alter function private.xzrecruiter_can_write(text)
  set search_path = pg_catalog;

alter function private.xzrecruiter_can_screen(text)
  set search_path = pg_catalog;

revoke execute on function public.rls_auto_enable() from public;
revoke execute on function public.rls_auto_enable() from anon;
revoke execute on function public.rls_auto_enable() from authenticated;
