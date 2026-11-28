begin;

-- Tablas privadas para costos, compras, ventas y gastos.
create table if not exists public.finance_product_costs (
  product_id text primary key,
  average_unit_cost numeric(14, 4),
  margin_percent numeric(7, 2),
  tracked_quantity integer not null default 0 check (tracked_quantity >= 0),
  updated_at timestamptz not null default now(),
  check (average_unit_cost is null or average_unit_cost > 0),
  check (margin_percent is null or margin_percent >= 0),
  check (
    (tracked_quantity = 0 and average_unit_cost is null)
    or (tracked_quantity > 0 and average_unit_cost is not null)
  )
);

create table if not exists public.inventory_purchases (
  purchase_id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null unique,
  purchase_type text not null check (purchase_type in ('initial', 'restock')),
  description text not null,
  acquired_on date not null,
  supplier text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  stock_added boolean not null default true
);

create table if not exists public.inventory_purchase_items (
  purchase_item_id uuid primary key default pg_catalog.gen_random_uuid(),
  purchase_id uuid not null references public.inventory_purchases (purchase_id) on delete restrict,
  product_id text not null,
  product_name text not null,
  variant_label text not null default '',
  quantity integer not null check (quantity > 0),
  unit_cost numeric(12, 2) not null check (unit_cost > 0),
  line_total numeric generated always as (quantity * unit_cost) stored
);

create table if not exists public.sales (
  sale_id uuid primary key default pg_catalog.gen_random_uuid(),
  order_id text not null unique,
  sold_at timestamptz not null default now(),
  total_revenue numeric(12, 2) not null check (total_revenue >= 0),
  known_cost_total numeric(14, 4) not null default 0 check (known_cost_total >= 0),
  cost_incomplete boolean not null default false,
  gross_profit numeric generated always as (
    case when cost_incomplete then null else total_revenue - known_cost_total end
  ) stored,
  created_by uuid references auth.users (id) on delete set null
);

create table if not exists public.sale_items (
  sale_item_id uuid primary key default pg_catalog.gen_random_uuid(),
  sale_id uuid not null references public.sales (sale_id) on delete restrict,
  product_id text not null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_sale_price numeric(12, 2) not null check (unit_sale_price >= 0),
  known_cost_quantity integer not null default 0 check (known_cost_quantity >= 0),
  unknown_cost_quantity integer not null default 0 check (unknown_cost_quantity >= 0),
  unit_cost_snapshot numeric(14, 4),
  line_revenue numeric generated always as (quantity * unit_sale_price) stored,
  known_cost_total numeric generated always as (
    known_cost_quantity * coalesce(unit_cost_snapshot, 0)
  ) stored,
  check (known_cost_quantity + unknown_cost_quantity = quantity),
  check (
    (known_cost_quantity = 0 and unit_cost_snapshot is null)
    or (known_cost_quantity > 0 and unit_cost_snapshot is not null)
  ),
  unique (sale_id, product_id)
);

