-- FAQ display_order는 1 이상만 허용.
-- 사용자 요청: 어드민에서 음수/0도 입력 가능했던 걸 1부터 강제.
--
-- 변경:
--   1. faqs.display_order default 0 → 1
--   2. CHECK constraint (display_order >= 1) 추가
--   3. admin_upsert_faq에서 validation
--   4. 백필: 이미 0/음수인 row가 있다면 1로 (사전 점검 결과 0건, 안전)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 기존 0/음수 row 백필 (사전 점검 결과 0건)
-- ─────────────────────────────────────────────────────────────────────────────
update public.faqs set display_order = 1 where display_order < 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) default 1, CHECK constraint 추가
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.faqs alter column display_order set default 1;

alter table public.faqs drop constraint if exists faqs_display_order_check;
alter table public.faqs add constraint faqs_display_order_check check (display_order >= 1);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) admin_upsert_faq: server-side validation
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_upsert_faq(
  p_id bigint default null,
  p_category text default null,
  p_question text default '',
  p_answer text default '',
  p_display_order integer default 1,
  p_is_published boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_q text := nullif(btrim(coalesce(p_question, '')), '');
  v_a text := nullif(btrim(coalesce(p_answer, '')), '');
  v_order integer := coalesce(p_display_order, 1);
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if v_q is null then raise exception '질문(question)을 입력해 주세요.'; end if;
  if v_a is null then raise exception '답변(answer)을 입력해 주세요.'; end if;
  if v_order < 1 then
    raise exception '표시 순서는 1 이상이어야 합니다. (입력값: %)', v_order;
  end if;

  if p_id is null then
    insert into public.faqs (category, question, answer, display_order, is_published)
    values (nullif(btrim(coalesce(p_category, '')), ''), v_q, v_a,
            v_order, coalesce(p_is_published, true))
    returning id into v_id;
  else
    update public.faqs
    set category = nullif(btrim(coalesce(p_category, '')), ''),
        question = v_q,
        answer = v_a,
        display_order = v_order,
        is_published = coalesce(p_is_published, is_published)
    where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'FAQ를 찾을 수 없습니다.'; end if;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_faq(bigint, text, text, text, integer, boolean) to authenticated;

commit;
