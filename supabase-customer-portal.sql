begin;

create table if not exists public.customer_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  phone text,
  default_delivery_type text
    check (default_delivery_type in ('domicilio', 'punto_fisico'))
    default 'domicilio',
  city text default 'Barranco de Loba',
  address text,
  reference_point text,
  updated_at timestamptz default now()
);

alter table public.customer_profiles enable row level security;

drop policy if exists "Customers can read their own profile" on public.customer_profiles;
create policy "Customers can read their own profile"
  on public.customer_profiles for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Customers can create their own profile" on public.customer_profiles;
create policy "Customers can create their own profile"
  on public.customer_profiles for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Customers can update their own profile" on public.customer_profiles;
create policy "Customers can update their own profile"
  on public.customer_profiles for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Admins can read customer profiles" on public.customer_profiles;
create policy "Admins can read customer profiles"
  on public.customer_profiles for select to authenticated
  using (public.is_inventory_admin());

grant select, insert, update on public.customer_profiles to authenticated;

alter table public.customer_profiles
  add column if not exists city text default 'Barranco de Loba';

alter table public.orders
  add column if not exists user_id uuid null references auth.users (id) on delete set null,
  add column if not exists delivery_type text default 'domicilio',
  add column if not exists city text default 'Barranco de Loba',
  add column if not exists delivery_address text null,
  add column if not exists reference_point text null,
  add column if not exists delivery_fee numeric(12, 2) not null default 0;

do $constraint_migration$
declare
  v_status_attnum smallint;
  v_constraint record;
begin
  select a.attnum into v_status_attnum
  from pg_catalog.pg_attribute a
  where a.attrelid = 'public.orders'::regclass
    and a.attname = 'status'
    and not a.attisdropped;

  if v_status_attnum is null then
    raise exception 'No se encontró la columna public.orders.status.';
  end if;

  for v_constraint in
    select c.conname, pg_catalog.pg_get_constraintdef(c.oid) as definition
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.orders'::regclass
      and c.contype = 'c'
      and c.conkey = array[v_status_attnum]::smallint[]
      and pg_catalog.pg_get_constraintdef(c.oid) ~* 'status.*(any|in)'
  loop
    execute pg_catalog.format(
      'alter table public.orders drop constraint %I',
      v_constraint.conname
    );
  end loop;

  if exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.orders'::regclass
      and c.contype = 'c'
      and c.conkey = array[v_status_attnum]::smallint[]
      and pg_catalog.pg_get_constraintdef(c.oid) ~* 'status'
      and pg_catalog.pg_get_constraintdef(c.oid) !~* 'status.*(any|in)'
  ) then
    raise exception 'Se encontró una restricción de status no reconocida; no se modificó.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.orders'::regclass
      and c.conname = 'orders_status_customer_portal_check'
  ) then
    alter table public.orders
      add constraint orders_status_customer_portal_check
      check (status in (
        'En proceso',
        'Confirmación de pago',
        'Confirmado',
        'Empacado',
        'Entregado',
        'Finalizado',
        'Pendiente'
      ));
  end if;
end;
$constraint_migration$;

drop policy if exists "Customers can read their own orders" on public.orders;
create policy "Customers can read their own orders"
  on public.orders for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Customers can create their own orders" on public.orders;
create policy "Customers can create their own orders"
  on public.orders for insert to anon, authenticated
  with check (
    (user_id is null or user_id = auth.uid())
    and status = 'En proceso'
    and stock_deducted = false
  );

-- Prevent the legacy permissive guest policy from accepting another user's ID.
drop policy if exists "Guest order inserts cannot set a user" on public.orders;
create policy "Guest order inserts cannot set a user"
  on public.orders as restrictive for insert to anon
  with check (user_id is null);

drop policy if exists "Customer order inserts match their session" on public.orders;
create policy "Customer order inserts match their session"
  on public.orders as restrictive for insert to authenticated
  with check (
    public.is_inventory_admin()
    or user_id is null
    or user_id = auth.uid()
  );

create or replace function public.deduct_confirmed_order_stock()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  ordered_product record;
  old_step integer;
  new_step integer;
  order_steps text[] := array[
    'En proceso',
    'Confirmación de pago',
    'Confirmado',
    'Empacado',
    'Entregado',
    'Finalizado'
  ];
