-- 재입고 "키워드" 알림 구독 (감사 P1 — 재입고 진입점 통일의 백엔드)
--
-- 기존 재입고 알림은 상품 단위(restock_notifications, 품절 상품 상세에서 신청)뿐이라
-- "아직 입고된 적 없는 교재"를 기다리는 수요를 받을 곳이 없었다 (그리드/검색
-- 빈결과의 '입고 알림' CTA가 카카오 채널·읽기전용 알림함으로 흩어져 있던 원인).
-- 키워드 구독은 신규 입고 시 products.search_text(FTS 컬럼 재사용) 매칭으로
-- 인앱 알림(member_notifications, type='restock')을 보낸다.
-- 부수 효과: 키워드 수요 자체가 "무엇을 더 수거·매입할지" 공급 데이터가 된다.
--
-- 카카오 알림톡은 보내지 않는다 — 찜/관심 기반 알림톡은 템플릿 반려 이력 있는
-- 광고성 분류(프로젝트 정책). 인앱 한정.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 구독 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.restock_keyword_subscriptions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  keyword text not null,
  -- 매칭용 정규화(소문자·공백 1칸) — products.search_text와 같은 규칙
  keyword_norm text not null,
  created_at timestamptz not null default now(),
  unique (user_id, keyword_norm)
);

create index if not exists idx_restock_keyword_subs_user
  on public.restock_keyword_subscriptions (user_id, created_at desc);

alter table public.restock_keyword_subscriptions enable row level security;

drop policy if exists restock_keyword_subs_own on public.restock_keyword_subscriptions;
create policy restock_keyword_subs_own
  on public.restock_keyword_subscriptions for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 구독 RPC (등록 / 목록 / 해지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.subscribe_restock_keyword(p_keyword text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_keyword text;
  v_norm text;
  v_count integer;
  v_id bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  v_keyword := btrim(coalesce(p_keyword, ''));
  v_norm := lower(regexp_replace(v_keyword, '\s+', ' ', 'g'));

  if char_length(v_norm) < 2 or char_length(v_norm) > 40 then
    raise exception '키워드는 2~40자로 입력해 주세요.';
  end if;

  select count(*) into v_count
  from public.restock_keyword_subscriptions
  where user_id = v_user_id;
  if v_count >= 20 then
    raise exception '키워드 알림은 최대 20개까지 등록할 수 있어요.';
  end if;

  insert into public.restock_keyword_subscriptions (user_id, keyword, keyword_norm)
  values (v_user_id, v_keyword, v_norm)
  on conflict (user_id, keyword_norm) do update set keyword = excluded.keyword
  returning id into v_id;

  return jsonb_build_object('success', true, 'id', v_id, 'keyword', v_keyword);
end;
$$;

create or replace function public.list_my_restock_keywords()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('id', s.id, 'keyword', s.keyword, 'created_at', s.created_at)
      order by s.created_at desc),
    '[]'::jsonb
  )
  from public.restock_keyword_subscriptions s
  where s.user_id = auth.uid();
$$;

create or replace function public.unsubscribe_restock_keyword(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  delete from public.restock_keyword_subscriptions
  where id = p_id and user_id = auth.uid();

  return jsonb_build_object('success', true, 'deleted', found);
end;
$$;

grant execute on function public.subscribe_restock_keyword(text) to authenticated;
grant execute on function public.list_my_restock_keywords() to authenticated;
grant execute on function public.unsubscribe_restock_keyword(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 입고 매칭 트리거 — 상품이 "구매 가능"해지는 순간 키워드 구독자에게 인앱 알림
--    (wishlist_soldout 트리거와 동형. 상품당 1회 dedupe.)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_restock_keyword_on_book_available()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_was_available boolean;
  v_is_available boolean;
  v_product_title text;
  v_search_text text;
begin
  v_is_available := (new.status = 'on_sale' and new.is_public = true);
  if not v_is_available then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    v_was_available := (old.status = 'on_sale' and old.is_public = true);
    if v_was_available then
      return new;
    end if;
  end if;

  if new.product_id is null then
    return new;
  end if;

  -- 이미 판매가능한 다른 책이 있으면 "재고 추가"일 뿐 입고 알림 아님
  if exists (
    select 1
    from public.books b
    where b.product_id = new.product_id
      and b.id <> new.id
      and b.status = 'on_sale'
      and b.is_public = true
  ) then
    return new;
  end if;

  select p.title, lower(regexp_replace(coalesce(p.search_text, ''), '\s+', ' ', 'g'))
  into v_product_title, v_search_text
  from public.products p
  where p.id = new.product_id;

  if coalesce(v_search_text, '') = '' then
    return new;
  end if;

  insert into public.member_notifications (user_id, type, title, body, ref_url, ref_type, ref_id)
  select
    s.user_id,
    'restock',
    '찾으시던 교재가 입고됐어요',
    format(
      '"%s" 키워드로 신청하신 입고 알림 — "%s"이(가) 입고되었습니다.',
      s.keyword,
      coalesce(v_product_title, '교재')
    ),
    '/store/' || new.product_id,
    'product',
    new.product_id
  from public.restock_keyword_subscriptions s
  where position(s.keyword_norm in v_search_text) > 0
    -- 같은 상품으로는 사용자당 1회만 (재고가 오르내려도 반복 발송 금지)
    and not exists (
      select 1
      from public.member_notifications mn
      where mn.user_id = s.user_id
        and mn.type = 'restock'
        and mn.ref_type = 'product'
        and mn.ref_id = new.product_id
    );

  return new;
end;
$$;

drop trigger if exists trg_books_restock_keyword on public.books;
create trigger trg_books_restock_keyword
  after insert or update of status, is_public on public.books
  for each row
  execute function public.notify_restock_keyword_on_book_available();

notify pgrst, 'reload schema';
