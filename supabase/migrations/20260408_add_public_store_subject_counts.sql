create or replace function public.get_public_store_subject_counts()
returns table (
  subject text,
  count integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.subject,
    count(distinct p.id)::integer as count
  from public.products p
  join public.books b
    on b.product_id = p.id
  where b.status = 'on_sale'
    and b.is_public = true
    and p.subject in ('수학', '국어', '영어', '과학', '사회', '한국사', '기타')
  group by p.subject
  order by
    case p.subject
      when '수학' then 1
      when '국어' then 2
      when '영어' then 3
      when '과학' then 4
      when '사회' then 5
      when '한국사' then 6
      when '기타' then 7
      else 99
    end;
$$;

grant execute on function public.get_public_store_subject_counts() to anon, authenticated;