begin
  if old.status is not distinct from new.status then
    return new;
  end if;

  old_step := case
    when old.status = 'Pendiente' then 1
    else pg_catalog.array_position(order_steps, old.status)
  end;
  new_step := pg_catalog.array_position(order_steps, new.status);

  if new_step is null then
    raise exception 'El estado del pedido no es válido.';
  end if;
  if old_step is null then
    raise exception 'El estado anterior del pedido no es válido.';
  end if;
  if new_step < old_step then
    raise exception 'No se puede regresar a un estado anterior del pedido.';
  end if;

  if new.status = 'Confirmado' and old.status in (
    'Pendiente', 'En proceso', 'Confirmación de pago'
  ) then
    if not exists (
      select 1 from public.sales s where s.order_id = new.id
    ) then
      raise exception 'Confirme el pedido mediante el registro financiero de ventas.';
    end if;
    if old.stock_deducted then
      raise exception 'El inventario de este pedido ya fue descontado.';
    end if;

    for ordered_product in
      select product_id, sum(quantity)::integer as quantity
      from pg_catalog.jsonb_to_recordset(new.product_quantities)
        as order_item(product_id text, quantity integer)
      group by product_id
      order by product_id
    loop
      if ordered_product.product_id is null
         or ordered_product.quantity is null
         or ordered_product.quantity <= 0 then
        raise exception 'La cantidad de productos del pedido no es válida.';
      end if;

      update public.product_stock
      set quantity = quantity - ordered_product.quantity,
          updated_at = now()
      where product_id = ordered_product.product_id
        and quantity >= ordered_product.quantity;

      if not found then
        raise exception 'No hay unidades suficientes del producto %.',
          ordered_product.product_id;
      end if;
    end loop;

    new.stock_deducted := true;
  elsif new.status in ('Empacado', 'Entregado', 'Finalizado') then
    if not exists (
      select 1 from public.sales s where s.order_id = new.id
    ) or not new.stock_deducted then
      raise exception 'El pedido debe tener una venta confirmada y el inventario descontado.';
    end if;
  elsif old.status in ('Confirmado', 'Empacado', 'Entregado', 'Finalizado')
        and new.status in ('En proceso', 'Confirmación de pago', 'Pendiente') then
    raise exception 'No se puede regresar a un estado anterior del pedido.';
  end if;

  return new;
end;
$function$;

do $trigger_check$
begin
  if not exists (
    select 1 from pg_catalog.pg_trigger t
    where t.tgrelid = 'public.orders'::regclass
      and t.tgname = 'deduct_confirmed_order_stock'
      and not t.tgisinternal
  ) then
    create trigger deduct_confirmed_order_stock
      before update of status on public.orders
      for each row
      execute function public.deduct_confirmed_order_stock();
  end if;
  alter table public.orders enable trigger deduct_confirmed_order_stock;
end;
$trigger_check$;

