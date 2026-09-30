-- XZ Recruiter Step 1: bind every application session to one explicit workspace.

alter table public.user_sessions
  add column if not exists agency_id uuid references public.agencies(id) on delete cascade;

update public.user_sessions s
set agency_id = (
  select am.agency_id
  from public.agency_memberships am
  where am.user_id = s.user_id
  order by am.created_at asc
  limit 1
)
where s.agency_id is null;

create index if not exists idx_xzrecruiter_sessions_workspace_user
  on public.user_sessions (agency_id, user_id, expires_at desc)
  where revoked_at is null;

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
    select count(*)::integer into v_recent_failures
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

  select am.agency_id into v_agency_id
  from public.agency_memberships am
  where am.user_id = v_user_id
  order by am.created_at asc
  limit 1;

  if v_agency_id is null then
    return jsonb_build_object('ok', false, 'error', 'workspace_missing');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.user_sessions (id, user_id, agency_id, token_hash, expires_at)
  values (
    v_session_id,
    v_user_id,
    v_agency_id,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    now() + interval '7 days'
  );

  insert into public.auth_login_events (id, email_normalized, success)
  values (gen_random_uuid(), v_email, true);

  insert into public.audit_events (id, agency_id, actor_user_id, action, entity_type, entity_id, metadata)
  values (
    gen_random_uuid(), v_agency_id, v_user_id, 'auth.login', 'user', v_user_id,
    jsonb_build_object('session_id', v_session_id, 'workspace_bound', true)
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
  ) into v_result
  from public.user_sessions s
  join public.users u on u.id = s.user_id and u.email_verified_at is not null
  join public.agency_memberships am on am.user_id = u.id and am.agency_id = s.agency_id
  join public.agencies a on a.id = s.agency_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.agency_id is not null
    and s.revoked_at is null
    and s.expires_at > now()
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

  select s.agency_id into v_agency_id
  from public.user_sessions s
  join public.users u on u.id = s.user_id and u.email_verified_at is not null
  join public.agency_memberships am on am.user_id = s.user_id and am.agency_id = s.agency_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.agency_id is not null
    and s.revoked_at is null
    and s.expires_at > now()
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
    select c.name, h.heat_score, h.recommendation, h.why_now_summary, f.fit_score
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
    'workspace_id', v_agency_id,
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
    select s.user_id, s.agency_id into v_user_id, v_agency_id
    from public.user_sessions s
    where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and s.revoked_at is null
    limit 1;

    update public.user_sessions
    set revoked_at = coalesce(revoked_at, now()), last_seen_at = now()
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and revoked_at is null;

    if v_user_id is not null then
      insert into public.audit_events (id, agency_id, actor_user_id, action, entity_type, entity_id, metadata)
      values (gen_random_uuid(), v_agency_id, v_user_id, 'auth.logout', 'user', v_user_id, '{}'::jsonb);
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;
