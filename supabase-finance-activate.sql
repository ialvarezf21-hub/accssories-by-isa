begin;

-- These restrictions are activated only after the updated panel is deployed.
-- Legacy, non-costed products retain the current stock editing/sync path.
drop policy if exists "Admins can insert product stock" on public.product_stock;
drop policy if exists "Admins can update product stock" on public.product_stock;
drop policy if exists "Admins can delete product stock" on public.product_stock;

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