create or replace function public.confirm_order_as_sale(
  p_order_id text,
  p_sale_lines jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_order public.orders%rowtype;
  v_lines jsonb;
  v_sale_id uuid;
  v_line record;
  v_stock integer;
  v_average numeric(14, 4);
  v_tracked integer;
  v_profile_found boolean;
  v_unknown_sold integer;
  v_known_sold integer;
  v_known_cost numeric(14, 4) := 0;
  v_cost_incomplete boolean := false;
  v_revenue numeric;
  v_stock_deducted boolean;
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;

  select o.* into v_order
  from public.orders o
  where o.id = p_order_id
  for update;
  if not found then
    raise exception 'No existe el pedido %.', p_order_id;
  end if;

  select s.sale_id into v_sale_id
  from public.sales s
  where s.order_id = p_order_id;
  if found then
    return v_sale_id;
  end if;

  if v_order.status not in ('Pendiente', 'En proceso', 'Confirmación de pago')
     or v_order.stock_deducted then
    raise exception 'Solo se pueden registrar pedidos sin confirmar y sin descuento previo.';
  end if;

  v_lines := coalesce(p_sale_lines, v_order.product_quantities);
  if v_lines is null or pg_catalog.jsonb_typeof(v_lines) <> 'array'
     or pg_catalog.jsonb_array_length(v_lines) = 0 then
    raise exception 'Faltan los detalles de venta.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(v_lines) as i(
      product_id text, product_name text, quantity integer, unit_price numeric
    )
    where i.product_id is null or pg_catalog.btrim(i.product_id) = ''
       or i.product_name is null or pg_catalog.btrim(i.product_name) = ''
       or i.quantity is null or i.quantity <= 0
       or i.unit_price is null or i.unit_price < 0
  ) then
    raise exception 'Los detalles o precios de venta no son válidos.';
  end if;

  if exists (
    select i.product_id
    from pg_catalog.jsonb_to_recordset(v_lines) as i(
      product_id text, product_name text, quantity integer, unit_price numeric
    )
    group by i.product_id
    having count(*) > 1
  ) then
    raise exception 'Cada producto debe aparecer una sola vez en la venta.';
  end if;

  if exists (
    select i.product_id, sum(i.quantity)::bigint
    from pg_catalog.jsonb_to_recordset(v_lines) as i(
      product_id text, product_name text, quantity integer, unit_price numeric
    )
    group by i.product_id
    except
    select q.product_id, sum(q.quantity)::bigint
    from pg_catalog.jsonb_to_recordset(v_order.product_quantities) as q(
      product_id text, quantity integer
    )
    group by q.product_id
  ) or exists (
    select q.product_id, sum(q.quantity)::bigint
    from pg_catalog.jsonb_to_recordset(v_order.product_quantities) as q(
      product_id text, quantity integer
    )
    group by q.product_id
    except
    select i.product_id, sum(i.quantity)::bigint
    from pg_catalog.jsonb_to_recordset(v_lines) as i(
      product_id text, product_name text, quantity integer, unit_price numeric
    )
    group by i.product_id
  ) then
    raise exception 'Las cantidades de la venta no coinciden con el pedido.';
  end if;

  select coalesce(sum(i.quantity * i.unit_price), 0) into v_revenue
  from pg_catalog.jsonb_to_recordset(v_lines) as i(
    product_id text, product_name text, quantity integer, unit_price numeric
  );
  if v_revenue <> v_order.total then
    raise exception 'Los precios por producto no coinciden con el total del pedido.';
  end if;

  insert into public.sales (order_id, total_revenue, created_by)
  values (p_order_id, v_order.total, auth.uid())
  returning sale_id into v_sale_id;

  for v_line in
    select *
    from pg_catalog.jsonb_to_recordset(v_lines) as i(
      product_id text, product_name text, quantity integer, unit_price numeric
    )
    order by i.product_id
  loop
    select s.quantity into v_stock
    from public.product_stock s
    where s.product_id = v_line.product_id
    for update;
    if not found or v_stock < v_line.quantity then
      raise exception 'No hay unidades suficientes del producto %.', v_line.product_id;
    end if;

    select c.average_unit_cost, c.tracked_quantity
      into v_average, v_tracked
    from public.finance_product_costs c
    where c.product_id = v_line.product_id
    for update;
    v_profile_found := found;
    if not v_profile_found then
      v_average := null;
      v_tracked := 0;
    end if;
    if v_tracked > v_stock then
      raise exception 'El costo registrado supera el stock del producto %.', v_line.product_id;
    end if;

    v_unknown_sold := least(v_line.quantity, v_stock - v_tracked);
    v_known_sold := v_line.quantity - v_unknown_sold;
    if v_known_sold > 0 and v_average is null then
      raise exception 'Falta el costo promedio del producto %.', v_line.product_id;
    end if;

    insert into public.sale_items (
      sale_id, product_id, product_name, quantity, unit_sale_price,
      known_cost_quantity, unknown_cost_quantity, unit_cost_snapshot
    )
    values (
      v_sale_id, v_line.product_id, v_line.product_name, v_line.quantity,
      v_line.unit_price, v_known_sold, v_unknown_sold,
      case when v_known_sold > 0 then v_average else null end
    );

    v_known_cost := v_known_cost + v_known_sold * coalesce(v_average, 0);
    if v_unknown_sold > 0 then
      v_cost_incomplete := true;
    end if;
    if v_profile_found then
      update public.finance_product_costs
      set tracked_quantity = tracked_quantity - v_known_sold,
          average_unit_cost = case
            when tracked_quantity - v_known_sold = 0 then null
            else average_unit_cost
          end,
          updated_at = now()
      where product_id = v_line.product_id;
    end if;
  end loop;

  update public.sales
  set known_cost_total = v_known_cost, cost_incomplete = v_cost_incomplete
  where sale_id = v_sale_id;

  update public.orders
  set status = 'Confirmado'
  where id = p_order_id
  returning stock_deducted into v_stock_deducted;
  if not found or not v_stock_deducted then
    raise exception 'No se pudo descontar el inventario del pedido.';
  end if;

  return v_sale_id;
end;
$function$;

revoke all on function public.confirm_order_as_sale(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.confirm_order_as_sale(text, jsonb)
  to authenticated;

commit;
