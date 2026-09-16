-- 관리자 상품 수정에서 AI 요약을 함께 검수·교정한다.
--
-- 기존 admin_update_product_master는 재고·등급·가격 보호 규칙이 누적된 핵심 함수다.
-- 해당 함수를 다시 정의하지 않고 래퍼에서 호출해, 상품 정보와 AI 요약을 한 트랜잭션으로
-- 저장한다. p_update_ai_summary=false이면 구 동작과 동일하며 기존 요약은 건드리지 않는다.

begin;

create or replace function public.admin_update_product_master_with_ai_summary(
  p_product_id bigint,
  p_title text,
  p_option text default null,
  p_original_price integer default null,
  p_cover_image_url text default null,
  p_books jsonb default '[]'::jsonb,
  p_subject text default null,
  p_brand text default null,
  p_book_type text default null,
  p_ai_summary text default null,
  p_update_ai_summary boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_summary text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 기존 상품 수정 함수가 가진 제목 중복·판매완료 가격·등급 보호 규칙을 그대로 사용한다.
  v_result := public.admin_update_product_master(
    p_product_id,
    p_title,
    p_option,
    p_original_price,
    p_cover_image_url,
    p_books,
    p_subject,
    p_brand,
    p_book_type
  );

  if p_update_ai_summary then
    v_summary := nullif(btrim(coalesce(p_ai_summary, '')), '');

    if v_summary is null or char_length(v_summary) < 40 then
      raise exception 'AI 요약은 40자 이상 입력해 주세요.';
    end if;

    if char_length(v_summary) > 2000 then
      raise exception 'AI 요약은 2,000자 이하로 입력해 주세요.';
    end if;

    update public.products
    set ai_summary = v_summary,
        updated_at = now()
    where id = p_product_id;
  end if;

  return v_result || jsonb_build_object('ai_summary_updated', p_update_ai_summary);
end;
$$;

revoke all on function public.admin_update_product_master_with_ai_summary(
  bigint, text, text, integer, text, jsonb, text, text, text, text, boolean
) from public;

grant execute on function public.admin_update_product_master_with_ai_summary(
  bigint, text, text, integer, text, jsonb, text, text, text, text, boolean
) to authenticated;

comment on function public.admin_update_product_master_with_ai_summary(
  bigint, text, text, integer, text, jsonb, text, text, text, text, boolean
) is '관리자 상품 마스터와 고객 노출 AI 요약을 한 트랜잭션으로 수정';

notify pgrst, 'reload schema';

commit;
