create or replace function public.check_member_email_availability(
  p_email text
)
returns table (
  normalized_email text,
  is_available boolean,
  account_role text
)
language sql
stable
security definer
set search_path = public
as $$
  with normalized as (
    select lower(nullif(btrim(p_email), '')) as email
  )
  select
    normalized.email as normalized_email,
    case
      when normalized.email is null then false
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = normalized.email
      ) then false
      when exists (
        select 1
        from public.member_profiles mp
        where lower(mp.email) = normalized.email
      ) then false
      else true
    end as is_available,
    case
      when normalized.email is null then 'invalid'
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = normalized.email
      ) then 'admin'
      when exists (
        select 1
        from public.member_profiles mp
        where lower(mp.email) = normalized.email
      ) then 'member'
      else 'available'
    end as account_role
  from normalized;
$$;

grant execute on function public.check_member_email_availability(text) to anon, authenticated;