create table if not exists public.business_expenses (
  expense_id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null unique,
  concept text not null,
  category text not null,
  amount numeric(12, 2) not null check (amount > 0),
  spent_on date not null,
  description text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.inventory_purchases
  add column if not exists stock_added boolean not null default true;
alter table public.inventory_purchase_items
  add column if not exists variant_label text not null default '';
alter table public.inventory_purchase_items
  drop constraint if exists inventory_purchase_items_purchase_id_product_id_key;
alter table public.inventory_purchase_items
  drop constraint if exists inventory_purchase_items_purchase_id_product_id_variant_label_key;
create unique index if not exists inventory_purchase_items_purchase_variant_key
  on public.inventory_purchase_items (purchase_id, product_id, variant_label);

alter table public.finance_product_costs enable row level security;
alter table public.inventory_purchases enable row level security;
alter table public.inventory_purchase_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.business_expenses enable row level security;

drop policy if exists "Admins can read finance product costs" on public.finance_product_costs;
create policy "Admins can read finance product costs"
  on public.finance_product_costs for select to authenticated
  using (public.is_inventory_admin());
drop policy if exists "Admins can read inventory purchases" on public.inventory_purchases;
create policy "Admins can read inventory purchases"
  on public.inventory_purchases for select to authenticated
  using (public.is_inventory_admin());
drop policy if exists "Admins can read inventory purchase items" on public.inventory_purchase_items;
create policy "Admins can read inventory purchase items"
  on public.inventory_purchase_items for select to authenticated
  using (public.is_inventory_admin());
drop policy if exists "Admins can read sales" on public.sales;
create policy "Admins can read sales"
  on public.sales for select to authenticated
  using (public.is_inventory_admin());
drop policy if exists "Admins can read sale items" on public.sale_items;
create policy "Admins can read sale items"
  on public.sale_items for select to authenticated
  using (public.is_inventory_admin());
drop policy if exists "Admins can read business expenses" on public.business_expenses;
create policy "Admins can read business expenses"
  on public.business_expenses for select to authenticated
  using (public.is_inventory_admin());

revoke all on public.finance_product_costs, public.inventory_purchases,
  public.inventory_purchase_items, public.sales, public.sale_items,
  public.business_expenses from anon, authenticated;
grant select on public.finance_product_costs, public.inventory_purchases,
  public.inventory_purchase_items, public.sales, public.sale_items,
  public.business_expenses to authenticated;

-- El mismo RPC registra una compra inicial o una reposición y actualiza stock.
-- p_items: [{product_id, product_name, variant_label, quantity, unit_cost,
--            margin_percent, add_to_stock}]
create or replace function public.record_inventory_purchase(
  p_request_id uuid,
  p_purchase_type text,
  p_description text,
  p_acquired_on date,
  p_supplier text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_purchase_id uuid;
  v_existing_type text;
  v_existing_description text;
  v_existing_date date;
  v_existing_supplier text;
  v_existing_stock_added boolean;
  v_existing_items integer;
  v_item record;
  v_stock integer;
  v_old_average numeric(14, 4);
  v_old_tracked integer;
  v_old_margin numeric(7, 2);
  v_new_average numeric(14, 4);
  v_new_tracked integer;
  v_add_to_stock boolean;
  v_profile_found boolean;
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;

  if p_request_id is null
     or p_purchase_type is null
     or p_purchase_type not in ('initial', 'restock')
     or p_acquired_on is null
     or p_description is null
     or pg_catalog.btrim(p_description) = ''
     or p_items is null
     or pg_catalog.jsonb_typeof(p_items) <> 'array'
     or pg_catalog.jsonb_array_length(p_items) = 0 then
    raise exception 'Los datos de la compra no son válidos.';
  end if;

  v_add_to_stock := coalesce((p_items -> 0 ->> 'add_to_stock')::boolean, true);
  if p_purchase_type = 'initial' and not v_add_to_stock then
    raise exception 'La compra inicial debe crear las unidades iniciales del catálogo.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_items) as i(
      product_id text, product_name text, variant_label text, quantity integer,
      unit_cost numeric, margin_percent numeric, add_to_stock boolean
    )
    where i.product_id is null or pg_catalog.btrim(i.product_id) = ''
       or i.product_name is null or pg_catalog.btrim(i.product_name) = ''
       or i.quantity is null or i.quantity <= 0
       or i.unit_cost is null or i.unit_cost <= 0
       or (i.margin_percent is not null and i.margin_percent < 0)
       or (p_purchase_type = 'initial' and i.margin_percent is null)
       or coalesce(i.add_to_stock, true) is distinct from v_add_to_stock
  ) then
    raise exception 'Hay productos, cantidades o valores inválidos en la compra.';
  end if;

  if exists (
    select i.product_id, coalesce(i.variant_label, '')
    from pg_catalog.jsonb_to_recordset(p_items) as i(
      product_id text, product_name text, variant_label text, quantity integer,
      unit_cost numeric, margin_percent numeric, add_to_stock boolean
    )
    group by i.product_id, coalesce(i.variant_label, '')
    having count(*) > 1
  ) then
    raise exception 'Cada producto y variante debe aparecer una sola vez por compra.';
  end if;

  insert into public.inventory_purchases (
    request_id, purchase_type, description, acquired_on, supplier, created_by, stock_added
  )
  values (
    p_request_id, p_purchase_type, pg_catalog.btrim(p_description), p_acquired_on,
    nullif(pg_catalog.btrim(p_supplier), ''), auth.uid(), v_add_to_stock
  )
  on conflict (request_id) do nothing
  returning purchase_id into v_purchase_id;

  if v_purchase_id is null then
    select p.purchase_id, p.purchase_type, p.description, p.acquired_on,
           p.supplier, p.stock_added
      into v_purchase_id, v_existing_type, v_existing_description,
           v_existing_date, v_existing_supplier, v_existing_stock_added
    from public.inventory_purchases p
    where p.request_id = p_request_id;
    if v_existing_type is distinct from p_purchase_type
       or v_existing_description is distinct from pg_catalog.btrim(p_description)
       or v_existing_date is distinct from p_acquired_on
       or v_existing_supplier is distinct from nullif(pg_catalog.btrim(p_supplier), '')
       or v_existing_stock_added is distinct from v_add_to_stock then
      raise exception 'El identificador de solicitud ya fue usado con datos distintos.';
    end if;

    select count(*) into v_existing_items
    from public.inventory_purchase_items i
    where i.purchase_id = v_purchase_id;
    if v_existing_items <> pg_catalog.jsonb_array_length(p_items)
       or exists (
         select 1
         from pg_catalog.jsonb_to_recordset(p_items) as i(
           product_id text, product_name text, variant_label text, quantity integer,
           unit_cost numeric, margin_percent numeric, add_to_stock boolean
         )
         left join public.inventory_purchase_items saved
           on saved.purchase_id = v_purchase_id
          and saved.product_id = i.product_id
          and saved.variant_label = coalesce(i.variant_label, '')
         where saved.purchase_item_id is null
            or saved.product_name is distinct from i.product_name
            or saved.quantity is distinct from i.quantity
            or saved.unit_cost is distinct from i.unit_cost
       ) then
      raise exception 'El identificador de solicitud ya fue usado con productos distintos.';
    end if;
    return v_purchase_id;
  end if;

  for v_item in
    select i.product_id,
           pg_catalog.sum(i.quantity)::integer as quantity,
           pg_catalog.sum(i.quantity * i.unit_cost) as total_cost,
           pg_catalog.max(i.margin_percent) as margin_percent
    from pg_catalog.jsonb_to_recordset(p_items) as i(
      product_id text, product_name text, variant_label text, quantity integer,
      unit_cost numeric, margin_percent numeric, add_to_stock boolean
    )
    group by i.product_id
    order by i.product_id
  loop
    if p_purchase_type = 'initial' then
      if exists (select 1 from public.product_stock s where s.product_id = v_item.product_id)
         or exists (select 1 from public.finance_product_costs c where c.product_id = v_item.product_id) then
        raise exception 'El producto % ya tiene inventario o costos registrados.', v_item.product_id;
      end if;

      insert into public.product_stock (product_id, quantity)
      values (v_item.product_id, v_item.quantity);

      insert into public.finance_product_costs (
        product_id, average_unit_cost, margin_percent, tracked_quantity
      )
      values (
        v_item.product_id, round(v_item.total_cost / v_item.quantity, 4),
        v_item.margin_percent, v_item.quantity
      );
    else
      select s.quantity into v_stock
      from public.product_stock s
      where s.product_id = v_item.product_id
      for update;
      if not found then
        raise exception 'No existe stock para el producto %.', v_item.product_id;
      end if;

      select c.average_unit_cost, c.tracked_quantity, c.margin_percent
        into v_old_average, v_old_tracked, v_old_margin
      from public.finance_product_costs c
      where c.product_id = v_item.product_id
      for update;
      v_profile_found := found;

      if not v_profile_found then
        v_old_average := null;
        v_old_tracked := 0;
        v_old_margin := null;
      end if;
      if v_old_tracked > v_stock then
        raise exception 'El costo registrado supera el stock del producto %.', v_item.product_id;
      end if;
      if not v_add_to_stock and v_old_tracked + v_item.quantity > v_stock then
        raise exception 'Las unidades a costear superan el stock ya cargado del producto %.', v_item.product_id;
      end if;

      v_new_tracked := v_old_tracked + v_item.quantity;
      v_new_average := round(
        (coalesce(v_old_average, 0) * v_old_tracked + v_item.total_cost) / v_new_tracked,
        4
      );

      if v_add_to_stock then
        update public.product_stock
        set quantity = quantity + v_item.quantity, updated_at = now()
        where product_id = v_item.product_id;
      end if;

      if v_profile_found then
        update public.finance_product_costs
        set average_unit_cost = v_new_average,
            tracked_quantity = v_new_tracked,
            margin_percent = coalesce(v_item.margin_percent, v_old_margin),
            updated_at = now()
        where product_id = v_item.product_id;
      else
        insert into public.finance_product_costs (
          product_id, average_unit_cost, margin_percent, tracked_quantity
        )
        values (
          v_item.product_id, v_new_average, v_item.margin_percent, v_new_tracked
        );
      end if;
    end if;

  end loop;

  insert into public.inventory_purchase_items (
    purchase_id, product_id, product_name, variant_label, quantity, unit_cost
  )
  select v_purchase_id, i.product_id, i.product_name,
         coalesce(i.variant_label, ''), i.quantity, i.unit_cost
  from pg_catalog.jsonb_to_recordset(p_items) as i(
    product_id text, product_name text, variant_label text, quantity integer,
    unit_cost numeric, margin_percent numeric, add_to_stock boolean
  );
  return v_purchase_id;
