-- Restore the most recent inventory reset backup.
-- Run this only if you need to put the deleted on-sale books back.

begin;

do $$
declare
  v_backup_run_id uuid;
  v_shipments_inserted integer := 0;
  v_books_inserted integer := 0;
begin
  select r.id
  into v_backup_run_id
  from public.book_inventory_reset_backup_runs r
  order by r.created_at desc
  limit 1;

  if v_backup_run_id is null then
    raise exception 'No backup run found in public.book_inventory_reset_backup_runs.';
  end if;

  insert into public.shipments (
    id,
    user_id,
    seller_name,
    seller_phone,
    pickup_date,
    status,
    created_at
  )
  overriding system value
  select
    backup_shipments.original_shipment_id,
    backup_shipments.user_id,
    backup_shipments.seller_name,
    backup_shipments.seller_phone,
    backup_shipments.pickup_date,
    backup_shipments.status,
    backup_shipments.created_at
  from public.book_inventory_reset_backup_shipments backup_shipments
  left join public.shipments shipments
    on shipments.id = backup_shipments.original_shipment_id
  where backup_shipments.backup_run_id = v_backup_run_id
    and shipments.id is null;

  get diagnostics v_shipments_inserted = row_count;

  insert into public.books (
    id,
    shipment_id,
    title,
    option,
    status,
    price,
    created_at
  )
  overriding system value
  select
    backup_books.original_book_id,
    backup_books.shipment_id,
    backup_books.title,
    backup_books.option,
    backup_books.status,
    backup_books.price,
    backup_books.created_at
  from public.book_inventory_reset_backup_books backup_books
  left join public.books books
    on books.id = backup_books.original_book_id
  where backup_books.backup_run_id = v_backup_run_id
    and books.id is null;

  get diagnostics v_books_inserted = row_count;

  perform setval(
    pg_get_serial_sequence('public.shipments', 'id'),
    coalesce((select max(s.id) from public.shipments s), 1),
    true
  );

  perform setval(
    pg_get_serial_sequence('public.books', 'id'),
    coalesce((select max(b.id) from public.books b), 1),
    true
  );

  raise notice
    'Restored backup_run_id=% shipments=% books=%',
    v_backup_run_id,
    v_shipments_inserted,
    v_books_inserted;
end;
$$;

commit;
