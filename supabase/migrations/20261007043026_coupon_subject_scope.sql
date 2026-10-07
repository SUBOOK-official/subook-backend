-- 과목 미지정(NULL)은 기존 쿠폰과 동일. 브랜드·과목을 모두 지정하면 AND 조건.
-- 기존 coupons/member_coupons RLS와 RPC 권한은 그대로 유지한다.
-- 롤백: 새 과목 제한 쿠폰을 먼저 비활성화하고 이 migration의 함수 교체만 역적용.
-- 컬럼은 보존하여 운영자가 설정한 제한을 잃지 않는다.
alter table public.coupons add column scope_subject text
  constraint coupons_scope_subject_check
  check (scope_subject in ('국어', '수학', '영어', '과학', '사회', '한국사', '기타'));
comment on column public.coupons.scope_subject is
  '사용 가능 교재 과목. NULL은 전체 과목, scope_brand와 동시 지정 시 두 조건 모두 일치해야 적용.';

-- 현재 정의의 쿠폰 관련 구문만 교체한다. 포인트·게스트·환불 재고 가드 및 ACL 보존.
do $migration$
declare
  patch record;
  definition text;
begin
  for patch in select * from (values
    ('admin_create_coupon', $old$    scope_brand,
    created_by$old$, $new$    scope_brand,
    scope_subject,
    created_by$new$),
    ('admin_create_coupon', $old$    nullif(trim(p_payload->>'scope_brand'), ''),
    auth.uid()$old$, $new$    nullif(trim(p_payload->>'scope_brand'), ''),
    nullif(trim(p_payload->>'scope_subject'), ''),
    auth.uid()$new$),
    ('admin_update_coupon', $old$      else scope_brand end$old$, $new$      else scope_brand end,
    scope_subject = case when p_payload ? 'scope_subject'
      then nullif(trim(p_payload->>'scope_subject'), '')
      else scope_subject end$new$),
    ('get_member_coupons', $old$      'min_order_amount', c.min_order_amount,$old$, $new$      'min_order_amount', c.min_order_amount,
      'scope_brand', c.scope_brand,
      'scope_subject', c.scope_subject,$new$),
    ('create_order_core', $old$  v_discount integer := 0;$old$, $new$  v_discount integer := 0;
  v_scope_subtotal integer := 0;
  v_scope_count integer := 0;$new$),
    ('create_order_core', $old$    if v_coupon.min_order_amount > v_subtotal then
      raise exception '최소 주문 금액(%원)을 만족하지 않습니다.', v_coupon.min_order_amount;
    end if;$old$, $new$    v_scope_subtotal := v_subtotal;
    if v_coupon.scope_brand is not null or v_coupon.scope_subject is not null then
      select coalesce(sum(b.price), 0), count(*) into v_scope_subtotal, v_scope_count
      from public.books b
      where b.id = any(p_book_ids)
        and (v_coupon.scope_brand is null or b.brand = v_coupon.scope_brand)
        and (v_coupon.scope_subject is null or b.subject = v_coupon.scope_subject);
      if v_scope_count = 0 then
        raise exception '이 쿠폰은 % 교재에만 사용할 수 있습니다.',
          concat_ws(' · ', v_coupon.scope_brand, v_coupon.scope_subject);
      end if;
    end if;
    if v_coupon.min_order_amount > v_scope_subtotal then
      raise exception '쿠폰 적용 대상 교재의 최소 주문 금액(%원)을 만족하지 않습니다.', v_coupon.min_order_amount;
    end if;$new$),
    ('create_order_core', $old$least(v_coupon.discount_value, v_subtotal)$old$, $new$least(v_coupon.discount_value, v_scope_subtotal)$new$),
    ('create_order_core', $old$(v_subtotal * v_coupon.discount_value) / 100$old$, $new$(v_scope_subtotal * v_coupon.discount_value) / 100$new$)
  ) as patches(function_name, old_text, new_text)
  loop
    select pg_get_functiondef(oid) into strict definition from pg_proc
    where pronamespace = 'public'::regnamespace and proname = patch.function_name;
    if (length(definition) - length(replace(definition, patch.old_text, ''))) / length(patch.old_text) <> 1 then
      raise exception 'Expected exactly one coupon patch in %; inspect current definition', patch.function_name;
    end if;
    execute replace(definition, patch.old_text, patch.new_text);
  end loop;
end;
$migration$;

create or replace function public.get_applicable_coupons(p_subtotal integer default 0, p_book_ids bigint[] default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
  v_free_shipping_threshold integer := 50000;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'issued_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', mc.id,
      'coupon_id', mc.coupon_id,
      'title', c.title,
      'description', c.description,
      'discount_type', c.discount_type,
      'discount_value', c.discount_value,
      'max_discount_amount', c.max_discount_amount,
      'min_order_amount', c.min_order_amount,
      'scope_brand', c.scope_brand,
      'scope_subject', c.scope_subject,
      'eligible_subtotal', case when c.scope_brand is null and c.scope_subject is null
        then p_subtotal else eligible.subtotal end,
      'expires_at', mc.expires_at,
      'issued_at', mc.issued_at
    ) as row_data
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    cross join lateral (
      select coalesce(sum(b.price), 0) as subtotal, count(*) as item_count
      from public.books b
      where b.id = any(p_book_ids)
        and (c.scope_brand is null or b.brand = c.scope_brand)
        and (c.scope_subject is null or b.subject = c.scope_subject)
    ) eligible
    where mc.user_id = v_user_id
      and mc.status = 'available'
      and (mc.expires_at is null or mc.expires_at >= now())
      and c.is_active = true
      and case when c.scope_brand is null and c.scope_subject is null
        then c.min_order_amount <= p_subtotal
        else eligible.item_count > 0 and c.min_order_amount <= eligible.subtotal
      end
      and (c.discount_type <> 'free_shipping' or p_subtotal < v_free_shipping_threshold)
      and (c.usage_limit_per_user is null or (
        select count(*) from public.member_coupons mc2
        where mc2.user_id = v_user_id and mc2.coupon_id = c.id and mc2.status = 'used'
      ) < c.usage_limit_per_user)
  ) sub;
  return v_result;
end;
$function$;

notify pgrst, 'reload schema';
