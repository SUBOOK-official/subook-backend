-- 쿠폰 운영 분류는 발급/할인/정산 정책과 별도로 관리한다.
create table public.admin_coupon_tags (
  coupon_id bigint primary key references public.coupons(id) on delete cascade,
  category text not null default 'general' check(category in ('general','campaign','cs','test')),
  campaign text not null default '' check(length(campaign)<=120)
);
alter table public.admin_coupon_tags enable row level security;
revoke all on public.admin_coupon_tags from public,anon,authenticated;
grant select,insert,update on public.admin_coupon_tags to authenticated;
create policy coupon_tags_admin_read on public.admin_coupon_tags for select to authenticated using(public.is_admin_user());
create policy coupon_tags_admin_insert on public.admin_coupon_tags for insert to authenticated with check(public.is_admin_user());
create policy coupon_tags_admin_update on public.admin_coupon_tags for update to authenticated using(public.is_admin_user()) with check(public.is_admin_user());

create function public.admin_list_work_coupons(p_search text default '',p_only_active boolean default false,p_limit integer default 50,p_offset integer default 0,p_category text default '',p_availability text default '')
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  with labelled as (
    select c.*,coalesce(t.category,'general') as category,coalesce(t.campaign,'') as campaign,
      case when not c.is_active then 'inactive' when c.valid_until <= now() then 'expired' when c.valid_from > now() then 'scheduled'
        when c.total_quantity is not null and c.issued_count>=c.total_quantity then 'exhausted' else 'available' end as availability
    from public.coupons c left join public.admin_coupon_tags t on t.coupon_id=c.id
    where (not p_only_active or c.is_active) and (p_search='' or c.title ilike '%'||p_search||'%' or c.code ilike '%'||p_search||'%' or t.campaign ilike '%'||p_search||'%')
  ), filtered as (
    select * from labelled where (p_category='' or category=p_category) and (p_availability='' or availability=p_availability)
  ) select jsonb_build_object('total_count',(select count(*) from filtered),'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select * from filtered order by created_at desc,id desc limit greatest(1,least(p_limit,200)) offset greatest(p_offset,0)) t),'[]')) into v_result;
  return v_result;
end $$;
revoke all on function public.admin_list_work_coupons(text,boolean,integer,integer,text,text) from public,anon;
grant execute on function public.admin_list_work_coupons(text,boolean,integer,integer,text,text) to authenticated;
notify pgrst,'reload schema';
