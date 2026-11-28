-- Reinicia solo los historiales de inversiones y gastos.
-- Conserva intactos products, product_stock, fotos, precios, disenos, pedidos y ventas.
-- Atencion: elimina permanentemente los registros de las cuatro tablas indicadas.
-- Ejecutar manualmente en Supabase; la operacion es transaccional e idempotente.
begin;

delete from public.inventory_purchase_items;
delete from public.inventory_purchases;
delete from public.finance_product_costs;
delete from public.business_expenses;

commit;
