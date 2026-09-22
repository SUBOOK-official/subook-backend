-- 배송완료부터 후기 허용. 회원의 첫 직접 작성 후기에만 글 1,000P / 사진 1,500P.
-- 기존 후기(숨김·환불 포함)는 첫 작성 여부에 포함, 별도 이관 후기는 제외한다.
-- 1만원 적립 하한, 기존 후기/RLS·환불 회수·구매확정/정산 흐름은 유지한다.
begin;

create or replace function public.point_policy()
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'earn_text', 500, 'earn_photo', 1000,
    'earn_first_text', 1000, 'earn_first_photo', 1500,
    'min_review_order_subtotal', 10000, 'min_balance_to_use', 1000,
    'min_order_subtotal', 15000, 'max_use_ratio', 0.2, 'expiry_months', 12
  );
$$;

create or replace function public.create_review(
  p_order_id bigint, p_rating integer, p_content text, p_photo_urls text[] default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_order record;
  v_items record;
  v_input record;
  v_review public.reviews%rowtype;
  v_policy jsonb := public.point_policy();
  v_earn integer := 0;
  v_first boolean;
  v_photo boolean;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  perform public.assert_member_not_blocked();

  -- 서로 다른 주문의 동시 첫 후기 요청도 회원별로 직렬화한다.
  -- 트랜잭션 종료 시 자동 해제 (PostgreSQL advisory transaction lock).
  perform pg_advisory_xact_lock(hashtextextended('create_review:' || v_user_id::text, 0));

  select o.id, o.status into v_order
  from public.orders o where o.id = p_order_id and o.user_id = v_user_id
  for update;
  if not found then
    raise exception '주문을 찾을 수 없어요.';
  end if;
  if v_order.status not in ('delivered', 'confirmed') then
    raise exception '배송완료 후에 후기를 작성할 수 있어요.';
  end if;
  if exists (select 1 from public.reviews r where r.order_id = p_order_id) then
    raise exception '이미 후기를 작성한 주문이에요.';
  end if;

  select * into v_input
  from public.normalize_review_input(v_user_id, p_rating, p_content, p_photo_urls);
  select
    (array_agg(oi.title order by oi.id))[1] as primary_title,
    (array_agg(oi.product_id order by oi.id) filter (where oi.product_id is not null))[1] as primary_product_id,
    coalesce(array_agg(distinct oi.product_id) filter (where oi.product_id is not null), '{}'::bigint[]) as product_ids,
    coalesce(sum(greatest(coalesce(oi.quantity, 1), 1)), 0)::integer as item_count,
    coalesce(sum(oi.total_price), 0)::integer as reward_subtotal
  into v_items from public.order_items oi
  where oi.order_id = p_order_id and oi.refunded_at is null;
  if v_items.item_count < 1 or v_items.primary_title is null then
    raise exception '환불된 주문에는 후기를 남길 수 없어요.';
  end if;

  select not exists (select 1 from public.reviews r where r.user_id = v_user_id) into v_first;
  v_photo := coalesce(cardinality(v_input.photo_urls), 0) > 0;
  insert into public.reviews (
    user_id, order_id, rating, content, photo_urls,
    product_ids, primary_product_id, primary_title, item_count
  ) values (
    v_user_id, p_order_id, v_input.rating, v_input.content, v_input.photo_urls,
    v_items.product_ids, v_items.primary_product_id, v_items.primary_title, v_items.item_count
  ) returning * into v_review;

  if v_items.reward_subtotal >= (v_policy->>'min_review_order_subtotal')::integer then
    v_earn := (v_policy->>case
      when v_first and v_photo then 'earn_first_photo'
      when v_first then 'earn_first_text'
      when v_photo then 'earn_photo'
      else 'earn_text' end)::integer;
    perform public.grant_points(
      v_user_id, v_earn, 'review', 'review_earn',
      p_review_id => v_review.id, p_order_id => p_order_id,
      p_note => case when v_first then '첫 ' else '' end ||
        case when v_photo then '사진 후기 작성' else '후기 작성' end
    );
  end if;

  return jsonb_build_object(
    'id', v_review.id, 'order_id', v_review.order_id,
    'rating', v_review.rating, 'content', v_review.content,
    'photo_urls', to_jsonb(v_review.photo_urls), 'product_title', v_review.primary_title,
    'item_count', v_review.item_count, 'is_hidden', v_review.is_hidden,
    'created_at', v_review.created_at, 'updated_at', v_review.updated_at,
    'earned_points', v_earn, 'first_review', v_first
  );
end;
$$;

revoke all on function public.create_review(bigint, integer, text, text[]) from public, anon;
grant execute on function public.create_review(bigint, integer, text, text[]) to authenticated;
commit;
notify pgrst, 'reload schema';
-- Rollback: 새 migration에서 20260904150532의 point_policy/create_review 정의 복원.
-- 이미 지급한 포인트는 회수하지 않는다. 기존 RLS·권한은 변경하지 않는다.
