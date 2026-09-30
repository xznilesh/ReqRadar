-- XZ Recruiter Step 7: Enterprise Multi-Tenant Security & Data Foundation.
-- Step 7 only. No automation/manager-control (Step 8) functionality is introduced.
-- Security posture: browser is untrusted; tenant identity is session-derived; direct Data API table access is deny-by-default.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1) Membership/session hardening: disabled/removed/inactive users lose access
-- ---------------------------------------------------------------------------
alter table public.users
  add column if not exists disabled_at timestamptz;

alter table public.agency_memberships
  add column if not exists active boolean not null default true;

create index if not exists idx_xzr_memberships_active_user
  on public.agency_memberships(user_id, agency_id)
  where active=true;

create index if not exists idx_xzr_sessions_active_workspace
  on public.user_sessions(agency_id,user_id,expires_at)
  where revoked_at is null;

create or replace function private.xzrecruiter_session_context(p_token text)
returns table(agency_id uuid,user_id uuid,role text)
language sql
stable
security definer
set search_path='public','extensions','pg_temp'
as $function$
  select s.agency_id,s.user_id,am.role
  from public.user_sessions s
  join public.users u
    on u.id=s.user_id
   and u.email_verified_at is not null
   and u.disabled_at is null
  join public.agency_memberships am
    on am.agency_id=s.agency_id
   and am.user_id=s.user_id
   and am.active=true
  where coalesce(p_token,'')<>''
    and s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and s.revoked_at is null
    and s.expires_at>now()
    and s.agency_id is not null
  limit 1;
$function$;
revoke all on function private.xzrecruiter_session_context(text) from public,anon,authenticated;

create or replace function public.xzrecruiter_login(p_email text,p_password text)
returns jsonb
language plpgsql
security definer
set search_path='public','extensions','pg_temp'
as $function$
declare
  v_email text:=lower(btrim(coalesce(p_email,'')));
  v_user_id uuid;v_agency_id uuid;v_password_hash text;v_verified_at timestamptz;v_disabled_at timestamptz;
  v_recent_failures integer:=0;v_session_id uuid:=gen_random_uuid();v_token text;
begin
  select u.id,c.password_hash,u.email_verified_at,u.disabled_at
  into v_user_id,v_password_hash,v_verified_at,v_disabled_at
  from public.users u
  join public.user_credentials c on c.user_id=u.id
  where lower(u.email)=v_email
  limit 1;

  if v_user_id is null or v_password_hash is null
     or extensions.crypt(coalesce(p_password,''),v_password_hash)<>v_password_hash then
    select count(*)::integer into v_recent_failures
    from public.auth_login_events
    where email_normalized=v_email and success=false and created_at>now()-interval '15 minutes';
    insert into public.auth_login_events(id,email_normalized,success)
    values(gen_random_uuid(),v_email,false);
    if v_recent_failures>=9 then return jsonb_build_object('ok',false,'error','temporarily_locked'); end if;
    return jsonb_build_object('ok',false,'error','invalid_credentials');
  end if;

  if v_disabled_at is not null then
    insert into public.auth_login_events(id,email_normalized,success)
    values(gen_random_uuid(),v_email,false);
    return jsonb_build_object('ok',false,'error','account_disabled');
  end if;

  if v_verified_at is null then
    insert into public.auth_login_events(id,email_normalized,success)
    values(gen_random_uuid(),v_email,false);
    return jsonb_build_object('ok',false,'error','email_unverified');
  end if;

  select am.agency_id into v_agency_id
  from public.agency_memberships am
  where am.user_id=v_user_id and am.active=true
  order by am.created_at asc
  limit 1;

  if v_agency_id is null then return jsonb_build_object('ok',false,'error','workspace_missing'); end if;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.user_sessions(id,user_id,agency_id,token_hash,expires_at)
  values(v_session_id,v_user_id,v_agency_id,encode(extensions.digest(v_token,'sha256'),'hex'),now()+interval '7 days');

  insert into public.auth_login_events(id,email_normalized,success)
  values(gen_random_uuid(),v_email,true);

  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(gen_random_uuid(),v_agency_id,v_user_id,'auth.login','user',v_user_id,
    jsonb_build_object('session_id',v_session_id,'workspace_bound',true));

  return jsonb_build_object('ok',true,'token',v_token);
exception when others then
  raise warning 'xzrecruiter_login failed';
  return jsonb_build_object('ok',false,'error','login_failed');
end;
$function$;
revoke all on function public.xzrecruiter_login(text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_login(text,text) to anon,authenticated;

-- ---------------------------------------------------------------------------
-- 2) Authoritative role -> capability model
-- ---------------------------------------------------------------------------
create or replace function private.xzrecruiter_normalize_business_role(
  p_agency uuid,p_user uuid,p_membership_role text
) returns text
language sql
stable
security invoker
set search_path='public','private','pg_temp'
as $$
  select case upper(coalesce(private.xzrecruiter_business_role(p_agency,p_user,p_membership_role),''))
    when 'BUSINESS_DEVELOPMENT' then 'ACCOUNT_MANAGER'
    when 'BDM' then 'ACCOUNT_MANAGER'
    when 'SOURCER' then 'RECRUITER'
    when 'HIRING_MANAGER' then 'HIRING_MANAGER'
    else upper(coalesce(private.xzrecruiter_business_role(p_agency,p_user,p_membership_role),''))
  end;
