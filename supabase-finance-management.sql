-- Ejecutar después de supabase-finance-prepare.sql y supabase-finance-activate.sql.
begin;

alter table public.inventory_purchases
  add column if not exists stock_added boolean not null default true;

alter table public.inventory_purchase_items
  add column if not exists variant_label text not null default '';

alter table public.inventory_purchase_items
  drop constraint if exists inventory_purchase_items_purchase_id_product_id_key;

create unique index if not exists inventory_purchase_items_purchase_variant_key
  on public.inventory_purchase_items (purchase_id, product_id, variant_label);

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
  if p_request_id is null or p_purchase_type is null
     or p_purchase_type not in ('initial', 'restock')
     or p_acquired_on is null or p_description is null
     or pg_catalog.btrim(p_description) = ''
     or p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array'
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
    from public.inventory_purchase_items i where i.purchase_id = v_purchase_id;
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

create or replace function public.recalculate_finance_product_cost(p_product_id text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_purchased_quantity integer;
  v_purchased_cost numeric;
  v_sold_quantity integer;
  v_sold_cost numeric;
  v_tracked integer;
  v_stock integer;
  v_average numeric(14, 4);
  v_margin numeric(7, 2);
begin
  select coalesce(sum(i.quantity), 0)::integer,
         coalesce(sum(i.line_total), 0)
    into v_purchased_quantity, v_purchased_cost
  from public.inventory_purchase_items i
  where i.product_id = p_product_id;
  select coalesce(sum(i.known_cost_quantity), 0)::integer,
         coalesce(sum(i.known_cost_total), 0)
    into v_sold_quantity, v_sold_cost
  from public.sale_items i
  where i.product_id = p_product_id;
  v_tracked := v_purchased_quantity - v_sold_quantity;
  if v_tracked < 0 then
    raise exception 'Las compras no cubren las unidades ya vendidas del producto %.', p_product_id;
  end if;
  select s.quantity into v_stock
  from public.product_stock s where s.product_id = p_product_id for update;
  if not found or v_tracked > v_stock then
    raise exception 'El stock actual no permite recalcular los costos del producto %.', p_product_id;
  end if;
  select c.margin_percent into v_margin
  from public.finance_product_costs c where c.product_id = p_product_id;
  if v_tracked > 0 then
    if v_purchased_cost - v_sold_cost <= 0 then
      raise exception 'El costo restante no es válido para el producto %.', p_product_id;
    end if;
    v_average := round((v_purchased_cost - v_sold_cost) / v_tracked, 4);
    insert into public.finance_product_costs (
      product_id, average_unit_cost, margin_percent, tracked_quantity, updated_at
    )
    values (p_product_id, v_average, v_margin, v_tracked, now())
    on conflict (product_id) do update
      set average_unit_cost = excluded.average_unit_cost,
          tracked_quantity = excluded.tracked_quantity,
          updated_at = excluded.updated_at;
  elsif v_margin is not null or exists (
    select 1 from public.finance_product_costs c where c.product_id = p_product_id
  ) then
    insert into public.finance_product_costs (
      product_id, average_unit_cost, margin_percent, tracked_quantity, updated_at
    )
    values (p_product_id, null, v_margin, 0, now())
    on conflict (product_id) do update
      set average_unit_cost = null, tracked_quantity = 0, updated_at = now();
  else
    delete from public.finance_product_costs where product_id = p_product_id;
  end if;
end;
$function$;

create or replace function public.update_inventory_purchase(
  p_purchase_id uuid,
  p_description text,
  p_acquired_on date,
  p_supplier text,
  p_add_to_stock boolean,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_purchase public.inventory_purchases%rowtype;
  v_product_id text;
  v_stock integer;
  v_old_quantity integer;
  v_new_quantity integer;
  v_old_stock_quantity integer;
  v_new_stock_quantity integer;
  v_affected_products text[];
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  if p_purchase_id is null or p_description is null or pg_catalog.btrim(p_description) = ''
     or p_acquired_on is null or p_add_to_stock is null
     or p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array'
     or pg_catalog.jsonb_array_length(p_items) = 0 then
    raise exception 'Los datos de la compra no son válidos.';
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
       or coalesce(i.add_to_stock, p_add_to_stock) is distinct from p_add_to_stock
  ) then
    raise exception 'Hay productos, cantidades o valores inválidos en la compra.';
  end if;
  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_items) as i(
      product_id text, product_name text, variant_label text, quantity integer,
      unit_cost numeric, margin_percent numeric, add_to_stock boolean
    )
    group by i.product_id, coalesce(i.variant_label, '')
    having count(*) > 1
  ) then
    raise exception 'Cada producto y variante debe aparecer una sola vez por compra.';
  end if;

  select p.* into v_purchase
  from public.inventory_purchases p
  where p.purchase_id = p_purchase_id
  for update;
  if not found then
    raise exception 'No existe la inversión que intentas editar.';
  end if;
  select array_agg(ids.product_id order by ids.product_id) into v_affected_products
  from (
    select i.product_id from public.inventory_purchase_items i
    where i.purchase_id = p_purchase_id
    union
    select i.product_id
    from pg_catalog.jsonb_to_recordset(p_items) as i(
      product_id text, product_name text, variant_label text, quantity integer,
      unit_cost numeric, margin_percent numeric, add_to_stock boolean
    )
  ) ids;
  for v_product_id in
    select product_id from (
      select i.product_id from public.inventory_purchase_items i
      where i.purchase_id = p_purchase_id
      union
      select i.product_id
      from pg_catalog.jsonb_to_recordset(p_items) as i(
        product_id text, product_name text, variant_label text, quantity integer,
        unit_cost numeric, margin_percent numeric, add_to_stock boolean
      )
    ) ids order by product_id
  loop
    select s.quantity into v_stock from public.product_stock s
    where s.product_id = v_product_id for update;
    if not found then
      raise exception 'No existe stock para el producto %.', v_product_id;
    end if;
    select coalesce(sum(i.quantity), 0)::integer into v_old_quantity
    from public.inventory_purchase_items i
    where i.purchase_id = p_purchase_id and i.product_id = v_product_id;
    select coalesce(sum(i.quantity), 0)::integer into v_new_quantity
    from pg_catalog.jsonb_to_recordset(p_items) as i(
      product_id text, product_name text, variant_label text, quantity integer,
      unit_cost numeric, margin_percent numeric, add_to_stock boolean
    ) where i.product_id = v_product_id;
    v_old_stock_quantity := case when v_purchase.stock_added then v_old_quantity else 0 end;
    v_new_stock_quantity := case when p_add_to_stock then v_new_quantity else 0 end;
    if v_stock - v_old_stock_quantity + v_new_stock_quantity < 0 then
      raise exception 'No se puede retirar del stock unidades que ya no están disponibles (%).', v_product_id;
    end if;
    if v_stock - v_old_stock_quantity + v_new_stock_quantity < v_new_quantity
       and not p_add_to_stock then
      raise exception 'El stock disponible no alcanza para registrar el costo del producto %.', v_product_id;
    end if;
    if v_old_stock_quantity <> v_new_stock_quantity then
      update public.product_stock
      set quantity = quantity - v_old_stock_quantity + v_new_stock_quantity,
          updated_at = now()
      where product_id = v_product_id;
    end if;
  end loop;

  update public.inventory_purchases
  set description = pg_catalog.btrim(p_description),
      acquired_on = p_acquired_on,
      supplier = nullif(pg_catalog.btrim(p_supplier), ''),
      stock_added = p_add_to_stock
  where purchase_id = p_purchase_id;
  delete from public.inventory_purchase_items where purchase_id = p_purchase_id;
  insert into public.inventory_purchase_items (
    purchase_id, product_id, product_name, variant_label, quantity, unit_cost
  )
  select p_purchase_id, i.product_id, i.product_name,
         coalesce(i.variant_label, ''), i.quantity, i.unit_cost
  from pg_catalog.jsonb_to_recordset(p_items) as i(
    product_id text, product_name text, variant_label text, quantity integer,
    unit_cost numeric, margin_percent numeric, add_to_stock boolean
  );
  foreach v_product_id in array v_affected_products loop
    perform public.recalculate_finance_product_cost(v_product_id);
  end loop;
  return p_purchase_id;
