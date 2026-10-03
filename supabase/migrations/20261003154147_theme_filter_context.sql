-- 테마별 소개·필터 문맥. 선정 교재·공개 판정·정렬·RLS는 그대로 유지한다.
-- https://supabase.com/docs/guides/database/postgres/row-level-security
-- 롤백: 프론트 이전 버전을 배포한다. 추가 메타데이터와 운영 교재 목록은 보존한다.

create function public.valid_theme_filter_context(context jsonb)
returns boolean language sql immutable set search_path = public as $$
  select case when context is null or jsonb_typeof(context) <> 'object' then false
    else not exists (
      select 1 from jsonb_each(context) item
      where item.key not in ('brands', 'types', 'years', 'subject')
        or jsonb_typeof(item.value) <> 'string'
        or length(btrim(item.value #>> '{}')) not between 1 and 60
    ) end;
$$;
revoke all on function public.valid_theme_filter_context(jsonb) from public;
grant execute on function public.valid_theme_filter_context(jsonb) to anon, authenticated, service_role;

alter table public.content_themes
  add column description text not null default '' check (length(description) <= 120),
  add column filter_context jsonb not null default '{}'::jsonb
    check (public.valid_theme_filter_context(filter_context));

comment on column public.content_themes.filter_context is
  '고정된 탐색 조건: 해당 필터와 URL 선택만 숨긴다. product_ids를 제한하거나 교재를 삭제하지 않는다.';

-- 기존 테이블의 themes_public_read/themes_admin_all 정책이 새 컬럼에도 적용된다.
-- 기존 RPC 정의에서 메타데이터만 확장해 현재 상품 공개·품절·페이지 상한을 보존한다.
do $migration$
declare
  definition text;
  fragment text := '''image_url'', theme.image_url';
begin
  definition := pg_get_functiondef('public.get_public_theme_page(uuid,integer,integer)'::regprocedure);
  if position(fragment in definition) = 0 then
    raise exception 'get_public_theme_page metadata fragment not found';
  end if;
  execute replace(definition, fragment,
    fragment || ', ''description'', theme.description, ''filter_context'', theme.filter_context');
end;
$migration$;

notify pgrst, 'reload schema';
