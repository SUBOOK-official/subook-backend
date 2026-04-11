-- Extend books so the storefront can read real saleable inventory without
-- introducing the full products/orders schema yet.

alter table public.books
  add column if not exists subject text null,
  add column if not exists brand text null,
  add column if not exists book_type text null,
  add column if not exists published_year integer null,
  add column if not exists instructor_name text null,
  add column if not exists original_price integer null check (original_price is null or original_price >= 0),
  add column if not exists condition_grade text null,
  add column if not exists cover_image_url text null,
  add column if not exists inspection_image_urls text[] not null default '{}'::text[],
  add column if not exists writing_percentage integer null check (writing_percentage is null or (writing_percentage >= 0 and writing_percentage <= 100)),
  add column if not exists has_damage boolean null,
  add column if not exists inspection_notes text null,
  add column if not exists inspected_at timestamptz null,
  add column if not exists is_public boolean not null default false;

create index if not exists idx_books_public_storefront_created_at
  on public.books (created_at desc, id desc)
  where status = 'on_sale' and is_public = true;

create index if not exists idx_books_public_storefront_filters
  on public.books (subject, brand, book_type, published_year, condition_grade)
  where status = 'on_sale' and is_public = true;

alter table public.books
  drop constraint if exists books_subject_check;

alter table public.books
  add constraint books_subject_check
  check (subject is null or subject in ('국어', '수학', '영어', '과학', '사회', '한국사', '기타'));

alter table public.books
  add constraint books_brand_check
  check (brand is null or brand in ('시대인재', '강남대성', '대성마이맥', '이투스', 'EBS'));

alter table public.books
  add constraint books_book_type_check
  check (book_type is null or book_type in ('기출', '모의고사', 'N제', 'EBS', '주간지', '내신'));

alter table public.books
  add constraint books_published_year_check
  check (published_year is null or (published_year >= 2000 and published_year <= 2100));

alter table public.books
  add constraint books_condition_grade_check
  check (condition_grade is null or condition_grade in ('S', 'A_PLUS', 'A'));

alter table public.books
  add constraint books_public_storefront_ready_check
  check (
    not is_public
    or (
      status = 'on_sale'
      and nullif(btrim(coalesce(title, '')), '') is not null
      and nullif(btrim(coalesce(subject, '')), '') is not null
      and nullif(btrim(coalesce(brand, '')), '') is not null
      and nullif(btrim(coalesce(book_type, '')), '') is not null
      and published_year is not null
      and original_price is not null
      and price is not null
      and nullif(btrim(coalesce(cover_image_url, '')), '') is not null
      and condition_grade is not null
      and writing_percentage is not null
      and has_damage is not null
      and inspected_at is not null
    )
  );

create or replace function public.books_enforce_public_storefront_rules()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status is distinct from 'on_sale' then
    new.is_public := false;
  end if;

  if coalesce(new.is_public, false) then
    if nullif(btrim(coalesce(new.title, '')), '') is null then
      raise exception 'Public books require a title.';
    end if;

    if nullif(btrim(coalesce(new.subject, '')), '') is null then
      raise exception 'Public books require a subject.';
    end if;

    if nullif(btrim(coalesce(new.brand, '')), '') is null then
      raise exception 'Public books require a brand.';
    end if;

    if nullif(btrim(coalesce(new.book_type, '')), '') is null then
      raise exception 'Public books require a book type.';
    end if;

    if new.published_year is null then
      raise exception 'Public books require a published year.';
    end if;

    if new.original_price is null then
      raise exception 'Public books require an original price.';
    end if;

    if new.price is null then
      raise exception 'Public books require a sale price.';
    end if;

    if nullif(btrim(coalesce(new.cover_image_url, '')), '') is null then
      raise exception 'Public books require a cover image.';
    end if;

    if nullif(btrim(coalesce(new.condition_grade, '')), '') is null then
      raise exception 'Public books require a condition grade.';
    end if;

    if new.writing_percentage is null then
      raise exception 'Public books require a writing percentage.';
    end if;

    if new.has_damage is null then
      raise exception 'Public books require a damage flag.';
    end if;

    if new.inspected_at is null then
      raise exception 'Public books require an inspection timestamp.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists books_enforce_public_storefront_rules_trigger on public.books;
create trigger books_enforce_public_storefront_rules_trigger
before insert or update on public.books
for each row
execute function public.books_enforce_public_storefront_rules();

