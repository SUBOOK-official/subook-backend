-- 배너 문구만 별도 저장한다. 상품/재고/기존 AI 요약은 수정하지 않는다.
-- 롤백: Vercel 배너 cron을 제거하고 프런트 fallback으로 복귀한다. 캐시는 보존 가능.
create table public.banner_copy_cache (
  product_id bigint primary key references public.products(id) on delete cascade,
  source_hash text,
  copy text check (char_length(copy) between 1 and 20 and copy !~ E'[\n\r<>]'),
  generated_at timestamptz,
  lease_token uuid,
  locked_until timestamptz,
  next_attempt_at timestamptz
);
alter table public.banner_copy_cache enable row level security;
revoke all on public.banner_copy_cache from public, anon, authenticated;
grant all on public.banner_copy_cache to service_role;

-- 원문 비교는 DB에서 일관되게 수행한다. 가격·재고·추천 순서만 바뀌면 재생성하지 않는다.
-- 프롬프트/모델 변경 시 이 버전도 새 migration으로 올린다.
create function public.banner_copy_source_hash(p public.products)
returns text language sql immutable set search_path = '' as $$
  select md5('v2:gemini-3.8-flash:' || jsonb_build_array(p.title,p.subject,p.brand,p.book_type,p.ai_summary)::text);
$$;
revoke all on function public.banner_copy_source_hash(public.products) from public, anon, authenticated;
grant execute on function public.banner_copy_source_hash(public.products) to service_role;

create function public.get_banner_copy_sources()
returns table(id bigint,title text,subject text,brand text,book_type text,ai_summary text,source_hash text)
language sql stable security definer set search_path = '' as $$
  select p.id,p.title::text,p.subject::text,p.brand::text,p.book_type::text,p.ai_summary,
    public.banner_copy_source_hash(p)
  from public.list_public_store_products(p_sort=>'recommended',p_limit=>13,p_offset=>0) r
  join public.products p on p.id=r.id;
$$;
revoke all on function public.get_banner_copy_sources() from public, anon, authenticated;
grant execute on function public.get_banner_copy_sources() to service_role;

create function public.get_public_banner_copies()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('product_id',s.id,'copy',c.copy)), '[]'::jsonb)
  from public.get_banner_copy_sources() s
  join public.banner_copy_cache c on c.product_id=s.id and c.source_hash=s.source_hash
  where c.copy is not null;
$$;
revoke all on function public.get_public_banner_copies() from public;
grant execute on function public.get_public_banner_copies() to anon, authenticated, service_role;

create function public.claim_banner_copy(p_product_id bigint,p_source_hash text,p_token uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare claimed bigint;
begin
  -- 조회 이후 원문이 바뀌었으면 오래된 정보로 생성을 시작하지 않는다.
  if p_token is null or not exists (
    select 1 from public.products p where p.id=p_product_id and public.banner_copy_source_hash(p)=p_source_hash
  ) then return false; end if;
  insert into public.banner_copy_cache(product_id,lease_token,locked_until,next_attempt_at)
    values(p_product_id,p_token,now()+interval '5 minutes',now()+interval '1 hour')
  on conflict(product_id) do update
    set lease_token=excluded.lease_token,locked_until=excluded.locked_until,next_attempt_at=excluded.next_attempt_at
    where (banner_copy_cache.source_hash is distinct from p_source_hash or banner_copy_cache.copy is null)
      and coalesce(banner_copy_cache.locked_until,'-infinity'::timestamptz)<now()
      and coalesce(banner_copy_cache.next_attempt_at,'-infinity'::timestamptz)<now()
  returning product_id into claimed;
  return claimed is not null;
end;
$$;
revoke all on function public.claim_banner_copy(bigint,text,uuid) from public, anon, authenticated;
grant execute on function public.claim_banner_copy(bigint,text,uuid) to service_role;

create function public.finish_banner_copy(p_product_id bigint,p_source_hash text,p_token uuid,p_copy text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare saved bigint;
begin
  -- 생성 중 원문 변경/다른 작업자의 잠금 획득 시 오래된 결과를 덮어쓰지 않는다.
  perform 1 from public.products p where p.id=p_product_id and public.banner_copy_source_hash(p)=p_source_hash for share;
  if not found then
    update public.banner_copy_cache set lease_token=null,locked_until=null,next_attempt_at=null
      where product_id=p_product_id and lease_token=p_token;
    return false;
  end if;
  update public.banner_copy_cache set copy=p_copy,source_hash=p_source_hash,generated_at=now(),
    lease_token=null,locked_until=null,next_attempt_at=null
    where product_id=p_product_id and lease_token=p_token
    returning product_id into saved;
  return saved is not null;
end;
$$;
revoke all on function public.finish_banner_copy(bigint,text,uuid,text) from public, anon, authenticated;
grant execute on function public.finish_banner_copy(bigint,text,uuid,text) to service_role;
