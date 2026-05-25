-- get_cart_items가 books.cover_image_url이 NULL일 때 products.cover_image_url을 fallback으로 사용.
-- (식스샵 import 등으로 books에는 cover가 없고 product 그룹에만 있는 경우 — 동일 product의 다른 옵션도
--  같은 표지를 공유하므로 product cover로 떼우는 게 자연스러움.)
-- CREATE OR REPLACE FUNCTION — additive.

create or replace function public.get_cart_items()
returns table (
  id bigint,
  book_id bigint,
  product_id bigint,
  quantity integer,
  title text,
  option_label text,
  subject text,
  brand text,
  condition_grade text,
  price integer,
  original_price integer,
  cover_image_url text,
  stock_count bigint,
  is_sold_out boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    ci.id,
    ci.book_id,
    ci.product_id,
    ci.quantity,
    b.title,
    b.option as option_label,
    b.subject,
    b.brand,
    b.condition_grade,
    b.price,
    b.original_price,
    coalesce(nullif(btrim(b.cover_image_url), ''), nullif(btrim(p.cover_image_url), '')) as cover_image_url,
    (select count(*) from public.books b2
     where b2.product_id = ci.product_id
       and b2.status = 'on_sale'
       and b2.is_public = true) as stock_count,
    (b.status <> 'on_sale' or not b.is_public) as is_sold_out,
    ci.created_at
  from public.cart_items ci
  join public.books b on b.id = ci.book_id
  left join public.products p on p.id = ci.product_id
  where ci.user_id = auth.uid()
  order by ci.created_at desc;
$$;
