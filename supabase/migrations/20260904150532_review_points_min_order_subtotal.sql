-- 후기 포인트는 환불되지 않은 상품금액이 10,000원 이상인 주문에만 지급한다.
-- 후기 작성 자체는 금액과 무관하게 계속 허용한다.

begin;

create or replace function public.point_policy()
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'earn_text', 500,
    'earn_photo', 1000,
    'min_review_order_subtotal', 10000,
    'min_balance_to_use', 1000,
    'min_order_subtotal', 15000,
    'max_use_ratio', 0.2,
    'expiry_months', 12
  );
$$;

grant execute on function public.point_policy() to anon, authenticated;

create or replace function public.create_review(
  p_order_id bigint,
  p_rating integer,
  p_content text,
  p_photo_urls text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order record;
  v_items record;
  v_input record;
  v_review public.reviews%rowtype;
  v_policy jsonb := public.point_policy();
  v_earn integer := 0;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  perform public.assert_member_not_blocked();

  select o.id, o.status
  into v_order
  from public.orders o
  where o.id = p_order_id
    and o.user_id = v_user_id
  limit 1;

  if not found then
    raise exception '주문을 찾을 수 없어요.';
  end if;
  if v_order.status <> 'confirmed' then
    raise exception '구매확정 후에 후기를 작성할 수 있어요.';
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
  into v_items
  from public.order_items oi
  where oi.order_id = p_order_id
    and oi.refunded_at is null;

  if v_items.item_count is null or v_items.item_count < 1 or v_items.primary_title is null then
    raise exception '환불된 주문에는 후기를 남길 수 없어요.';
  end if;

  insert into public.reviews (
    user_id, order_id, rating, content, photo_urls,
    product_ids, primary_product_id, primary_title, item_count
  ) values (
    v_user_id, p_order_id, v_input.rating, v_input.content, v_input.photo_urls,
    v_items.product_ids, v_items.primary_product_id, v_items.primary_title, v_items.item_count
  )
  returning * into v_review;

  -- 환불되지 않은 상품금액이 10,000원 이상일 때만 후기 포인트를 지급한다.
  if v_items.reward_subtotal >= (v_policy->>'min_review_order_subtotal')::integer then
    v_earn := case
      when coalesce(cardinality(v_review.photo_urls), 0) > 0 then (v_policy->>'earn_photo')::integer
      else (v_policy->>'earn_text')::integer
    end;
    perform public.grant_points(
      v_user_id, v_earn, 'review', 'review_earn',
      p_review_id => v_review.id,
      p_order_id => p_order_id,
      p_note => case when coalesce(cardinality(v_review.photo_urls), 0) > 0 then '사진 후기 작성' else '후기 작성' end
    );
  end if;

  return jsonb_build_object(
    'id', v_review.id,
    'order_id', v_review.order_id,
    'rating', v_review.rating,
    'content', v_review.content,
    'photo_urls', to_jsonb(v_review.photo_urls),
    'product_title', v_review.primary_title,
    'item_count', v_review.item_count,
    'is_hidden', v_review.is_hidden,
    'created_at', v_review.created_at,
    'updated_at', v_review.updated_at,
    'earned_points', v_earn
  );
end;
$$;

commit;

notify pgrst, 'reload schema';

-- Rollback: point_policy()에서 min_review_order_subtotal을 제거하고,
-- create_review()를 20260902111905_member_points.sql 정의로 복원한다.
