-- check_member_nickname_availability: 닉네임 중복확인 RPC (누락 보강).
--
-- 프론트(memberPortal.js)는 이 RPC를 호출하지만 어떤 마이그레이션에도 정의가 없었다
-- (드리프트가 아니라 처음부터 안 만들어진 코드/마이그 갭). RPC가 404라 프론트는
-- member_profiles 직접 조회로 fallback하는데, member_profiles RLS(select_self: 본인 행만)
-- 때문에 다른 회원 닉네임을 못 봐서 항상 "사용 가능"으로 잘못 응답 → 닉네임 중복이
-- 사실상 검사되지 않았다. RLS를 우회하는 security definer 함수로 정확히 검사한다.
--
-- 반환: 프론트는 rpcRow.is_available(boolean)을 읽음 → returns table(is_available boolean).
-- 비교: 프론트는 trim만(대소문자 보존) → 혼동 방지 위해 대소문자 무시로 비교. 본인/탈퇴회원 제외.

create or replace function public.check_member_nickname_availability(p_nickname text)
returns table (is_available boolean)
language sql
stable
security definer
set search_path = public
as $$
  select case
    when nullif(btrim(coalesce(p_nickname, '')), '') is null then false
    else not exists (
      select 1
      from public.member_profiles mp
      where lower(btrim(mp.nickname)) = lower(btrim(p_nickname))
        and mp.user_id is distinct from auth.uid()
        and mp.personal_data_erased_at is null
    )
  end as is_available;
$$;

grant execute on function public.check_member_nickname_availability(text) to authenticated;

notify pgrst, 'reload schema';