end;
$function$;

-- Registra venta y su costo histórico antes de actualizar el pedido.
-- p_sale_lines: [{product_id, product_name, quantity, unit_price}]
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

  if v_order.status <> 'Pendiente' or v_order.stock_deducted then
    raise exception 'Solo se pueden registrar pedidos pendientes sin descuento previo.';
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

    -- Las unidades históricas sin costo se consideran vendidas primero.
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

  -- En la fase preparatoria, el trigger actual descuenta stock como hoy.
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

create or replace function public.record_business_expense(
  p_request_id uuid,
  p_concept text,
  p_category text,
  p_amount numeric,
  p_spent_on date,
  p_description text default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_expense_id uuid;
  v_saved public.business_expenses%rowtype;
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  if p_request_id is null
     or p_concept is null or pg_catalog.btrim(p_concept) = ''
     or p_category is null or pg_catalog.btrim(p_category) = ''
     or p_amount is null or p_amount <= 0
     or p_spent_on is null then
    raise exception 'Los datos del gasto no son válidos.';
  end if;

  insert into public.business_expenses (
    request_id, concept, category, amount, spent_on, description, created_by
  )
  values (
    p_request_id, pg_catalog.btrim(p_concept), pg_catalog.btrim(p_category),
    p_amount, p_spent_on, nullif(pg_catalog.btrim(p_description), ''), auth.uid()
  )
  on conflict (request_id) do nothing
  returning expense_id into v_expense_id;

  if v_expense_id is null then
    select e.* into v_saved
    from public.business_expenses e
    where e.request_id = p_request_id;
    if v_saved.concept is distinct from pg_catalog.btrim(p_concept)
       or v_saved.category is distinct from pg_catalog.btrim(p_category)
       or v_saved.amount is distinct from p_amount
       or v_saved.spent_on is distinct from p_spent_on
       or v_saved.description is distinct from nullif(pg_catalog.btrim(p_description), '') then
      raise exception 'El identificador de solicitud ya fue usado con datos distintos.';
    end if;
    v_expense_id := v_saved.expense_id;
  end if;
  return v_expense_id;
end;
$function$;

revoke all on function public.record_inventory_purchase(uuid, text, text, date, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.confirm_order_as_sale(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.record_business_expense(uuid, text, text, numeric, date, text)
  from public, anon, authenticated;
grant execute on function public.record_inventory_purchase(uuid, text, text, date, text, jsonb)
  to authenticated;
grant execute on function public.confirm_order_as_sale(text, jsonb)
  to authenticated;
grant execute on function public.record_business_expense(uuid, text, text, numeric, date, text)
  to authenticated;

commit;
