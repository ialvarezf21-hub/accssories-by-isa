create table if not exists public.product_stock (
  product_id text primary key,
  quantity integer not null check (quantity >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id text primary key,
  created_at timestamptz not null default now(),
  date text not null,
  customer text not null,
  items text not null,
  total numeric(12, 2) not null check (total >= 0),
  status text not null default 'Pendiente'
    check (status in ('Pendiente', 'Confirmado', 'Entregado')),
  product_quantities jsonb not null default '[]'::jsonb
    check (jsonb_typeof(product_quantities) = 'array'),
  stock_deducted boolean not null default false
);

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade
);

grant usage on schema public to anon, authenticated;

alter table public.product_stock enable row level security;
alter table public.orders enable row level security;
alter table public.admin_users enable row level security;

create or replace function public.is_inventory_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users
    where user_id = auth.uid()
  );
$$;

revoke all on function public.is_inventory_admin() from public;
grant execute on function public.is_inventory_admin() to authenticated;

drop policy if exists "Public can read product stock" on public.product_stock;
create policy "Public can read product stock"
  on public.product_stock for select
  to anon, authenticated
  using (true);

drop policy if exists "Admins can insert product stock" on public.product_stock;
create policy "Admins can insert product stock"
  on public.product_stock for insert
  to authenticated
  with check (public.is_inventory_admin());

drop policy if exists "Admins can update product stock" on public.product_stock;
create policy "Admins can update product stock"
  on public.product_stock for update
  to authenticated
  using (public.is_inventory_admin())
  with check (public.is_inventory_admin());

drop policy if exists "Admins can delete product stock" on public.product_stock;
create policy "Admins can delete product stock"
  on public.product_stock for delete
  to authenticated
  using (public.is_inventory_admin());

drop policy if exists "Customers can create pending orders" on public.orders;
create policy "Customers can create pending orders"
  on public.orders for insert
  to anon, authenticated
  with check (status = 'Pendiente' and stock_deducted = false);

drop policy if exists "Admins can read orders" on public.orders;
create policy "Admins can read orders"
  on public.orders for select
  to authenticated
  using (public.is_inventory_admin());

drop policy if exists "Admins can import orders" on public.orders;
create policy "Admins can import orders"
  on public.orders for insert
  to authenticated
  with check (public.is_inventory_admin());

drop policy if exists "Admins can update orders" on public.orders;
create policy "Admins can update orders"
  on public.orders for update
  to authenticated
  using (public.is_inventory_admin())
  with check (public.is_inventory_admin());

drop policy if exists "Admins can delete orders" on public.orders;
create policy "Admins can delete orders"
  on public.orders for delete
  to authenticated
  using (public.is_inventory_admin());

drop policy if exists "Admins can read their own allowlist entry" on public.admin_users;
create policy "Admins can read their own allowlist entry"
  on public.admin_users for select
  to authenticated
  using (user_id = auth.uid());

grant select on public.product_stock to anon, authenticated;
grant insert, update, delete on public.product_stock to authenticated;
grant insert on public.orders to anon;
grant select, insert, update, delete on public.orders to authenticated;
grant select on public.admin_users to authenticated;

create or replace function public.deduct_confirmed_order_stock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  ordered_product record;
begin
  if new.status in ('Confirmado', 'Entregado')
     and old.status not in ('Confirmado', 'Entregado')
     and not old.stock_deducted then
    for ordered_product in
      select product_id, sum(quantity)::integer as quantity
      from jsonb_to_recordset(new.product_quantities)
        as order_item(product_id text, quantity integer)
      group by product_id
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
        raise exception 'No hay unidades suficientes del producto %.', ordered_product.product_id;
      end if;
    end loop;

    new.stock_deducted := true;
  end if;

  return new;
end;
$$;

revoke all on function public.deduct_confirmed_order_stock() from public, anon, authenticated;

drop trigger if exists deduct_confirmed_order_stock on public.orders;
create trigger deduct_confirmed_order_stock
  before update of status on public.orders
  for each row
  execute function public.deduct_confirmed_order_stock();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'product_stock'
  ) then
    execute 'alter publication supabase_realtime add table public.product_stock';
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    execute 'alter publication supabase_realtime add table public.orders';
  end if;
end;
$$;

-- Create the administrator in Supabase Auth first, then allowlist that account:
-- insert into public.admin_users (user_id)
-- select id from auth.users where email = 'admin@example.com'
-- on conflict do nothing;
