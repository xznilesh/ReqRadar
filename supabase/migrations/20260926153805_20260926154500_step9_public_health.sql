-- Step 9 production readiness: public database health probe for Vercel readiness.
create or replace function public.xzrecruiter_public_health()
returns jsonb
language sql
stable
set search_path='pg_catalog'
as $$
  select jsonb_build_object('ok',true,'database','ready','checked_at',clock_timestamp());
$$;
revoke all on function public.xzrecruiter_public_health() from public;
grant execute on function public.xzrecruiter_public_health() to anon, authenticated;
