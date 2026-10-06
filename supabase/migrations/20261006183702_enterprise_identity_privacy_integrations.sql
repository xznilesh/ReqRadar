-- XZRecruiter enterprise identity, privacy and integration foundation.
-- Generated filename created by pinned Supabase CLI v2.120.0 in GitHub Actions.
-- Additive only. Do not apply until legacy migration-version collisions are reconciled against remote history.

begin;

alter table public.user_sessions
  add column if not exists device_metadata jsonb not null default '{}'::jsonb,
  add column if not exists last_seen_at timestamptz;

create index if not exists idx_xzr_user_sessions_device_activity
  on public.user_sessions(agency_id,user_id,last_seen_at desc)
  where revoked_at is null;

create table if not exists public.enterprise_scim_tokens (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  token_prefix text not null,
  label text not null default 'SCIM',
  default_role text not null default 'RECRUITER'
    check (default_role in ('RECRUITER','VIEWER','MEMBER')),
  active boolean not null default true,
  expires_at timestamptz,
  last_used_at timestamptz,
  created_by_user_id uuid references public.users(id) on delete set null,
  revoked_by_user_id uuid references public.users(id) on delete set null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_xzr_scim_tokens_agency_active
  on public.enterprise_scim_tokens(agency_id,active,created_at desc);

create table if not exists public.enterprise_integration_connections (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  provider text not null check (provider in ('GOOGLE','MICROSOFT')),
  external_account_id text,
  external_account_email text,
  access_token_ciphertext text,
  refresh_token_ciphertext text,
  token_expires_at timestamptz,
  scopes text[] not null default '{}'::text[],
  status text not null default 'CONNECTED'
    check (status in ('CONNECTED','ERROR','REVOKED','REAUTH_REQUIRED')),
  last_health_at timestamptz,
  last_error_code text,
  last_error_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(agency_id,user_id,provider)
);
create index if not exists idx_xzr_integrations_health
  on public.enterprise_integration_connections(agency_id,status,last_health_at desc);

create table if not exists public.enterprise_api_keys (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  key_prefix text not null,
  key_hash text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  name text not null,
  scopes text[] not null default '{}'::text[],
  active boolean not null default true,
  expires_at timestamptz,
  last_used_at timestamptz,
  created_by_user_id uuid references public.users(id) on delete set null,
  revoked_by_user_id uuid references public.users(id) on delete set null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_xzr_api_keys_agency_active
  on public.enterprise_api_keys(agency_id,active,created_at desc);

create table if not exists public.enterprise_webhook_endpoints (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  url text not null check (url ~ '^https://'),
  secret_ciphertext text not null,
  events text[] not null default '{}'::text[],
  active boolean not null default true,
  last_delivery_at timestamptz,
  last_error_code text,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agency_id,url)
);

create table if not exists public.enterprise_webhook_deliveries (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  endpoint_id uuid not null references public.enterprise_webhook_endpoints(id) on delete cascade,
  event_id uuid not null,
  event_type text not null,
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  attempt_count integer not null default 0 check (attempt_count between 0 and 50),
  status text not null default 'PENDING'
    check (status in ('PENDING','DELIVERED','FAILED','DEAD_LETTER')),
  response_status integer,
  next_attempt_at timestamptz,
  delivered_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(endpoint_id,event_id)
);
create index if not exists idx_xzr_webhook_delivery_retry
  on public.enterprise_webhook_deliveries(status,next_attempt_at)
  where status in ('PENDING','FAILED');

create table if not exists public.candidate_legal_holds (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  reason text not null,
  placed_by_user_id uuid references public.users(id) on delete set null,
  placed_at timestamptz not null default now(),
  released_by_user_id uuid references public.users(id) on delete set null,
  released_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);
create unique index if not exists uq_xzr_candidate_active_legal_hold
  on public.candidate_legal_holds(agency_id,candidate_id)
  where released_at is null;

create table if not exists public.candidate_privacy_requests (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete restrict,
  request_type text not null
    check (request_type in ('ACCESS','PORTABILITY','CORRECTION','RESTRICTION','DELETE')),
  status text not null default 'RECEIVED'
    check (status in ('RECEIVED','IDENTITY_VERIFIED','IN_PROGRESS','ON_HOLD','COMPLETED','REJECTED','ERROR')),
  requested_at timestamptz not null default now(),
  due_at timestamptz,
  requested_by_user_id uuid references public.users(id) on delete set null,
  handled_by_user_id uuid references public.users(id) on delete set null,
  completed_at timestamptz,
  legal_basis text,
  result_summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_xzr_privacy_requests_queue
  on public.candidate_privacy_requests(agency_id,status,due_at,requested_at);

create table if not exists public.candidate_retention_runs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid references public.agencies(id) on delete cascade,
  candidate_id uuid references public.candidates(id) on delete set null,
  privacy_request_id uuid references public.candidate_privacy_requests(id) on delete set null,
  mode text not null check (mode in ('DRY_RUN','EXECUTE')),
  status text not null check (status in ('STARTED','SKIPPED_LEGAL_HOLD','COMPLETED','ERROR')),
  policy_retention_days integer,
  storage_objects_removed integer not null default 0,
  database_records_scrubbed integer not null default 0,
  error_code text,
  evidence jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists idx_xzr_retention_runs_candidate
  on public.candidate_retention_runs(agency_id,candidate_id,started_at desc);

alter table public.organization_data_governance
  add column if not exists candidate_privacy_notice_version text,
  add column if not exists candidate_privacy_notice_url text,
  add column if not exists candidate_privacy_notice_text text,
  add column if not exists candidate_ai_notice_text text,
  add column if not exists candidate_notice_effective_at timestamptz;

create or replace function public.xzrecruiter_public_privacy_notice(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path='public','pg_temp'
as $function$
  select coalesce((
    select jsonb_build_object(
      'ok',true,
      'notice',jsonb_build_object(
        'version',g.candidate_privacy_notice_version,
        'url',g.candidate_privacy_notice_url,
        'text',g.candidate_privacy_notice_text,
        'ai_notice',g.candidate_ai_notice_text,
        'effective_at',g.candidate_notice_effective_at,
        'human_review_required',true
      )
    )
    from public.recruitment_jobs j
    left join public.organization_data_governance g on g.agency_id=j.agency_id
    where j.public_slug=p_slug
      and j.public_visibility='PUBLIC'
      and j.archived_at is null
      and j.status='OPEN'
    limit 1
  ),jsonb_build_object('ok',false,'error','not_found'));
$function$;

revoke all on function public.xzrecruiter_public_privacy_notice(text) from public;
grant execute on function public.xzrecruiter_public_privacy_notice(text) to anon,authenticated;

create or replace function public.xzrecruiter_public_apply_with_notice(
  p_slug text,
  p_application jsonb,
  p_notice_version text
)
returns jsonb
language plpgsql
security definer
set search_path='public','extensions','pg_temp'
as $function$
declare
  v_job public.recruitment_jobs%rowtype;
  v_notice public.organization_data_governance%rowtype;
  v_result jsonb;
  v_application uuid;
  v_candidate uuid;
begin
  select * into v_job
  from public.recruitment_jobs
  where public_slug=p_slug
    and public_visibility='PUBLIC'
    and archived_at is null
    and status='OPEN'
  limit 1;
  if v_job.id is null then
    return jsonb_build_object('ok',false,'error','not_found');
  end if;

  select * into v_notice
  from public.organization_data_governance
  where agency_id=v_job.agency_id;

  if nullif(btrim(coalesce(v_notice.candidate_privacy_notice_version,'')),'') is not null
     and btrim(coalesce(p_notice_version,''))<>btrim(v_notice.candidate_privacy_notice_version) then
    return jsonb_build_object(
      'ok',false,
      'error','privacy_notice_required',
      'notice_version',v_notice.candidate_privacy_notice_version
    );
  end if;

  v_result:=public.xzrecruiter_public_apply(p_slug,p_application);
  if coalesce((v_result->>'ok')::boolean,false) is not true then
    return v_result;
  end if;

  v_application:=nullif(v_result->>'application_id','')::uuid;
  select candidate_id into v_candidate
  from public.applications
  where id=v_application and agency_id=v_job.agency_id;

  if v_candidate is not null then
    update public.applications
    set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'privacy_notice_version',nullif(v_notice.candidate_privacy_notice_version,''),
      'privacy_notice_url',nullif(v_notice.candidate_privacy_notice_url,''),
      'privacy_notice_accepted_at',now(),
      'ai_notice_present',nullif(v_notice.candidate_ai_notice_text,'') is not null,
      'human_review_required',true
    )
    where id=v_application and agency_id=v_job.agency_id;

    insert into public.audit_events(
      id,agency_id,actor_user_id,action,entity_type,entity_id,metadata
    ) values(
      gen_random_uuid(),v_job.agency_id,null,'candidate.consent_notice_accepted','candidate',v_candidate,
      jsonb_build_object(
        'transactional',true,
        'application_id',v_application,
        'notice_version',nullif(v_notice.candidate_privacy_notice_version,''),
        'notice_url',nullif(v_notice.candidate_privacy_notice_url,''),
        'ai_notice_present',nullif(v_notice.candidate_ai_notice_text,'') is not null,
        'human_review_required',true
      )
    );
  end if;

  return v_result||jsonb_build_object(
    'privacy_notice_version',nullif(v_notice.candidate_privacy_notice_version,'')
  );
end;
$function$;

revoke all on function public.xzrecruiter_public_apply_with_notice(text,jsonb,text) from public;
grant execute on function public.xzrecruiter_public_apply_with_notice(text,jsonb,text) to anon,authenticated;

create or replace function private.xzrecruiter_candidate_consent_history_trigger()
returns trigger
language plpgsql
security definer
set search_path='public','extensions','pg_temp'
as $function$
declare
  v_actor uuid;
  v_previous jsonb;
  v_current jsonb;
begin
  v_actor:=coalesce(new.updated_by_user_id,new.created_by_user_id);
  if tg_op='INSERT' then
    v_previous:=null;
  else
    if old.consent_status is not distinct from new.consent_status
       and old.consent_source is not distinct from new.consent_source
       and old.consent_at is not distinct from new.consent_at then
      return new;
    end if;
    v_previous:=jsonb_build_object(
      'status',old.consent_status,
      'source',old.consent_source,
      'consent_at',old.consent_at
    );
  end if;

  v_current:=jsonb_build_object(
    'status',new.consent_status,
    'source',new.consent_source,
    'consent_at',new.consent_at
  );

  insert into public.audit_events(
    id,agency_id,actor_user_id,action,entity_type,entity_id,metadata
  ) values(
    gen_random_uuid(),new.agency_id,v_actor,'candidate.consent_history','candidate',new.id,
    jsonb_build_object(
      'transactional',true,
      'operation',tg_op,
      'previous',v_previous,
      'current',v_current
    )
  );
  return new;
end;
$function$;

revoke all on function private.xzrecruiter_candidate_consent_history_trigger()
  from public,anon,authenticated;

drop trigger if exists xzr_candidate_consent_history_insert on public.candidates;
create trigger xzr_candidate_consent_history_insert
after insert on public.candidates
for each row execute function private.xzrecruiter_candidate_consent_history_trigger();

drop trigger if exists xzr_candidate_consent_history_update on public.candidates;
create trigger xzr_candidate_consent_history_update
after update of consent_status,consent_source,consent_at on public.candidates
for each row execute function private.xzrecruiter_candidate_consent_history_trigger();

do $block$
declare
  t text;
begin
  foreach t in array array[
    'enterprise_scim_tokens',
    'enterprise_integration_connections',
    'enterprise_api_keys',
    'enterprise_webhook_endpoints',
    'enterprise_webhook_deliveries',
    'candidate_legal_holds',
    'candidate_privacy_requests',
    'candidate_retention_runs'
  ]
  loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on table public.%I from public,anon,authenticated',t);
    execute format('grant select,insert,update,delete on table public.%I to service_role',t);
  end loop;
end;
$block$;

commit;
