-- 출시 전(pre-release) 상품 주문 차단 (2026-08-31)
--
-- 전일학원 콜라보 교재처럼 "스토어에는 노출하되 아직 팔지는 않는" 상품이 필요해졌다.
-- 스토어 노출 조건과 주문 가능 조건이 둘 다 books(status='on_sale' AND is_public)라
-- DB만으로는 둘을 분리할 수 없어, 주문 경로에만 걸리는 가드를 따로 둔다.
--
-- 프론트(public-web src/lib/publicFeaturedProducts.js preRelease 플래그)가 가격·구매
-- 버튼을 감추지만 그건 UI일 뿐이라, RPC를 직접 호출하면 주문이 만들어질 수 있다.
-- ⚠ 두 곳은 짝으로 유지할 것 — 오픈일에 preRelease=false 로 바꾸면서 이 테이블의
--   해당 row 도 함께 지워야 실제 판매가 열린다.
--
-- create_order_core / add_to_cart 를 건드리지 않는 additive 방식이다
-- (두 함수는 유지해야 할 가드가 많아 재정의 위험이 크다).

begin;

create table if not exists public.pre_release_products (
  product_id bigint primary key references public.products(id) on delete cascade,
  note text,
  created_at timestamptz not null default now()
);

comment on table public.pre_release_products is
  '출시 전 상품 — 스토어에는 노출되지만 장바구니·주문을 막는다. 오픈 시 row 삭제. '
  '프론트 publicFeaturedProducts.js 의 preRelease 플래그와 짝으로 관리할 것.';

-- 서버측 가드 전용 테이블이라 클라이언트 조회가 필요 없다 (정책 없이 RLS만 켠다).
alter table public.pre_release_products enable row level security;

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
  where b.id = new.book_id;

  if v_title is not null then
    raise exception '「%」은(는) 아직 판매 시작 전인 상품입니다.', v_title;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_order_items_pre_release on public.order_items;
create trigger trg_order_items_pre_release
  before insert on public.order_items
  for each row
  execute function public.assert_book_not_pre_release();

drop trigger if exists trg_cart_items_pre_release on public.cart_items;
create trigger trg_cart_items_pre_release
  before insert on public.cart_items
  for each row
  execute function public.assert_book_not_pre_release();

commit;
