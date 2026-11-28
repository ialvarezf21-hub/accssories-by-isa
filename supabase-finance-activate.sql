begin;

-- These restrictions are activated only after the updated panel is deployed.
-- Legacy, non-costed products retain the current stock editing/sync path.
drop policy if exists "Admins can insert product stock" on public.product_stock;
drop policy if exists "Admins can update product stock" on public.product_stock;
drop policy if exists "Admins can delete product stock" on public.product_stock;
drop policy if exists "Admins can insert untracked product stock" on public.product_stock;
drop policy if exists "Admins can update untracked product stock" on public.product_stock;
drop policy if exists "Admins can delete untracked product stock" on public.product_stock;

create policy "Admins can insert untracked product stock"
  on public.product_stock for insert to authenticated
  with check (
    public.is_inventory_admin()
    and not exists (
      select 1 from public.finance_product_costs c
      where c.product_id = product_stock.product_id
    )
  );

create policy "Admins can update untracked product stock"
  on public.product_stock for update to authenticated
  using (
    public.is_inventory_admin()
    and not exists (
      select 1 from public.finance_product_costs c
      where c.product_id = product_stock.product_id
    )
  )
  with check (
    public.is_inventory_admin()
    and not exists (
      select 1 from public.finance_product_costs c
      where c.product_id = product_stock.product_id
    )
  );

create policy "Admins can delete untracked product stock"
  on public.product_stock for delete to authenticated
  using (
    public.is_inventory_admin()
    and not exists (
      select 1 from public.finance_product_costs c
      where c.product_id = product_stock.product_id
    )
  );

create or replace function public.set_product_stock_quantity(
  p_product_id text,
  p_quantity integer
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tracked_quantity integer;
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  if p_product_id is null or pg_catalog.btrim(p_product_id) = ''
     or p_quantity is null or p_quantity < 0 then
    raise exception 'El producto o la cantidad de inventario no son válidos.';
  end if;

  insert into public.product_stock (product_id, quantity, updated_at)
  values (p_product_id, p_quantity, now())
  on conflict (product_id) do update
    set quantity = excluded.quantity,
        updated_at = now();

  select c.tracked_quantity into v_tracked_quantity
  from public.finance_product_costs c
  where c.product_id = p_product_id
  for update;
  if found then
    v_tracked_quantity := least(coalesce(v_tracked_quantity, 0), p_quantity);
    update public.finance_product_costs
    set tracked_quantity = v_tracked_quantity,
        average_unit_cost = case
          when v_tracked_quantity = 0 then null
          else average_unit_cost
        end,
        updated_at = now()
    where product_id = p_product_id;
  end if;
end;
$function$;

revoke all on function public.set_product_stock_quantity(text, integer) from public, anon, authenticated;
grant execute on function public.set_product_stock_quantity(text, integer) to authenticated;

-- A status transition that deducts stock must have a sale row created by the
-- financial RPC in the same transaction. A confirmed sale cannot be reopened.
create or replace function public.deduct_confirmed_order_stock()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  ordered_product record;
begin
  if old.status = 'Pendiente'
     and new.status in ('Confirmado', 'Entregado') then
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

  elsif old.status = 'Confirmado' and new.status = 'Entregado' then
    if not exists (
      select 1 from public.sales s where s.order_id = new.id
    ) then
      raise exception 'El pedido confirmado no tiene un registro financiero de venta.';
    end if;

  elsif old.status in ('Confirmado', 'Entregado')
        and new.status = 'Pendiente' then
    raise exception 'No se puede regresar a pendiente un pedido confirmado.';

  elsif old.status = 'Entregado' and new.status = 'Confirmado' then
    raise exception 'No se puede regresar a confirmado un pedido entregado.';
  end if;

  return new;
end;
$function$;

drop trigger if exists deduct_confirmed_order_stock on public.orders;
create trigger deduct_confirmed_order_stock
  before update of status on public.orders
  for each row
  execute function public.deduct_confirmed_order_stock();

create or replace function public.delete_confirmed_sale(p_sale_id uuid)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_sale public.sales%rowtype;
  v_order public.orders%rowtype;
  v_item record;
  v_stock integer;
  v_average_unit_cost numeric(14, 4);
  v_tracked_quantity integer;
  v_new_tracked_quantity integer;
begin
  if not public.is_inventory_admin() then
    raise exception 'Se requiere una cuenta administradora.';
  end if;
  if p_sale_id is null then
    raise exception 'La venta que intentas eliminar no es válida.';
  end if;

  select s.* into v_sale
  from public.sales s
  where s.sale_id = p_sale_id
  for update;
  if not found then
    return null;
  end if;

  select o.* into v_order
  from public.orders o
  where o.id = v_sale.order_id
  for update;
  if not found or not v_order.stock_deducted then
    raise exception 'No se pudo verificar el descuento de inventario de esta venta.';
  end if;
  if not exists (
    select 1 from public.sale_items i where i.sale_id = p_sale_id
  ) then
    raise exception 'La venta no tiene detalles para devolver al inventario.';
  end if;

  for v_item in
    select i.product_id, i.quantity, i.known_cost_quantity, i.unit_cost_snapshot
    from public.sale_items i
    where i.sale_id = p_sale_id
    order by i.product_id
  loop
    update public.product_stock
    set quantity = quantity + v_item.quantity,
        updated_at = now()
    where product_id = v_item.product_id
    returning quantity into v_stock;
    if not found then
      raise exception 'No existe inventario para devolver el producto %.', v_item.product_id;
    end if;

    if v_item.known_cost_quantity > 0 then
      select c.average_unit_cost, c.tracked_quantity
        into v_average_unit_cost, v_tracked_quantity
      from public.finance_product_costs c
      where c.product_id = v_item.product_id
      for update;
      if found then
        v_new_tracked_quantity := v_tracked_quantity + v_item.known_cost_quantity;
        update public.finance_product_costs
        set average_unit_cost = round(
              (coalesce(v_average_unit_cost, 0) * v_tracked_quantity
                + v_item.known_cost_quantity * v_item.unit_cost_snapshot)
                / v_new_tracked_quantity,
              4
            ),
            tracked_quantity = v_new_tracked_quantity,
            updated_at = now()
        where product_id = v_item.product_id;
      end if;
    end if;
  end loop;

  delete from public.sale_items where sale_id = p_sale_id;
  delete from public.sales where sale_id = p_sale_id;
  delete from public.orders where id = v_order.id;
  if not found then
    raise exception 'No se pudo eliminar el pedido asociado a la venta.';
  end if;

  return v_order.id;
end;
$function$;

revoke all on function public.delete_confirmed_sale(uuid) from public, anon, authenticated;
grant execute on function public.delete_confirmed_sale(uuid) to authenticated;

-- Keep unconfirmed orders deletable but preserve orders with a financial sale.
drop policy if exists "Admins can delete orders" on public.orders;
drop policy if exists "Admins can delete orders without a sale" on public.orders;
create policy "Admins can delete orders without a sale"
  on public.orders for delete to authenticated
  using (
    public.is_inventory_admin()
    and not exists (
      select 1 from public.sales s where s.order_id = orders.id
    )
  );

commit;
