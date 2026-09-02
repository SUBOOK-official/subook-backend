-- 통합 후기: 공개 조회에 "구매 교재 목록" 추가 (2026-09-02 피드백)
--
-- "○○○ 외 2권" 후기를 눌렀을 때 대표 교재 하나로 넘어가지 않고 구매한 교재 전체를
-- 보여주기 위해 get_public_reviews 각 항목에 items(상품별 제목·표지·권수)를 붙인다.
-- 스냅샷 컬럼을 늘리지 않고 order_items에서 읽는다(환불된 품목 제외, 상품 단위로 묶음).

begin;

create or replace function public.get_public_reviews(
  p_product_id bigint default null,
  p_limit integer default 10,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint;
  v_average numeric;
  v_counts jsonb;
  v_same_count bigint := 0;
  v_items jsonb;
begin
  select count(*), round(avg(rating)::numeric, 1)
  into v_total, v_average
  from public.reviews
  where is_hidden = false;

  select coalesce(jsonb_object_agg(rating::text, cnt), '{}'::jsonb)
  into v_counts
  from (
    select rating, count(*) as cnt
    from public.reviews
    where is_hidden = false
    group by rating
  ) c;

  if p_product_id is not null then
    select count(*) into v_same_count
    from public.reviews
    where is_hidden = false
      and product_ids @> array[p_product_id];
  end if;

  select coalesce(jsonb_agg(row_data), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', r.id,
      'author', public.mask_review_nickname(coalesce(mp.nickname, mp.name)),
      'rating', r.rating,
      'content', r.content,
      'photo_urls', to_jsonb(r.photo_urls),
      'product_id', r.primary_product_id,
      'product_title', r.primary_title,
      'item_count', r.item_count,
      'is_same_product', (p_product_id is not null and r.product_ids @> array[p_product_id]),
      'created_at', r.created_at,
      -- 구매 교재 목록: 상품 단위로 묶고(같은 교재 여러 권 → quantity 합산), 환불 품목 제외
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', g.product_id,
          'title', g.title,
          'cover_image_url', g.cover_image_url,
          'quantity', g.quantity
        ) order by g.first_id)
        from (
          select
            oi.product_id,
            min(oi.title) as title,
            min(oi.cover_image_url) as cover_image_url,
            sum(greatest(coalesce(oi.quantity, 1), 1))::integer as quantity,
            min(oi.id) as first_id
          from public.order_items oi
          where oi.order_id = r.order_id
            and oi.refunded_at is null
          group by oi.product_id, oi.title
        ) g
      ), '[]'::jsonb)
    ) as row_data
    from public.reviews r
    left join public.member_profiles mp on mp.user_id = r.user_id
    where r.is_hidden = false
    order by
      (p_product_id is not null and r.product_ids @> array[p_product_id]) desc,
      r.created_at desc,
      r.id desc
    limit v_limit offset v_offset
  ) sub;

  return jsonb_build_object(
    'total', coalesce(v_total, 0),
    'average', v_average,
    'rating_counts', v_counts,
    'same_product_count', v_same_count,
    'items', v_items
  );
end;
$$;

grant execute on function public.get_public_reviews(bigint, integer, integer) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
