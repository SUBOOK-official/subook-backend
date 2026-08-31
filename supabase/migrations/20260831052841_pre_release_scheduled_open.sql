-- 출시 전 상품 — 오픈 시각 예약 (2026-08-31)
--
-- 전일학원 콜라보 오픈이 2026-09-03 18:00 KST 로 정해졌다. 그 시각에 사람이 직접
-- 플래그를 풀거나 크론이 돌지 않아도 스스로 열리도록, 가드가 release_at 을 보고
-- 판단하게 바꾼다.
--   · release_at 이 NULL  → 계속 차단 (수동으로 row 를 지울 때까지)
--   · now() < release_at → 차단
--   · now() >= release_at → 통과 (row 를 남겨둬도 판매가 열린다)
--
-- pg_cron 잡을 쓰지 않은 이유: 잡 실패/누락 위험이 없고, 데드맨 스위치의
-- v_expected 목록도 건드릴 필요가 없다. 시각 비교만으로 원자적으로 열린다.
--
-- ⚠ 프론트(publicFeaturedProducts.js COLLAB_OPEN_AT)에 같은 시각이 들어 있다.
--   오픈 시각을 바꾸면 두 곳을 함께 고칠 것.

begin;

alter table public.pre_release_products
  add column if not exists release_at timestamptz;

comment on column public.pre_release_products.release_at is
  '이 시각부터 주문 허용. NULL이면 row 를 지울 때까지 계속 차단. '
  '프론트 publicFeaturedProducts.js 의 COLLAB_OPEN_AT 과 같은 값을 유지할 것.';

create or replace function public.assert_book_not_pre_release()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_title text;
begin
  select p.title
  into v_title
  from public.books b
  join public.pre_release_products pr on pr.product_id = b.product_id
  join public.products p on p.id = b.product_id
  where b.id = new.book_id
    -- 오픈 시각이 지났으면 더 이상 막지 않는다.
    and (pr.release_at is null or now() < pr.release_at);

  if v_title is not null then
    raise exception '「%」은(는) 아직 판매 시작 전인 상품입니다.', v_title;
  end if;

  return new;
end;
$function$;

-- 전일학원 콜라보 2종 오픈 예약
update public.pre_release_products
set release_at = timestamptz '2026-09-03 18:00:00+09'
where product_id in (2370, 2371);

commit;
