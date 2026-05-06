-- 식스샵 마이그레이션 1회용 일괄 upsert RPC.
-- service_role JWT로만 호출 (anon/authenticated revoke).
-- 같은 group_key가 이미 있으면 cover_image_url/status만 갱신.
-- group_key는 storefront_product_group_key()로 자동 계산.

create or replace function public.admin_bulk_upsert_products_sixshop(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer := 0;
  v_updated integer := 0;
begin
  with input as (
    select
      coalesce(nullif(btrim(d->>'title'), ''), '') as title,
      nullif(btrim(d->>'option'), '') as option,
      d->>'subject' as subject,
      d->>'brand' as brand,
      d->>'book_type' as book_type,
      nullif(d->>'published_year', '')::int as published_year,
      nullif(btrim(d->>'instructor_name'), '') as instructor_name,
      nullif(btrim(d->>'cover_image_url'), '') as cover_image_url,
      coalesce(d->>'status', 'selling') as status
    from jsonb_array_elements(p_payload) as d
    where coalesce(nullif(btrim(d->>'title'), ''), '') <> ''
  ),
  upserted as (
    insert into public.products (
      group_key, title, option, subject, brand, book_type,
      published_year, instructor_name, cover_image_url, status
    )
    select
      public.storefront_product_group_key(
        title, option, subject, brand, book_type, published_year, instructor_name
      ),
      title, option, subject, brand, book_type,
      published_year, instructor_name, cover_image_url, status
    from input
    on conflict (group_key) do update
      set
        cover_image_url = coalesce(excluded.cover_image_url, public.products.cover_image_url),
        status = excluded.status,
        updated_at = now()
    returning (xmax = 0) as is_inserted
  )
  select
    count(*) filter (where is_inserted),
    count(*) filter (where not is_inserted)
  into v_inserted, v_updated
  from upserted;

  return jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
end;
$$;

-- service_role만 호출 가능
revoke execute on function public.admin_bulk_upsert_products_sixshop(jsonb) from public;
revoke execute on function public.admin_bulk_upsert_products_sixshop(jsonb) from anon;
revoke execute on function public.admin_bulk_upsert_products_sixshop(jsonb) from authenticated;
