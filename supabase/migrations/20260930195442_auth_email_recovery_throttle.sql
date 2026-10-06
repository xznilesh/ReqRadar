-- Auth-only server credential: no service-role key is needed in the web runtime.
create table if not exists public.xzrecruiter_auth_server_keys (
  name text primary key check (name = 'web_auth'),
  key_hash text not null check (key_hash ~ '^[a-f0-9]{64}$')
);
alter table public.xzrecruiter_auth_server_keys enable row level security;
revoke all on public.xzrecruiter_auth_server_keys from public, anon, authenticated;

create or replace function public.xzrecruiter_auth_rate_limit(
  p_server_key text, p_scope text, p_key_hash text
) returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_limit integer; v_window integer := 900;
begin
  if length(coalesce(p_server_key,'')) < 40 or not exists (
    select 1 from public.xzrecruiter_auth_server_keys
    where name = 'web_auth' and key_hash = encode(digest(p_server_key,'sha256'),'hex')
  ) then raise exception 'invalid_server_credential' using errcode = '42501'; end if;
  case p_scope
    when 'auth:signup' then v_limit := 5; v_window := 3600;
    when 'auth:login' then v_limit := 10;
    when 'auth:verification_resend' then v_limit := 5;
    when 'auth:password_reset_request' then v_limit := 5;
    when 'auth:password_reset_complete' then v_limit := 10;
    when 'auth:verify_email' then v_limit := 20;
    else raise exception 'unsupported_scope' using errcode = '22023';
  end case;
  return public.xzrecruiter_consume_rate_limit(p_scope,p_key_hash,v_limit,v_window);
end $$;
revoke all on function public.xzrecruiter_auth_rate_limit(text,text,text) from public;
grant execute on function public.xzrecruiter_auth_rate_limit(text,text,text) to anon, authenticated, service_role;