$$;
revoke all on function private.xzrecruiter_normalize_business_role(uuid,uuid,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_has_permission(p_role text,p_permission text)
returns boolean
language sql
immutable
security invoker
set search_path='pg_temp'
as $$
  select case upper(coalesce(p_role,''))
    when 'OWNER' then true
    when 'ADMIN' then true
    when 'RECRUITMENT_MANAGER' then lower(p_permission)=any(array[
      'requirement:create','requirement:approve','requirement:assign',
      'candidate:view','candidate:edit','candidate:screen',
      'submission:create','document:resume_view','document:review','audit:view'
    ])
    when 'ACCOUNT_MANAGER' then lower(p_permission)=any(array[
      'requirement:create','requirement:approve','requirement:assign',
      'candidate:view','submission:am_review','submission:client_submit',
      'commercial:view','commercial:edit','document:resume_view','document:sensitive_view','document:review','audit:view'
    ])
    when 'RECRUITER' then lower(p_permission)=any(array[
      'candidate:view','candidate:edit','candidate:screen','submission:create',
      'document:resume_view'
    ])
    when 'COMPLIANCE_REVIEWER' then lower(p_permission)=any(array[
      'candidate:view','document:resume_view','document:sensitive_view','document:review','audit:view'
    ])
    when 'CLIENT_USER' then false
    else false
  end;
$$;
revoke all on function private.xzrecruiter_has_permission(text,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_candidate_object_access(
  p_agency uuid,p_user uuid,p_business_role text,p_candidate uuid,p_permission text default 'candidate:view'
) returns boolean
language sql
stable
security definer
set search_path='public','private','pg_temp'
as $$
  select
    private.xzrecruiter_has_permission(p_business_role,p_permission)
    and exists(
      select 1 from public.candidates c
      where c.id=p_candidate and c.agency_id=p_agency and c.archived_at is null
        and (
          upper(coalesce(p_business_role,''))<>'RECRUITER'
          or c.owner_user_id=p_user
          or exists(
            select 1
            from public.applications a
            join public.requirement_recruiter_assignments ra
              on ra.agency_id=p_agency
             and ra.job_id=a.job_id
             and ra.recruiter_user_id=p_user
             and ra.assignment_status='ACTIVE'
            join public.recruitment_jobs j
              on j.id=a.job_id and j.agency_id=p_agency and j.archived_at is null
             and j.recruiter_ready=true and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null
            where a.agency_id=p_agency
              and a.candidate_id=c.id
              and a.archived_at is null
          )
        )
    );
$$;
revoke all on function private.xzrecruiter_candidate_object_access(uuid,uuid,text,uuid,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_job_object_access(
  p_agency uuid,p_user uuid,p_business_role text,p_job uuid
) returns boolean
language sql
stable
security definer
set search_path='public','private','pg_temp'
as $$
  select exists(
    select 1 from public.recruitment_jobs j
    where j.id=p_job and j.agency_id=p_agency and j.archived_at is null
      and (
        upper(coalesce(p_business_role,''))<>'RECRUITER'
        or exists(
          select 1 from public.requirement_recruiter_assignments ra
          where ra.agency_id=p_agency and ra.job_id=j.id
            and ra.recruiter_user_id=p_user and ra.assignment_status='ACTIVE'
            and j.recruiter_ready=true and j.requirement_state='OPEN'
            and j.approved_hiring_brief_id is not null
        )
      )
  );
$$;
revoke all on function private.xzrecruiter_job_object_access(uuid,uuid,text,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_entity_belongs_to_agency(
  p_agency uuid,p_entity_type text,p_entity_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_type text:=upper(coalesce(p_entity_type,''));
begin
  if p_agency is null or p_entity_id is null then return false; end if;
  if v_type='CANDIDATE' then return exists(select 1 from public.candidates where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='JOB' then return exists(select 1 from public.recruitment_jobs where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='APPLICATION' then return exists(select 1 from public.applications where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='INTERVIEW' then return exists(select 1 from public.interviews where id=p_entity_id and agency_id=p_agency);
  elsif v_type='OFFER' then return exists(select 1 from public.offers where id=p_entity_id and agency_id=p_agency);
  elsif v_type='PLACEMENT' then return exists(select 1 from public.placements where id=p_entity_id and agency_id=p_agency);
  elsif v_type='CLIENT' then return exists(select 1 from public.recruitment_clients where id=p_entity_id and agency_id=p_agency);
  elsif v_type='SUBMISSION' then return exists(select 1 from public.candidate_submissions where id=p_entity_id and agency_id=p_agency);
  elsif v_type='TASK' then return exists(select 1 from public.crm_tasks where id=p_entity_id and agency_id=p_agency and archived_at is null);
  end if;
  return false;
end;
$fn$;
revoke all on function private.xzrecruiter_entity_belongs_to_agency(uuid,text,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_attachment_object_access(
  p_agency uuid,p_user uuid,p_business_role text,p_entity_type text,p_entity_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_type text:=upper(coalesce(p_entity_type,''));v_candidate uuid;v_job uuid;
begin
  if not private.xzrecruiter_entity_belongs_to_agency(p_agency,v_type,p_entity_id) then return false; end if;
  if upper(coalesce(p_business_role,''))<>'RECRUITER' then return true; end if;

  if v_type='CANDIDATE' then
    return private.xzrecruiter_candidate_object_access(p_agency,p_user,p_business_role,p_entity_id,'candidate:view');
  elsif v_type='JOB' then
    return private.xzrecruiter_job_object_access(p_agency,p_user,p_business_role,p_entity_id);
  elsif v_type='APPLICATION' then
    select candidate_id,job_id into v_candidate,v_job
    from public.applications where id=p_entity_id and agency_id=p_agency and archived_at is null;
  elsif v_type='INTERVIEW' then
    select a.candidate_id,a.job_id into v_candidate,v_job
    from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=p_agency
    where i.id=p_entity_id and i.agency_id=p_agency;
  elsif v_type='OFFER' then
    select a.candidate_id,a.job_id into v_candidate,v_job
    from public.offers o join public.applications a on a.id=o.application_id and a.agency_id=p_agency
    where o.id=p_entity_id and o.agency_id=p_agency;
  elsif v_type='PLACEMENT' then
    select p.candidate_id,p.job_id into v_candidate,v_job
    from public.placements p where p.id=p_entity_id and p.agency_id=p_agency;
  else
    return false;
  end if;

  return v_candidate is not null
    and private.xzrecruiter_candidate_object_access(p_agency,p_user,p_business_role,v_candidate,'candidate:view')
    and private.xzrecruiter_job_object_access(p_agency,p_user,p_business_role,v_job);
end;
$fn$;
revoke all on function private.xzrecruiter_attachment_object_access(uuid,uuid,text,text,uuid) from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 3) Security events, retention/export foundation, rate limits
-- ---------------------------------------------------------------------------
create table if not exists public.security_events(
  id uuid primary key default gen_random_uuid(),
  agency_id uuid references public.agencies(id) on delete restrict,
  actor_user_id uuid references public.users(id) on delete set null,
  actor_role text,
  event_type text not null,
  severity text not null default 'INFO' check(severity in ('INFO','WARN','HIGH','CRITICAL')),
  entity_type text,
  entity_id uuid,
  request_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_xzr_security_events_agency_time
  on public.security_events(agency_id,created_at desc);
create index if not exists idx_xzr_security_events_type_time
  on public.security_events(event_type,created_at desc);

create table if not exists public.organization_data_governance(
  agency_id uuid primary key references public.agencies(id) on delete cascade,
  candidate_retention_days integer not null default 2555 check(candidate_retention_days between 30 and 3650),
  security_event_retention_days integer not null default 730 check(security_event_retention_days between 90 and 3650),
  allow_recruiter_bulk_export boolean not null default false,
  allow_recruitment_manager_bulk_export boolean not null default false,
  updated_by_user_id uuid references public.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Invitation records are future privilege-bearing inputs: constrain them to Step-7 business roles.
alter table public.workspace_invitations
  drop constraint if exists workspace_invitations_business_role_step7_check;
alter table public.workspace_invitations
  drop constraint if exists workspace_invitations_business_role_check;
alter table public.workspace_invitations
  add constraint workspace_invitations_business_role_check
  check (business_role in ('ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER','RECRUITER','COMPLIANCE_REVIEWER','CLIENT_USER'));

alter table public.workspace_invitations
  drop constraint if exists workspace_invitations_owner_escalation_check;
alter table public.workspace_invitations
  add constraint workspace_invitations_owner_escalation_check
  check (upper(coalesce(business_role,'')) <> 'OWNER');

create table if not exists public.security_rate_limits(
  scope text not null,
  key_hash text not null,
  window_started_at timestamptz not null,
  hits integer not null check(hits>=0),
  updated_at timestamptz not null default now(),
  primary key(scope,key_hash)
);
create index if not exists idx_xzr_rate_limit_updated on public.security_rate_limits(updated_at);

create or replace function private.xzrecruiter_log_security_event(
  p_agency uuid,p_actor uuid,p_role text,p_event text,p_severity text,
  p_entity_type text default null,p_entity_id uuid default null,p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path='public','pg_temp'
as $fn$
begin
  insert into public.security_events(
    agency_id,actor_user_id,actor_role,event_type,severity,entity_type,entity_id,metadata
  ) values(
    p_agency,p_actor,nullif(left(coalesce(p_role,''),80),''),
    left(coalesce(p_event,'security.event'),160),
    case when upper(coalesce(p_severity,'')) in ('INFO','WARN','HIGH','CRITICAL') then upper(p_severity) else 'WARN' end,
    nullif(left(coalesce(p_entity_type,''),80),''),
    p_entity_id,
    coalesce(p_metadata,'{}'::jsonb)
  );
end;
$fn$;
revoke all on function private.xzrecruiter_log_security_event(uuid,uuid,text,text,text,text,uuid,jsonb) from public,anon,authenticated;

create or replace function private.xzrecruiter_invitation_security_event()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_event text;v_role text;
begin
  if tg_op='INSERT' then v_event:='membership.invite_created';
  elsif old.status is distinct from new.status then v_event:='membership.invite_status_changed';
  elsif old.business_role is distinct from new.business_role or old.rbac_role is distinct from new.rbac_role then
    v_event:='membership.invite_role_changed';
  else return new;
  end if;
  select private.xzrecruiter_normalize_business_role(new.agency_id,new.invited_by_user_id,m.role)
    into v_role
  from public.agency_memberships m
  where m.agency_id=new.agency_id and m.user_id=new.invited_by_user_id
  limit 1;
  perform private.xzrecruiter_log_security_event(
    new.agency_id,new.invited_by_user_id,v_role,v_event,'WARN','workspace_invitation',new.id,
    jsonb_build_object(
      'status',new.status,'rbac_role',new.rbac_role,'business_role',new.business_role,
      'email_hash',encode(extensions.digest(lower(coalesce(new.email,'')),'sha256'),'hex')
    )
  );
  return new;
end;
$fn$;
revoke all on function private.xzrecruiter_invitation_security_event() from public,anon,authenticated;

drop trigger if exists xzr_workspace_invitation_security_event on public.workspace_invitations;
create trigger xzr_workspace_invitation_security_event
after insert or update of status,rbac_role,business_role on public.workspace_invitations
for each row execute function private.xzrecruiter_invitation_security_event();

create or replace function public.xzrecruiter_consume_rate_limit(
  p_scope text,p_key_hash text,p_limit integer,p_window_seconds integer
) returns jsonb
language plpgsql
security definer
set search_path='public','pg_temp'
as $fn$
declare
  v_scope text:=lower(btrim(coalesce(p_scope,'')));
  v_key text:=lower(btrim(coalesce(p_key_hash,'')));
  v_limit integer:=least(greatest(coalesce(p_limit,1),1),1000);
  v_window integer:=least(greatest(coalesce(p_window_seconds,60),10),86400);
  v_hits integer;v_started timestamptz;
begin
  if v_scope!~'^[a-z0-9:_-]{2,80}$' or v_key!~'^[a-f0-9]{64}$' then
    return jsonb_build_object('ok',false,'allowed',false,'error','invalid_rate_limit_key');
  end if;

  insert into public.security_rate_limits(scope,key_hash,window_started_at,hits,updated_at)
  values(v_scope,v_key,now(),1,now())
  on conflict(scope,key_hash) do update
  set hits=case
      when public.security_rate_limits.window_started_at + make_interval(secs=>v_window)<=now() then 1
      else public.security_rate_limits.hits+1 end,
      window_started_at=case
      when public.security_rate_limits.window_started_at + make_interval(secs=>v_window)<=now() then now()
      else public.security_rate_limits.window_started_at end,
      updated_at=now()
  returning hits,window_started_at into v_hits,v_started;

  return jsonb_build_object(
    'ok',true,'allowed',v_hits<=v_limit,'remaining',greatest(v_limit-v_hits,0),
    'reset_at',v_started+make_interval(secs=>v_window)
  );
end;
$fn$;
revoke all on function public.xzrecruiter_consume_rate_limit(text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_consume_rate_limit(text,text,integer,integer) to service_role;

create or replace function public.xzrecruiter_security_event_context(
  p_token text,p_limit integer default 100
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_limit integer:=least(greatest(coalesce(p_limit,100),1),500);
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_has_permission(v_role,'audit:view') then
    return jsonb_build_object('ok',false,'error','forbidden');
  end if;
  return jsonb_build_object(
    'ok',true,
    'events',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select id,event_type,severity,entity_type,entity_id,actor_user_id,actor_role,metadata,created_at
        from public.security_events
        where agency_id=v_agency
        order by created_at desc
        limit v_limit
      ) x
    ),'[]'::jsonb)
  );
end;
$fn$;
revoke all on function public.xzrecruiter_security_event_context(text,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_security_event_context(text,integer) to anon,authenticated;

create or replace function private.xzrecruiter_membership_session_guard()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_event text;
begin
  v_agency:=coalesce(new.agency_id,old.agency_id);
  v_user:=coalesce(new.user_id,old.user_id);
  v_role:=coalesce(new.role,old.role);

  if tg_op='DELETE' then
    v_event:='membership.removed';
  elsif old.role is distinct from new.role then
    v_event:='membership.role_changed';
  elsif old.active is distinct from new.active then
    v_event:=case when new.active then 'membership.enabled' else 'membership.disabled' end;
  else
    return coalesce(new,old);
  end if;

  update public.user_sessions
  set revoked_at=coalesce(revoked_at,now())
  where agency_id=v_agency and user_id=v_user and revoked_at is null;

  perform private.xzrecruiter_log_security_event(
    v_agency,null,v_role,v_event,'WARN','membership',v_user,
    jsonb_build_object('sessions_revoked',true)
  );
  return coalesce(new,old);
end;
$fn$;
revoke all on function private.xzrecruiter_membership_session_guard() from public,anon,authenticated;

drop trigger if exists xzr_membership_session_guard on public.agency_memberships;
create trigger xzr_membership_session_guard
after update of role,active or delete on public.agency_memberships
for each row execute function private.xzrecruiter_membership_session_guard();

create or replace function private.xzrecruiter_disabled_user_session_guard()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
begin
  if old.disabled_at is distinct from new.disabled_at and new.disabled_at is not null then
    update public.user_sessions
    set revoked_at=coalesce(revoked_at,now())
    where user_id=new.id and revoked_at is null;
  end if;
  return new;
end;
$fn$;
revoke all on function private.xzrecruiter_disabled_user_session_guard() from public,anon,authenticated;

drop trigger if exists xzr_disabled_user_session_guard on public.users;
create trigger xzr_disabled_user_session_guard
after update of disabled_at on public.users
for each row execute function private.xzrecruiter_disabled_user_session_guard();

-- ---------------------------------------------------------------------------
-- 4) Data classification
-- ---------------------------------------------------------------------------
alter table public.candidate_documents
  add column if not exists data_classification text not null default 'HIGHLY_SENSITIVE';
alter table public.recruitment_attachments
  add column if not exists data_classification text not null default 'CONFIDENTIAL';
alter table public.requirement_jd_sources
  add column if not exists data_classification text not null default 'CONFIDENTIAL';
alter table public.requirement_hiring_briefs
  add column if not exists data_classification text not null default 'INTERNAL';
alter table public.candidate_submissions
  add column if not exists data_classification text not null default 'CONFIDENTIAL';
alter table public.application_screening_sessions
  add column if not exists data_classification text not null default 'HIGHLY_SENSITIVE';
alter table public.application_screening_answers
  add column if not exists data_classification text not null default 'HIGHLY_SENSITIVE';
alter table public.candidate_fact_assertions
  add column if not exists data_classification text not null default 'HIGHLY_SENSITIVE';
alter table public.candidate_submission_versions
  add column if not exists data_classification text not null default 'CONFIDENTIAL';

do $do$
declare t text;
begin
  foreach t in array array[
    'candidate_documents','recruitment_attachments','requirement_jd_sources',
    'requirement_hiring_briefs','candidate_submissions','application_screening_sessions',
    'application_screening_answers','candidate_fact_assertions','candidate_submission_versions'
  ] loop
    if not exists(
      select 1 from pg_constraint
      where conrelid=('public.'||t)::regclass and conname='xzr_'||t||'_classification_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check(data_classification in (''PUBLIC_LOW'',''INTERNAL'',''CONFIDENTIAL'',''HIGHLY_SENSITIVE''))',
        t,'xzr_'||t||'_classification_check'
      );
    end if;
  end loop;
end
$do$;

-- Core tenant entity classification foundation.
do $do$
declare r record;v_default text;v_constraint text;
begin
  for r in
    select * from (values
      ('candidates','HIGHLY_SENSITIVE'),
      ('applications','HIGHLY_SENSITIVE'),
      ('recruitment_jobs','CONFIDENTIAL'),
      ('recruitment_clients','CONFIDENTIAL'),
      ('crm_contacts','CONFIDENTIAL'),
      ('crm_tasks','INTERNAL'),
      ('recruitment_activity_events','INTERNAL'),
      ('interviews','CONFIDENTIAL'),
      ('offers','CONFIDENTIAL'),
      ('placements','CONFIDENTIAL'),
      ('application_screening_summaries','HIGHLY_SENSITIVE'),
      ('application_screening_overrides','HIGHLY_SENSITIVE'),
      ('application_match_versions','HIGHLY_SENSITIVE'),
      ('requirement_ai_runs','CONFIDENTIAL')
    ) as x(table_name,default_classification)
  loop
    if to_regclass('public.'||r.table_name) is not null then
      execute format(
        'alter table public.%I add column if not exists data_classification text not null default %L',
        r.table_name,r.default_classification
      );
      v_constraint:='xzr_'||r.table_name||'_core_classification_check';
      if not exists(
        select 1 from pg_constraint
        where conrelid=('public.'||r.table_name)::regclass and conname=v_constraint
      ) then
        execute format(
          'alter table public.%I add constraint %I check(data_classification in (''PUBLIC_LOW'',''INTERNAL'',''CONFIDENTIAL'',''HIGHLY_SENSITIVE''))',
          r.table_name,v_constraint
        );
      end if;
    end if;
  end loop;
end
$do$;

-- ---------------------------------------------------------------------------
-- 5) Direct table/API hard boundary
-- ---------------------------------------------------------------------------
do $do$
declare r record;
begin
  for r in
    select distinct table_name
    from information_schema.columns
    where table_schema='public' and column_name='agency_id'
  loop
    execute format('alter table public.%I enable row level security',r.table_name);
    if not exists(
      select 1 from pg_policies
      where schemaname='public' and tablename=r.table_name and policyname='xzrecruiter_data_api_deny'
    ) then
      execute format(
        'create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',
        r.table_name
      );
    end if;
  end loop;
end
$do$;

do $do$
declare t text;
begin
  foreach t in array array[
    'users','user_credentials','user_sessions','auth_login_events','password_reset_tokens',
    'agencies','agency_memberships','security_rate_limits'
  ] loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I enable row level security',t);
      if not exists(
        select 1 from pg_policies
        where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny'
      ) then
        execute format(
          'create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',
          t
        );
      end if;
    end if;
  end loop;
end
$do$;

revoke select,insert,update,delete on all tables in schema public from anon,authenticated;
alter default privileges in schema public revoke select,insert,update,delete on tables from anon,authenticated;
alter default privileges in schema public revoke execute on functions from public,anon,authenticated;

-- Existing SECURITY DEFINER functions must never remain executable merely via the implicit PUBLIC grant.
do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef=true
  loop
    execute format('revoke execute on function %s from public',r.signature);
  end loop;
end
$do$;

-- Views use caller privileges/RLS rather than owner privileges.
do $do$
declare r record;
begin
  for r in
    select n.nspname as schema_name,c.relname as view_name
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='v'
  loop
    execute format('alter view %I.%I set (security_invoker=true)',r.schema_name,r.view_name);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------------
-- 6) Sensitive document + attachment authorization
-- ---------------------------------------------------------------------------
do $do$
begin
  if to_regprocedure('public.xzrecruiter_candidate_document_access(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_candidate_document_access_step7_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_candidate_document_access(text,uuid) rename to xzrecruiter_candidate_document_access_step7_legacy';
  end if;
end
$do$;
revoke all on function public.xzrecruiter_candidate_document_access_step7_legacy(text,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_candidate_document_access(p_token text,p_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_candidate uuid;v_result jsonb;v_document_type text;v_classification text;v_permission text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  select candidate_id,upper(coalesce(document_type,'')),upper(coalesce(data_classification,'HIGHLY_SENSITIVE'))
  into v_candidate,v_document_type,v_classification
  from public.candidate_documents
  where id=p_document_id and agency_id=v_agency and archived_at is null;
  if v_candidate is null then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'document.access_denied','HIGH','candidate_document',p_document_id,jsonb_build_object('reason','not_found_or_cross_tenant'));
    return jsonb_build_object('ok',false,'error','candidate_document_access_forbidden');
  end if;
  v_permission:=case when v_document_type='RESUME' then 'document:resume_view' else 'document:sensitive_view' end;
  if not private.xzrecruiter_has_permission(v_role,v_permission) then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'document.access_denied','HIGH','candidate_document',p_document_id,jsonb_build_object('reason','permission','required_permission',v_permission,'classification',v_classification));
    return jsonb_build_object('ok',false,'error','candidate_document_access_forbidden');
  end if;
  if not private.xzrecruiter_candidate_object_access(v_agency,v_user,v_role,v_candidate,'candidate:view') then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'document.access_denied','HIGH','candidate_document',p_document_id,jsonb_build_object('reason','scope'));
    return jsonb_build_object('ok',false,'error','candidate_document_access_forbidden');
  end if;
  v_result:=public.xzrecruiter_candidate_document_access_step7_legacy(p_token,p_document_id);
  if coalesce(v_result->>'ok','false')='true' then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'document.sensitive_access','INFO','candidate_document',p_document_id,jsonb_build_object('candidate_id',v_candidate));
  end if;
  return v_result;
end;
$fn$;
revoke all on function public.xzrecruiter_candidate_document_access(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_candidate_document_access(text,uuid) to anon,authenticated;

do $do$
begin
  if to_regprocedure('public.xzrecruiter_attachment_context(text,text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_attachment_context_step7_legacy(text,text,uuid)') is null then
    execute 'alter function public.xzrecruiter_attachment_context(text,text,uuid) rename to xzrecruiter_attachment_context_step7_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_prepare_attachment(text,text,uuid,text,text,bigint)') is not null
     and to_regprocedure('public.xzrecruiter_prepare_attachment_step7_legacy(text,text,uuid,text,text,bigint)') is null then
    execute 'alter function public.xzrecruiter_prepare_attachment(text,text,uuid,text,text,bigint) rename to xzrecruiter_prepare_attachment_step7_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_attachment_access(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_attachment_access_step7_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_attachment_access(text,uuid) rename to xzrecruiter_attachment_access_step7_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_archive_attachment(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_archive_attachment_step7_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_archive_attachment(text,uuid) rename to xzrecruiter_archive_attachment_step7_legacy';
  end if;
end
$do$;

revoke all on function public.xzrecruiter_attachment_context_step7_legacy(text,text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_prepare_attachment_step7_legacy(text,text,uuid,text,text,bigint) from public,anon,authenticated;
revoke all on function public.xzrecruiter_attachment_access_step7_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_archive_attachment_step7_legacy(text,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_attachment_gate(
  p_token text,p_entity_type text,p_entity_id uuid,p_permission text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_has_permission(v_role,p_permission)
     or not private.xzrecruiter_attachment_object_access(v_agency,v_user,v_role,p_entity_type,p_entity_id) then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'attachment.access_denied','HIGH',lower(p_entity_type),p_entity_id,jsonb_build_object('permission',p_permission));
    return jsonb_build_object('ok',false,'error','attachment_access_forbidden');
  end if;
  return jsonb_build_object('ok',true,'agency_id',v_agency,'user_id',v_user,'business_role',v_role);
end;
$fn$;
revoke all on function private.xzrecruiter_attachment_gate(text,text,uuid,text) from public,anon,authenticated;

create or replace function public.xzrecruiter_attachment_context(p_token text,p_entity_type text,p_entity_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','pg_temp' as $fn$
declare g jsonb;
begin
  g:=private.xzrecruiter_attachment_gate(p_token,p_entity_type,p_entity_id,'document:sensitive_view');
  if coalesce(g->>'ok','false')<>'true' then return g; end if;
  return public.xzrecruiter_attachment_context_step7_legacy(p_token,p_entity_type,p_entity_id);
end;$fn$;

create or replace function public.xzrecruiter_prepare_attachment(p_token text,p_entity_type text,p_entity_id uuid,p_filename text,p_mime_type text,p_size_bytes bigint)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $fn$
declare g jsonb;
begin
  g:=private.xzrecruiter_attachment_gate(p_token,p_entity_type,p_entity_id,'document:review');
  if coalesce(g->>'ok','false')<>'true' then return g; end if;
  return public.xzrecruiter_prepare_attachment_step7_legacy(p_token,p_entity_type,p_entity_id,p_filename,p_mime_type,p_size_bytes);
end;$fn$;

create or replace function public.xzrecruiter_attachment_access(p_token text,p_attachment_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_type text;v_entity uuid;g jsonb;v_result jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select entity_type,entity_id into v_type,v_entity
  from public.recruitment_attachments where id=p_attachment_id and agency_id=v_agency and archived_at is null;
  if v_entity is null then return jsonb_build_object('ok',false,'error','attachment_not_found'); end if;
  g:=private.xzrecruiter_attachment_gate(p_token,v_type,v_entity,'document:sensitive_view');
  if coalesce(g->>'ok','false')<>'true' then return g; end if;
  v_result:=public.xzrecruiter_attachment_access_step7_legacy(p_token,p_attachment_id);
  v_role:=g->>'business_role';
  if coalesce(v_result->>'ok','false')='true' then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'attachment.sensitive_access','INFO',lower(v_type),v_entity,jsonb_build_object('attachment_id',p_attachment_id));
  end if;
  return v_result;
end;$fn$;

create or replace function public.xzrecruiter_archive_attachment(p_token text,p_attachment_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $fn$
declare v_agency uuid;v_type text;v_entity uuid;g jsonb;
begin
  select agency_id into v_agency from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select entity_type,entity_id into v_type,v_entity
  from public.recruitment_attachments where id=p_attachment_id and agency_id=v_agency and archived_at is null;
  if v_entity is null then return jsonb_build_object('ok',false,'error','attachment_not_found'); end if;
  g:=private.xzrecruiter_attachment_gate(p_token,v_type,v_entity,'document:review');
  if coalesce(g->>'ok','false')<>'true' then return g; end if;
  return public.xzrecruiter_archive_attachment_step7_legacy(p_token,p_attachment_id);
end;$fn$;

revoke all on function public.xzrecruiter_attachment_context(text,text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_prepare_attachment(text,text,uuid,text,text,bigint) from public,anon,authenticated;
revoke all on function public.xzrecruiter_attachment_access(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_archive_attachment(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_attachment_context(text,text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_prepare_attachment(text,text,uuid,text,text,bigint) to anon,authenticated;
grant execute on function public.xzrecruiter_attachment_access(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_attachment(text,uuid) to anon,authenticated;

-- ---------------------------------------------------------------------------
-- 7) Bulk export, submission idempotency and race hardening
-- ---------------------------------------------------------------------------
do $do$
begin
  if exists(
    select 1
    from public.candidate_submissions
    group by agency_id,application_id
    having count(*)>1
  ) then
    raise exception 'step7_preflight_duplicate_candidate_submissions';
  end if;
end
$do$;

create unique index if not exists uq_xzr_submission_application
  on public.candidate_submissions(agency_id,application_id);

do $do$
begin
  if to_regprocedure('public.xzrecruiter_candidate_export(text,uuid[])') is not null
     and to_regprocedure('public.xzrecruiter_candidate_export_step7_legacy(text,uuid[])') is null then
    execute 'alter function public.xzrecruiter_candidate_export(text,uuid[]) rename to xzrecruiter_candidate_export_step7_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean)') is not null
     and to_regprocedure('public.xzrecruiter_save_candidate_submission_step7_legacy(text,uuid,jsonb,boolean)') is null then
    execute 'alter function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) rename to xzrecruiter_save_candidate_submission_step7_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_review_internal_submission(text,uuid,text,text)') is not null
     and to_regprocedure('public.xzrecruiter_review_internal_submission_step7_legacy(text,uuid,text,text)') is null then
    execute 'alter function public.xzrecruiter_review_internal_submission(text,uuid,text,text) rename to xzrecruiter_review_internal_submission_step7_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_mark_client_submitted(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_mark_client_submitted_step7_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_mark_client_submitted(text,uuid) rename to xzrecruiter_mark_client_submitted_step7_legacy';
  end if;
end
$do$;

revoke all on function public.xzrecruiter_candidate_export_step7_legacy(text,uuid[]) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_candidate_submission_step7_legacy(text,uuid,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.xzrecruiter_review_internal_submission_step7_legacy(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_mark_client_submitted_step7_legacy(text,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_candidate_export(p_token text,p_candidate_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_result jsonb;v_rate jsonb;v_allowed boolean:=false;v_count integer:=coalesce(array_length(p_candidate_ids,1),0);
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  if v_count<1 or v_count>500 then return jsonb_build_object('ok',false,'error','invalid_export_size'); end if;
  v_allowed:=v_role in ('OWNER','ADMIN')
    or (v_role='RECRUITMENT_MANAGER' and coalesce((select allow_recruitment_manager_bulk_export from public.organization_data_governance where agency_id=v_agency),false))
    or (v_role='RECRUITER' and coalesce((select allow_recruiter_bulk_export from public.organization_data_governance where agency_id=v_agency),false));
  if not v_allowed then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'candidate.export_denied','HIGH','candidate',null,jsonb_build_object('requested_count',v_count));
    return jsonb_build_object('ok',false,'error','bulk_export_forbidden');
  end if;
  if exists(
    select 1 from unnest(p_candidate_ids) id
    where not private.xzrecruiter_candidate_object_access(v_agency,v_user,v_role,id,'candidate:view')
  ) then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'candidate.export_scope_denied','HIGH','candidate',null,jsonb_build_object('requested_count',v_count));
    return jsonb_build_object('ok',false,'error','candidate_access_forbidden');
  end if;
  v_rate:=public.xzrecruiter_consume_rate_limit(
    'candidate:export',
    encode(extensions.digest(v_agency::text||'|'||v_user::text,'sha256'),'hex'),
    20,3600
  );
  if coalesce((v_rate->>'allowed')::boolean,false)=false then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'candidate.export_rate_limited','HIGH','candidate',null);
    return jsonb_build_object('ok',false,'error','rate_limited');
  end if;
  v_result:=public.xzrecruiter_candidate_export_step7_legacy(p_token,p_candidate_ids);
  perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'candidate.export','WARN','candidate',null,jsonb_build_object('requested_count',coalesce(array_length(p_candidate_ids,1),0)));
  return v_result;
end;$fn$;
revoke all on function public.xzrecruiter_candidate_export(text,uuid[]) from public,anon,authenticated;
grant execute on function public.xzrecruiter_candidate_export(text,uuid[]) to anon,authenticated;

create or replace function public.xzrecruiter_save_candidate_submission(p_token text,p_application_id uuid,p_submission jsonb,p_submit boolean default false)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_candidate uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_has_permission(v_role,'submission:create') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select candidate_id into v_candidate from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null;
  if v_candidate is null or not private.xzrecruiter_candidate_object_access(v_agency,v_user,v_role,v_candidate,'candidate:view') then
    return jsonb_build_object('ok',false,'error','candidate_access_forbidden');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_agency::text||'|submission|'||p_application_id::text,0));
  return public.xzrecruiter_save_candidate_submission_step7_legacy(p_token,p_application_id,p_submission,p_submit);
end;$fn$;

create or replace function public.xzrecruiter_review_internal_submission(p_token text,p_submission_id uuid,p_action text,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_has_permission(v_role,'submission:am_review') then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'submission.am_review_denied','HIGH','submission',p_submission_id);
    return jsonb_build_object('ok',false,'error','am_only');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_agency::text||'|submission|'||p_submission_id::text,0));
  return public.xzrecruiter_review_internal_submission_step7_legacy(p_token,p_submission_id,p_action,p_note);
end;$fn$;

create or replace function public.xzrecruiter_mark_client_submitted(p_token text,p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_result jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_has_permission(v_role,'submission:client_submit') then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'submission.client_submit_denied','CRITICAL','submission',p_submission_id);
    return jsonb_build_object('ok',false,'error','am_only');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_agency::text||'|submission|'||p_submission_id::text,0));
  v_result:=public.xzrecruiter_mark_client_submitted_step7_legacy(p_token,p_submission_id);
  if coalesce(v_result->>'ok','false')='true' then
    perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'submission.client_submitted','WARN','submission',p_submission_id);
  end if;
  return v_result;
end;$fn$;

revoke all on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.xzrecruiter_review_internal_submission(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_mark_client_submitted(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) to anon,authenticated;
grant execute on function public.xzrecruiter_review_internal_submission(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_mark_client_submitted(text,uuid) to anon,authenticated;

-- ---------------------------------------------------------------------------
-- 8) Commercial data boundary: one DB dispatcher; old RPCs no longer callable directly
-- ---------------------------------------------------------------------------
create or replace function public.xzrecruiter_crm_dispatch(p_token text,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_role text;v_action text:=coalesce(p_action,'');v_payload jsonb:=coalesce(p_payload,'{}'::jsonb);
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_role:=private.xzrecruiter_normalize_business_role(v_agency,v_user,v_membership_role);

  if v_action=any(array['referenceContext','search','businessPipeline','vendorContext','client360','contact360','opportunity360','savedViewContext']) then
    if not private.xzrecruiter_has_permission(v_role,'commercial:view') then
      perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'commercial.read_denied','HIGH','crm',null,jsonb_build_object('action',v_action));
      return jsonb_build_object('ok',false,'error','commercial_access_forbidden');
    end if;
  else
    if not private.xzrecruiter_has_permission(v_role,'commercial:edit') then
      perform private.xzrecruiter_log_security_event(v_agency,v_user,v_role,'commercial.write_denied','HIGH','crm',null,jsonb_build_object('action',v_action));
      return jsonb_build_object('ok',false,'error','commercial_edit_forbidden');
    end if;
  end if;

  if v_action='referenceContext' then return public.xzrecruiter_crm_reference_context(p_token);
  elsif v_action='search' then return public.xzrecruiter_crm_search(p_token,v_payload->>'module',coalesce(v_payload->>'query',''),coalesce(v_payload->'filters','{}'::jsonb),coalesce((v_payload->>'limit')::integer,50),coalesce((v_payload->>'offset')::integer,0));
  elsif v_action='businessPipeline' then return public.xzrecruiter_business_pipeline_context(p_token,coalesce((v_payload->>'limit')::integer,500));
  elsif v_action='vendorContext' then return public.xzrecruiter_vendor_context(p_token,coalesce(v_payload->>'query',''),coalesce((v_payload->>'limit')::integer,50),coalesce((v_payload->>'offset')::integer,0));
  elsif v_action='saveClient' then return public.xzrecruiter_save_client(p_token,v_payload);
  elsif v_action='saveContact' then return public.xzrecruiter_save_contact(p_token,v_payload);
  elsif v_action='saveOpportunity' then return public.xzrecruiter_save_opportunity(p_token,v_payload);
  elsif v_action='moveOpportunity' then return public.xzrecruiter_move_opportunity_stage(p_token,(v_payload->>'opportunityId')::uuid,(v_payload->>'stageId')::uuid,nullif(v_payload->>'reason',''));
  elsif v_action='saveActivity' then return public.xzrecruiter_save_crm_activity(p_token,v_payload);
  elsif v_action='saveTask' then return public.xzrecruiter_save_crm_task(p_token,v_payload);
  elsif v_action='setTaskStatus' then return public.xzrecruiter_set_crm_task_status(p_token,(v_payload->>'taskId')::uuid,v_payload->>'status');
  elsif v_action='saveContract' then return public.xzrecruiter_save_client_contract(p_token,v_payload);
  elsif v_action='saveCustomValues' then return public.xzrecruiter_save_crm_custom_values(p_token,v_payload->>'entityType',(v_payload->>'entityId')::uuid,coalesce(v_payload->'values','[]'::jsonb));
  elsif v_action='client360' then return public.xzrecruiter_client_360(p_token,(v_payload->>'clientId')::uuid);
  elsif v_action='contact360' then return public.xzrecruiter_contact_360(p_token,(v_payload->>'contactId')::uuid);
  elsif v_action='opportunity360' then return public.xzrecruiter_opportunity_360(p_token,(v_payload->>'opportunityId')::uuid);
  elsif v_action='archiveEntity' then return public.xzrecruiter_archive_crm_entity(p_token,v_payload->>'entityType',(v_payload->>'entityId')::uuid);
  elsif v_action='saveSavedView' then return public.xzrecruiter_save_saved_view(p_token,v_payload);
  elsif v_action='savedViewContext' then return public.xzrecruiter_saved_view_context(p_token,v_payload->>'module');
  elsif v_action='issueClientPortal' then return public.xzrecruiter_issue_client_portal_access(p_token,(v_payload->>'clientId')::uuid,nullif(v_payload->>'contactId','')::uuid);
  elsif v_action='saveVendor' then return public.xzrecruiter_save_vendor(p_token,v_payload);
  elsif v_action='issueVendorPortal' then return public.xzrecruiter_issue_vendor_portal_access(p_token,(v_payload->>'vendorId')::uuid);
  elsif v_action='shareJobVendor' then return public.xzrecruiter_share_job_with_vendor(p_token,(v_payload->>'vendorId')::uuid,(v_payload->>'jobId')::uuid,coalesce((v_payload->>'active')::boolean,true));
  end if;
  return jsonb_build_object('ok',false,'error','unsupported_action');
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','invalid_request');
end;
$fn$;
revoke all on function public.xzrecruiter_crm_dispatch(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.xzrecruiter_crm_dispatch(text,text,jsonb) to anon,authenticated;

do $do$
declare sig regprocedure;
begin
  foreach sig in array array[
    'public.xzrecruiter_crm_reference_context(text)'::regprocedure,
    'public.xzrecruiter_crm_search(text,text,text,jsonb,integer,integer)'::regprocedure,
    'public.xzrecruiter_business_pipeline_context(text,integer)'::regprocedure,
    'public.xzrecruiter_vendor_context(text,text,integer,integer)'::regprocedure,
    'public.xzrecruiter_save_client(text,jsonb)'::regprocedure,
    'public.xzrecruiter_save_contact(text,jsonb)'::regprocedure,
    'public.xzrecruiter_save_opportunity(text,jsonb)'::regprocedure,
    'public.xzrecruiter_move_opportunity_stage(text,uuid,uuid,text)'::regprocedure,
    'public.xzrecruiter_save_crm_activity(text,jsonb)'::regprocedure,
    'public.xzrecruiter_save_crm_task(text,jsonb)'::regprocedure,
    'public.xzrecruiter_set_crm_task_status(text,uuid,text)'::regprocedure,
    'public.xzrecruiter_save_client_contract(text,jsonb)'::regprocedure,
    'public.xzrecruiter_save_crm_custom_values(text,text,uuid,jsonb)'::regprocedure,
    'public.xzrecruiter_client_360(text,uuid)'::regprocedure,
    'public.xzrecruiter_contact_360(text,uuid)'::regprocedure,
    'public.xzrecruiter_opportunity_360(text,uuid)'::regprocedure,
    'public.xzrecruiter_archive_crm_entity(text,text,uuid)'::regprocedure,
    'public.xzrecruiter_save_saved_view(text,jsonb)'::regprocedure,
    'public.xzrecruiter_saved_view_context(text,text)'::regprocedure,
    'public.xzrecruiter_issue_client_portal_access(text,uuid,uuid)'::regprocedure,
    'public.xzrecruiter_save_vendor(text,jsonb)'::regprocedure,
    'public.xzrecruiter_issue_vendor_portal_access(text,uuid)'::regprocedure,
    'public.xzrecruiter_share_job_with_vendor(text,uuid,uuid,boolean)'::regprocedure
  ] loop
    execute format('revoke all on function %s from public,anon,authenticated',sig);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------------
-- 9) Critical workflow actions mirrored into immutable security events
-- ---------------------------------------------------------------------------
create or replace function private.xzrecruiter_security_event_from_activity()
returns trigger
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_role text;
begin
  if new.action=any(array[
    'requirement.hiring_brief_approved','requirement.approved','requirement.hard_rule_updated',
    'candidate.qualified','screening.override_applied',
    'submission.internal_submitted','submission.recruiter_resubmitted','submission.am_approved',
    'submission.am_returned','submission.am_rejected','submission.client_submitted'
  ]) then
    select private.xzrecruiter_normalize_business_role(new.agency_id,new.actor_user_id,m.role)
    into v_role from public.agency_memberships m
    where m.agency_id=new.agency_id and m.user_id=new.actor_user_id limit 1;
    perform private.xzrecruiter_log_security_event(
      new.agency_id,new.actor_user_id,v_role,'workflow.'||new.action,
      case when new.action in ('submission.client_submitted','screening.override_applied') then 'WARN' else 'INFO' end,
      new.entity_type,new.entity_id,
      jsonb_build_object('activity_event_id',new.id)
    );
  end if;
  return new;
end;
$fn$;
revoke all on function private.xzrecruiter_security_event_from_activity() from public,anon,authenticated;
drop trigger if exists xzr_activity_security_mirror on public.recruitment_activity_events;
create trigger xzr_activity_security_mirror
after insert on public.recruitment_activity_events
for each row execute function private.xzrecruiter_security_event_from_activity();

-- ---------------------------------------------------------------------------
-- 10) Performance/index foundation for tenant-scoped security checks
-- ---------------------------------------------------------------------------
create index if not exists idx_xzr_candidates_tenant_owner_active
  on public.candidates(agency_id,owner_user_id,id) where archived_at is null;
create index if not exists idx_xzr_applications_tenant_candidate_job
  on public.applications(agency_id,candidate_id,job_id) where archived_at is null;
create index if not exists idx_xzr_assignments_tenant_recruiter_job
  on public.requirement_recruiter_assignments(agency_id,recruiter_user_id,job_id,assignment_status);
create index if not exists idx_xzr_documents_tenant_candidate_active
  on public.candidate_documents(agency_id,candidate_id,id) where archived_at is null;
create index if not exists idx_xzr_submissions_tenant_state
  on public.candidate_submissions(agency_id,workflow_status,updated_at desc);
create index if not exists idx_xzr_tasks_tenant_due
  on public.crm_tasks(agency_id,status,due_at) where archived_at is null;
create index if not exists idx_xzr_screening_tenant_application
  on public.application_screening_sessions(agency_id,application_id,status,updated_at desc);
create index if not exists idx_xzr_screening_answers_tenant_session
  on public.application_screening_answers(agency_id,screening_session_id,question_key);
create index if not exists idx_xzr_submission_versions_tenant_current
  on public.candidate_submission_versions(agency_id,submission_id,version_number desc);
create index if not exists idx_xzr_security_rate_limit_window
  on public.security_rate_limits(window_started_at,updated_at);

-- Audit/history tables are not directly writable by browser roles.
revoke update,delete on public.audit_events,public.security_events from anon,authenticated;