create or replace function public.list_public_store_books(
  p_subjects text[] default null,
  p_book_types text[] default null,
  p_brands text[] default null,
  p_years integer[] default null,
  p_condition_grades text[] default null,
  p_search text default null,
  p_sort text default 'popular',
  p_limit integer default 24,
  p_offset integer default 0
)
returns table (
  id bigint,
  title text,
  option text,
  subject text,
  brand text,
  book_type text,
  published_year integer,
  instructor_name text,
  condition_grade text,
  price integer,
  original_price integer,
  discount_rate integer,
  cover_image_url text,
  inspection_image_urls text[],
  writing_percentage integer,
  has_damage boolean,
  inspection_notes text,
  inspected_at timestamptz,
  created_at timestamptz,
  popularity_score integer,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      lower(coalesce(btrim(p_sort), 'popular')) as sort_key,
      btrim(coalesce(p_search, '')) as search_term
  ),
  filtered as (
    select
      b.*,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      (
        case coalesce(b.condition_grade, '')
          when 'S' then 300
          when 'A_PLUS' then 200
          when 'A' then 100
          else 0
        end
        + greatest(0, coalesce(b.original_price - b.price, 0) / 100)
        + greatest(0, 100 - coalesce(b.writing_percentage, 100))
        + case
            when b.inspected_at is null then 0
            else greatest(0, 30 - least(30, floor(extract(day from now() - b.inspected_at))::integer))
          end
      )::integer as popularity_score
    from public.books b
    cross join params
    where b.status = 'on_sale'
      and b.is_public = true
      and (coalesce(cardinality(p_subjects), 0) = 0 or b.subject = any(p_subjects))
      and (coalesce(cardinality(p_book_types), 0) = 0 or b.book_type = any(p_book_types))
      and (coalesce(cardinality(p_brands), 0) = 0 or b.brand = any(p_brands))
      and (coalesce(cardinality(p_years), 0) = 0 or b.published_year = any(p_years))
      and (coalesce(cardinality(p_condition_grades), 0) = 0 or b.condition_grade = any(p_condition_grades))
      and (
        params.search_term = ''
        or b.title ilike '%' || params.search_term || '%'
        or coalesce(b.option, '') ilike '%' || params.search_term || '%'
        or coalesce(b.subject, '') ilike '%' || params.search_term || '%'
        or coalesce(b.brand, '') ilike '%' || params.search_term || '%'
        or coalesce(b.book_type, '') ilike '%' || params.search_term || '%'
        or coalesce(b.instructor_name, '') ilike '%' || params.search_term || '%'
        or coalesce(b.published_year::text, '') ilike '%' || params.search_term || '%'
      )
  ),
  ordered as (
    select *
    from filtered
    cross join params
    order by
      case when params.sort_key = 'latest' then filtered.created_at end desc nulls last,
      case when params.sort_key = 'price_low' then filtered.price end asc nulls last,
      case when params.sort_key = 'price_high' then filtered.price end desc nulls last,
      case when params.sort_key = 'popular' then filtered.popularity_score end desc nulls last,
      filtered.created_at desc,
      filtered.id desc
  )
  select
    ordered.id,
    ordered.title,
    ordered.option,
    ordered.subject,
    ordered.brand,
    ordered.book_type,
    ordered.published_year,
    ordered.instructor_name,
    ordered.condition_grade,
    ordered.price,
    ordered.original_price,
    ordered.discount_rate,
    ordered.cover_image_url,
    ordered.inspection_image_urls,
    ordered.writing_percentage,
    ordered.has_damage,
    ordered.inspection_notes,
    ordered.inspected_at,
    ordered.created_at,
    ordered.popularity_score,
    count(*) over()::integer as total_count
  from ordered
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 24), 500));
$$;

create or replace function public.get_public_store_book_detail(
  p_book_id bigint
)
returns table (
  id bigint,
  title text,
  option text,
  subject text,
  brand text,
  book_type text,
  published_year integer,
  instructor_name text,
  condition_grade text,
  price integer,
  original_price integer,
  discount_rate integer,
  cover_image_url text,
  inspection_image_urls text[],
  writing_percentage integer,
  has_damage boolean,
  inspection_notes text,
  inspected_at timestamptz,
  created_at timestamptz,
  related_books jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  with book as (
    select
      b.*,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate
    from public.books b
    where b.id = p_book_id
      and b.status = 'on_sale'
      and b.is_public = true
    limit 1
  ),
  related as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', related_book.id,
          'title', related_book.title,
          'option', related_book.option,
          'subject', related_book.subject,
          'brand', related_book.brand,
          'book_type', related_book.book_type,
          'published_year', related_book.published_year,
          'condition_grade', related_book.condition_grade,
          'price', related_book.price,
          'original_price', related_book.original_price,
          'discount_rate', related_book.discount_rate,
          'cover_image_url', related_book.cover_image_url
        )
        order by related_book.match_score desc, related_book.created_at desc, related_book.id desc
      ),
      '[]'::jsonb
    ) as related_books
    from (
      select
        candidate.*,
        (
          case when candidate.subject = book.subject then 3 else 0 end
          + case when candidate.brand = book.brand then 2 else 0 end
          + case when candidate.book_type = book.book_type then 2 else 0 end
          + case when candidate.instructor_name = book.instructor_name and book.instructor_name is not null then 1 else 0 end
        )::integer as match_score,
        case
          when candidate.original_price is null or candidate.original_price <= 0 or candidate.price is null then null
          else greatest(0, least(100, round(((candidate.original_price - candidate.price)::numeric / candidate.original_price) * 100)::integer))
        end as discount_rate
      from public.books candidate
      cross join book
      where candidate.id <> book.id
        and candidate.status = 'on_sale'
        and candidate.is_public = true
        and (
          candidate.subject = book.subject
          or candidate.brand = book.brand
          or candidate.book_type = book.book_type
          or (
            candidate.instructor_name = book.instructor_name
            and book.instructor_name is not null
          )
        )
      order by match_score desc, candidate.created_at desc, candidate.id desc
      limit 6
    ) related_book
  )
  select
    book.id,
    book.title,
    book.option,
    book.subject,
    book.brand,
    book.book_type,
    book.published_year,
    book.instructor_name,
    book.condition_grade,
    book.price,
    book.original_price,
    book.discount_rate,
    book.cover_image_url,
    book.inspection_image_urls,
    book.writing_percentage,
    book.has_damage,
    book.inspection_notes,
    book.inspected_at,
    book.created_at,
    related.related_books
  from book
  cross join related;
$$;

grant execute on function public.list_public_store_books(text[], text[], text[], integer[], text[], text, text, integer, integer) to anon, authenticated;
grant execute on function public.get_public_store_book_detail(bigint) to anon, authenticated;
