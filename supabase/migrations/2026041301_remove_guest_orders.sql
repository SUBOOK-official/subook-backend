-- Remove the deprecated guest order lookup feature.

drop function if exists public.lookup_guest_order(text, text, text);

drop table if exists public.guest_orders;

drop function if exists public.touch_guest_order_updated_at();
