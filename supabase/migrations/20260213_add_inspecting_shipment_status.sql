-- Add "inspecting" stage to shipment status:
-- scheduled -> inspecting -> inspected

do $$
declare
  status_constraint record;
begin
  for status_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.shipments'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format(
      'alter table public.shipments drop constraint if exists %I',
      status_constraint.conname
    );
  end loop;
end;
$$;

alter table public.shipments
  add constraint shipments_status_check
  check (status in ('scheduled', 'inspecting', 'inspected'));
