-- 찜한 상품이 품절되는 순간 찜 사용자에게 인앱 알림 (재입고 알림 신청 유도)
--
-- 배경: 품절 상품은 스토어 목록에서 사라지므로(list_public_store_products가
-- 판매가능 책이 있는 상품만 반환) 사용자가 재입고 알림 신청 동선에 도달하기
-- 어렵다. 찜해 둔 사용자에게 품절 시점에 인앱 알림을 보내 상세 페이지의
-- "재입고 알림 받기" 신청으로 잇는다.
--
-- 설계:
-- - books.status/is_public 변경의 모든 경로(결제 확인, 관리자 처리, 수동정산 등)를
--   한 지점에서 잡기 위해 DB 트리거 사용.
-- - "판매가능 → 불가"로 바뀐 책의 product에 판매가능 책이 0권이 된 경우만 발송
--   (해당 row가 직전까지 판매가능이었으므로 = 방금 품절 전환).
-- - 이미 재입고 알림을 구독한 사용자는 제외(이미 유도할 액션을 마침).
-- - 다중 row UPDATE(한 문장에서 여러 권 판매)와 품절 반복 대비 1시간 dedup.
-- - 인앱 알림 전용. 카카오 알림톡은 명시 신청자(restock_notifications)에게만
--   발송한다는 정책과 무관하게 유지된다.

begin;

create or replace function public.notify_wishlist_on_product_soldout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_was_available boolean;
  v_is_available boolean;
  v_product_title text;
begin
  v_was_available := (old.status = 'on_sale' and old.is_public);
  v_is_available := (new.status = 'on_sale' and new.is_public);

  -- "판매가능 → 불가"로 바뀐 책만 관심
  if not v_was_available or v_is_available then
    return new;
  end if;

  if new.product_id is null then
    return new;
  end if;

  -- 상품에 아직 판매가능 책이 남아 있으면 품절 아님
  if exists (
    select 1
    from public.books b
    where b.product_id = new.product_id
      and b.status = 'on_sale'
      and b.is_public = true
  ) then
    return new;
  end if;

  select p.title into v_product_title
  from public.products p
  where p.id = new.product_id;

  insert into public.member_notifications (user_id, type, title, body, ref_url, ref_type, ref_id)
  select
    w.user_id,
    'wishlist_soldout',
    '찜한 교재가 품절됐어요',
    format(
      '찜하신 "%s"이(가) 품절되었습니다. 재입고 알림을 신청하시면 다시 입고될 때 알려드릴게요.',
      coalesce(v_product_title, '교재')
    ),
    '/store/' || new.product_id,
    'product',
    new.product_id
  from public.wishlist_items w
  where w.product_id = new.product_id
    -- 이미 재입고 알림을 신청한 사용자는 제외
    and not exists (
      select 1
      from public.restock_notifications rn
      where rn.user_id = w.user_id
        and rn.product_id = new.product_id
        and rn.notified_at is null
    )
    -- 같은 문장에서 여러 권이 동시에 팔리거나 품절이 반복될 때 중복 방지
    and not exists (
      select 1
      from public.member_notifications mn
      where mn.user_id = w.user_id
        and mn.type = 'wishlist_soldout'
        and mn.ref_id = new.product_id
        and mn.created_at > now() - interval '1 hour'
    );

  return new;
end;
$$;

drop trigger if exists trg_books_wishlist_soldout on public.books;
create trigger trg_books_wishlist_soldout
  after update of status, is_public on public.books
  for each row
  when (old.status is distinct from new.status or old.is_public is distinct from new.is_public)
  execute function public.notify_wishlist_on_product_soldout();

commit;
