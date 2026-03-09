drop policy if exists shipments_delete_public on public.shipments;
drop policy if exists shipments_delete_admin on public.shipments;

create policy shipments_delete_admin
  on public.shipments
  for delete
  to authenticated
  using (public.is_admin_user());
