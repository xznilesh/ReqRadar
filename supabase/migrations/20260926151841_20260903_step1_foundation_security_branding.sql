-- XZ Recruiter Step 1: foundation, security and branding backend gates.
-- Additive to existing recruitment data; no recruitment/client/candidate rows are rewritten.

alter table public.users
  add column if not exists email_verified_at timestamptz;

alter table public.agency_memberships
  drop constraint if exists agency_memberships_role_check;

alter table public.agency_memberships
  add constraint agency_memberships_role_check
  check (role = any (array['OWNER'::text, 'ADMIN'::text, 'RECRUITER'::text, 'VIEWER'::text, 'MEMBER'::text]));

create index if not exists idx_xzrecruiter_auth_login_events_email_time
  on public.auth_login_events (email_normalized, created_at desc);

create index if not exists idx_xzrecruiter_password_reset_tokens_user_active
  on public.password_reset_tokens (user_id, expires_at desc)
  where used_at is null;

create or replace function public.xzrecruiter_signup(
  p_email text,
  p_password text,
  p_name text,
  p_agency text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text := btrim(coalesce(p_name, ''));
  v_agency_name text := btrim(coalesce(p_agency, ''));
  v_user_id uuid := gen_random_uuid();
  v_agency_id uuid := gen_random_uuid();
  v_password_hash text;
begin
  if v_name = '' or v_agency_name = '' or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_profile');
  end if;

  if length(coalesce(p_password, '')) < 12 then
    return jsonb_build_object('ok', false, 'error', 'weak_password');
  end if;

  if exists (select 1 from public.users where lower(email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'account_exists');
  end if;

  v_password_hash := extensions.crypt(p_password, extensions.gen_salt('bf', 12));

  insert into public.users (id, email, display_name, email_verified_at)
  values (v_user_id, v_email, v_name, null);

  insert into public.user_credentials (user_id, password_hash, password_salt)
  values (v_user_id, v_password_hash, 'bcrypt-v1');

  insert into public.agencies (id, name, country, timezone, onboarding_status)
  values (v_agency_id, v_agency_name, 'IN', 'Asia/Kolkata', 'IN_PROGRESS');

  insert into public.agency_memberships (agency_id, user_id, role)
  values (v_agency_id, v_user_id, 'OWNER');

  insert into public.audit_events (
    id, agency_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    gen_random_uuid(), v_agency_id, v_user_id, 'workspace.created', 'user', v_user_id,
    jsonb_build_object('email', v_email, 'role', 'OWNER', 'email_verified', false)
  );

  return jsonb_build_object(
    'ok', true,
    'requires_email_verification', true,
    'user', jsonb_build_object('id', v_user_id, 'email', v_email, 'display_name', v_name),
    'agency', jsonb_build_object('id', v_agency_id, 'name', v_agency_name, 'role', 'OWNER')
  );
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'account_exists');
  when others then
    raise warning 'xzrecruiter_signup failed: %', sqlerrm;
    return jsonb_build_object('ok', false, 'error', 'signup_failed');
end;
$function$;

create or replace function public.xzrecruiter_login(p_email text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user_id uuid;
  v_agency_id uuid;
  v_password_hash text;
  v_verified_at timestamptz;
  v_recent_failures integer := 0;
  v_session_id uuid := gen_random_uuid();
  v_token text;
begin
  select u.id, c.password_hash, u.email_verified_at
    into v_user_id, v_password_hash, v_verified_at
  from public.users u
  join public.user_credentials c on c.user_id = u.id
  where lower(u.email) = v_email
  limit 1;

  if v_user_id is null
     or v_password_hash is null
     or extensions.crypt(coalesce(p_password, ''), v_password_hash) <> v_password_hash then
    select count(*)::integer
      into v_recent_failures
    from public.auth_login_events
    where email_normalized = v_email
      and success = false
      and created_at > now() - interval '15 minutes';

    insert into public.auth_login_events (id, email_normalized, success)
    values (gen_random_uuid(), v_email, false);

    if v_recent_failures >= 9 then
      return jsonb_build_object('ok', false, 'error', 'temporarily_locked');
    end if;
    return jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  end if;

  if v_verified_at is null then
    insert into public.auth_login_events (id, email_normalized, success)
    values (gen_random_uuid(), v_email, false);
    return jsonb_build_object('ok', false, 'error', 'email_unverified');
  end if;

  select am.agency_id
    into v_agency_id
  from public.agency_memberships am
  where am.user_id = v_user_id
  order by am.created_at asc
  limit 1;

  if v_agency_id is null then
    return jsonb_build_object('ok', false, 'error', 'workspace_missing');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.user_sessions (id, user_id, token_hash, expires_at)
  values (
    v_session_id,
    v_user_id,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    now() + interval '7 days'
  );

  insert into public.auth_login_events (id, email_normalized, success)
  values (gen_random_uuid(), v_email, true);

  insert into public.audit_events (
    id, agency_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    gen_random_uuid(), v_agency_id, v_user_id, 'auth.login', 'user', v_user_id,
    jsonb_build_object('session_id', v_session_id)
  );

  return jsonb_build_object('ok', true, 'token', v_token);
exception
  when others then
    raise warning 'xzrecruiter_login failed: %', sqlerrm;
    return jsonb_build_object('ok', false, 'error', 'login_failed');
end;
$function$;

create or replace function public.xzrecruiter_me(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  if coalesce(p_token, '') = '' then return null; end if;

  select jsonb_build_object(
    'id', u.id,
    'email', u.email,
    'display_name', u.display_name,
    'email_verified', true,
    'agency_id', a.id,
    'agency_name', a.name,
    'role', am.role
  )
  into v_result
  from public.user_sessions s
  join public.users u on u.id = s.user_id and u.email_verified_at is not null
  join public.agency_memberships am on am.user_id = u.id
  join public.agencies a on a.id = am.agency_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.revoked_at is null
    and s.expires_at > now()
  order by am.created_at asc
  limit 1;

  return v_result;
end;
$function$;

create or replace function public.xzrecruiter_dashboard(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_agency_id uuid;
  v_companies integer := 0;
  v_jobs integer := 0;
  v_hot integer := 0;
  v_clients integer := 0;
  v_candidates integer := 0;
  v_signals jsonb := '[]'::jsonb;
  v_pipeline jsonb := '[]'::jsonb;
begin
  if coalesce(p_token, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;

  select am.agency_id
  into v_agency_id
  from public.user_sessions s
  join public.users u on u.id = s.user_id and u.email_verified_at is not null
  join public.agency_memberships am on am.user_id = s.user_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.revoked_at is null
    and s.expires_at > now()
  order by am.created_at asc
  limit 1;

  if v_agency_id is null then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;

  select count(*)::integer into v_companies from public.companies where active = true;
  select count(*)::integer into v_jobs from public.canonical_jobs where active = true;
  select count(*)::integer into v_hot from public.agency_company_hiring_heat where agency_id = v_agency_id and heat_score >= 70;
  select count(*)::integer into v_clients from public.recruitment_clients where agency_id = v_agency_id and status = 'ACTIVE';
  select count(*)::integer into v_candidates from public.candidates where agency_id = v_agency_id;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.heat_score desc), '[]'::jsonb)
  into v_signals
  from (
    select c.name,
           h.heat_score,
           h.recommendation,
           h.why_now_summary,
           f.fit_score
    from public.agency_company_hiring_heat h
    join public.companies c on c.id = h.company_id
    left join public.agency_company_fit_scores f
      on f.agency_id = h.agency_id and f.company_id = h.company_id
    where h.agency_id = v_agency_id
    order by h.heat_score desc, h.updated_at desc
    limit 8
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc), '[]'::jsonb)
  into v_pipeline
  from (
    select stage, count(*)::integer as n
    from public.applications
    where agency_id = v_agency_id and status = 'ACTIVE'
    group by stage
  ) x;

  return jsonb_build_object(
    'ok', true,
    'metrics', jsonb_build_object(
      'companies', v_companies,
      'jobs', v_jobs,
      'hot', v_hot,
      'clients', v_clients,
      'candidates', v_candidates
    ),
    'signals', v_signals,
    'pipeline', v_pipeline
  );
end;
$function$;

create or replace function public.xzrecruiter_logout(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_user_id uuid;
  v_agency_id uuid;
begin
  if coalesce(p_token, '') <> '' then
    select s.user_id, am.agency_id
      into v_user_id, v_agency_id
    from public.user_sessions s
    left join public.agency_memberships am on am.user_id = s.user_id
    where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and s.revoked_at is null
    order by am.created_at asc
    limit 1;

    update public.user_sessions
    set revoked_at = coalesce(revoked_at, now()), last_seen_at = now()
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and revoked_at is null;

    if v_user_id is not null then
      insert into public.audit_events (
        id, agency_id, actor_user_id, action, entity_type, entity_id, metadata
      ) values (
        gen_random_uuid(), v_agency_id, v_user_id, 'auth.logout', 'user', v_user_id, '{}'::jsonb
      );
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function public.xzrecruiter_verify_email()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_auth_user_id uuid := auth.uid();
  v_user_id uuid;
  v_agency_id uuid;
begin
  if v_auth_user_id is null or v_email = '' then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;

  update public.users
  set email_verified_at = coalesce(email_verified_at, now()), updated_at = now()
  where lower(email) = v_email
  returning id into v_user_id;

  if v_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'workspace_not_found');
  end if;

  select agency_id into v_agency_id
  from public.agency_memberships
  where user_id = v_user_id
  order by created_at asc
  limit 1;

  insert into public.audit_events (
    id, agency_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    gen_random_uuid(), v_agency_id, v_user_id, 'auth.email_verified', 'user', v_user_id,
    jsonb_build_object('auth_user_id', v_auth_user_id, 'email', v_email)
  );

  return jsonb_build_object('ok', true, 'email', v_email);
end;
$function$;

create or replace function public.xzrecruiter_password_reset_intent(p_email text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user_id uuid;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select id into v_user_id
  from public.users
  where lower(email) = v_email
  limit 1;

  if v_user_id is not null then
    update public.password_reset_tokens
    set used_at = coalesce(used_at, now())
    where user_id = v_user_id and used_at is null;

    insert into public.password_reset_tokens (id, user_id, token_hash, expires_at)
    values (
      gen_random_uuid(),
      v_user_id,
      encode(extensions.digest(v_token, 'sha256'), 'hex'),
      now() + interval '20 minutes'
    );
  end if;

  return jsonb_build_object('ok', true, 'intent', v_token);
end;
$function$;

create or replace function public.xzrecruiter_reset_password_verified(
  p_intent text,
  p_new_password text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_auth_user_id uuid := auth.uid();
  v_user_id uuid;
  v_agency_id uuid;
  v_reset_id uuid;
begin
  if v_auth_user_id is null or v_email = '' or coalesce(p_intent, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;

  if length(coalesce(p_new_password, '')) < 12 then
    return jsonb_build_object('ok', false, 'error', 'weak_password');
  end if;

  select u.id, t.id
    into v_user_id, v_reset_id
  from public.users u
  join public.password_reset_tokens t on t.user_id = u.id
  where lower(u.email) = v_email
    and t.token_hash = encode(extensions.digest(p_intent, 'sha256'), 'hex')
    and t.used_at is null
    and t.expires_at > now()
  order by t.created_at desc
  limit 1;

  if v_user_id is null or v_reset_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_or_expired_reset');
  end if;

  update public.user_credentials
  set password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf', 12)),
      password_salt = 'bcrypt-v1',
      password_updated_at = now()
  where user_id = v_user_id;

  update public.users
  set email_verified_at = coalesce(email_verified_at, now()), updated_at = now()
  where id = v_user_id;

  update public.password_reset_tokens
  set used_at = now()
  where id = v_reset_id;

  update public.user_sessions
  set revoked_at = coalesce(revoked_at, now()), last_seen_at = now()
  where user_id = v_user_id and revoked_at is null;

  select agency_id into v_agency_id
  from public.agency_memberships
  where user_id = v_user_id
  order by created_at asc
  limit 1;

  insert into public.audit_events (
    id, agency_id, actor_user_id, action, entity_type, entity_id, metadata
  ) values (
    gen_random_uuid(), v_agency_id, v_user_id, 'auth.password_reset', 'user', v_user_id,
    jsonb_build_object('auth_user_id', v_auth_user_id, 'all_sessions_revoked', true)
  );

  return jsonb_build_object('ok', true);
end;
$function$;

-- Proof-only RPCs must require an authenticated Supabase Auth JWT.
revoke all on function public.xzrecruiter_verify_email() from public, anon;
grant execute on function public.xzrecruiter_verify_email() to authenticated;

revoke all on function public.xzrecruiter_reset_password_verified(text, text) from public, anon;
grant execute on function public.xzrecruiter_reset_password_verified(text, text) to authenticated;

-- Reset intent is deliberately anonymous and returns a generic-shaped response to prevent account enumeration.
revoke all on function public.xzrecruiter_password_reset_intent(text) from public, authenticated;
grant execute on function public.xzrecruiter_password_reset_intent(text) to anon;

-- Existing public app RPCs remain available only to the anonymous Data API role used by the server facade.
revoke all on function public.xzrecruiter_signup(text, text, text, text) from public, authenticated;
grant execute on function public.xzrecruiter_signup(text, text, text, text) to anon;

revoke all on function public.xzrecruiter_login(text, text) from public, authenticated;
grant execute on function public.xzrecruiter_login(text, text) to anon;

revoke all on function public.xzrecruiter_me(text) from public, authenticated;
grant execute on function public.xzrecruiter_me(text) to anon;

revoke all on function public.xzrecruiter_dashboard(text) from public, authenticated;
grant execute on function public.xzrecruiter_dashboard(text) to anon;

revoke all on function public.xzrecruiter_logout(text) from public, authenticated;
grant execute on function public.xzrecruiter_logout(text) to anon;

-- Revoke legacy pre-verification app sessions only after the new verification-aware app is deployed.
-- This statement is intentionally part of the activation migration, not executed during source-only review.
update public.user_sessions s
set revoked_at = coalesce(s.revoked_at, now()), last_seen_at = now()
from public.users u
where s.user_id = u.id
  and u.email_verified_at is null
  and s.revoked_at is null;
