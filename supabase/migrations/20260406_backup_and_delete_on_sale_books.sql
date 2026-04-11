-- Preserve the migration order, but keep this step non-destructive.
-- The old inventory backup/delete routine is intentionally not run as part of
-- member-management rollout. This migration only prepares shipment ownership.

alter table public.shipments
  add column if not exists user_id uuid null references auth.users(id) on delete set null;

-- Link legacy shipments to the owning member when the seller name and phone
-- are an exact unique match in member_profiles.
update public.shipments s
set user_id = matched.user_id
from (
  select s2.id as shipment_id, mp.user_id
  from public.shipments s2
  join public.member_profiles mp
    on mp.name = s2.seller_name
   and regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') =
     regexp_replace(s2.seller_phone, '[^0-9]', '', 'g')
  where mp.phone is not null
    and not exists (
      select 1
      from public.member_profiles mp2
      where mp2.name = s2.seller_name
        and regexp_replace(coalesce(mp2.phone, ''), '[^0-9]', '', 'g') =
          regexp_replace(s2.seller_phone, '[^0-9]', '', 'g')
        and mp2.user_id <> mp.user_id
    )
) matched
where s.id = matched.shipment_id
  and s.user_id is null;