end;
$function$;

create or replace function public.delete_inventory_purchase(p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_purchase public.inventory_purchases%rowtype;
  v_item record;
  v_stock integer;
  v_product_id text;
  v_affected_products text[];
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  select p.* into v_purchase from public.inventory_purchases p
  where p.purchase_id = p_purchase_id for update;
  if not found then
    raise exception 'No existe la inversión que intentas eliminar.';
  end if;
  select array_agg(ids.product_id order by ids.product_id) into v_affected_products
  from (
    select distinct i.product_id from public.inventory_purchase_items i
    where i.purchase_id = p_purchase_id
  ) ids;
  for v_item in
    select i.product_id, sum(i.quantity)::integer as quantity
    from public.inventory_purchase_items i
    where i.purchase_id = p_purchase_id
    group by i.product_id order by i.product_id
  loop
    select s.quantity into v_stock from public.product_stock s
    where s.product_id = v_item.product_id for update;
    if not found then
      raise exception 'No existe stock para el producto %.', v_item.product_id;
    end if;
    if v_purchase.stock_added and v_stock < v_item.quantity then
      raise exception 'No se puede eliminar: parte del stock de % ya fue utilizado.', v_item.product_id;
    end if;
    if v_purchase.stock_added then
      update public.product_stock
      set quantity = quantity - v_item.quantity, updated_at = now()
      where product_id = v_item.product_id;
    end if;
  end loop;
  delete from public.inventory_purchase_items where purchase_id = p_purchase_id;
  delete from public.inventory_purchases where purchase_id = p_purchase_id;
  foreach v_product_id in array v_affected_products loop
    perform public.recalculate_finance_product_cost(v_product_id);
  end loop;
end;
$function$;

create or replace function public.update_business_expense(
  p_expense_id uuid,
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
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  if p_expense_id is null or p_concept is null or pg_catalog.btrim(p_concept) = ''
     or p_category is null or pg_catalog.btrim(p_category) = ''
     or p_amount is null or p_amount <= 0 or p_spent_on is null then
    raise exception 'Los datos del gasto no son válidos.';
  end if;
  update public.business_expenses
  set concept = pg_catalog.btrim(p_concept),
      category = pg_catalog.btrim(p_category),
      amount = p_amount,
      spent_on = p_spent_on,
      description = nullif(pg_catalog.btrim(p_description), '')
  where expense_id = p_expense_id;
  if not found then
    raise exception 'No existe el gasto que intentas editar.';
  end if;
  return p_expense_id;
end;
$function$;

create or replace function public.delete_business_expense(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  delete from public.business_expenses where expense_id = p_expense_id;
  if not found then
    raise exception 'No existe el gasto que intentas eliminar.';
  end if;
end;
$function$;

revoke all on function public.record_inventory_purchase(uuid, text, text, date, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.recalculate_finance_product_cost(text)
  from public, anon, authenticated;
revoke all on function public.update_inventory_purchase(uuid, text, date, text, boolean, jsonb)
  from public, anon, authenticated;
revoke all on function public.delete_inventory_purchase(uuid)
  from public, anon, authenticated;
revoke all on function public.update_business_expense(uuid, text, text, numeric, date, text)
  from public, anon, authenticated;
revoke all on function public.delete_business_expense(uuid)
  from public, anon, authenticated;
grant execute on function public.record_inventory_purchase(uuid, text, text, date, text, jsonb)
  to authenticated;
grant execute on function public.update_inventory_purchase(uuid, text, date, text, boolean, jsonb)
  to authenticated;
grant execute on function public.delete_inventory_purchase(uuid)
  to authenticated;
grant execute on function public.update_business_expense(uuid, text, text, numeric, date, text)
  to authenticated;
grant execute on function public.delete_business_expense(uuid)
  to authenticated;

commit;
