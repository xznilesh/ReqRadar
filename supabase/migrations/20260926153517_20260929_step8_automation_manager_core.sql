-- XZ Recruiter locked roadmap Step 8: Automation + Real-Time Manager Control.
-- Core persistence only. Reuses canonical recruitment entities, crm_tasks and recruitment_activity_events.
-- No Step-9 launch/production-QA functionality is introduced.

-- Supabase-hosted Postgres supports pg_cron; Step 8 uses DB-native scheduling so
-- automation does not depend on a manager opening the product.
create extension if not exists pg_cron;

-- Compatibility-safe canonical execution fields referenced by Step 3/7.
alter table public.recruitment_jobs
  add column if not exists submission_target_daily integer not null default 0,
  add column if not exists submission_target_total integer not null default 0;

alter table public.recruitment_jobs drop constraint if exists recruitment_jobs_submission_target_daily_check;
alter table public.recruitment_jobs add constraint recruitment_jobs_submission_target_daily_check
  check (submission_target_daily between 0 and 1000);
alter table public.recruitment_jobs drop constraint if exists recruitment_jobs_submission_target_total_check;
alter table public.recruitment_jobs add constraint recruitment_jobs_submission_target_total_check
  check (submission_target_total between 0 and 10000);

create table if not exists public.requirement_recruiter_assignments (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  recruiter_user_id uuid not null references public.users(id) on delete cascade,
  assignment_status text not null default 'ACTIVE'
    check (assignment_status in ('ACTIVE','PAUSED','COMPLETED','REMOVED')),
  daily_submission_target integer not null default 0 check (daily_submission_target between 0 and 1000),
  total_submission_target integer not null default 0 check (total_submission_target between 0 and 10000),
  manager_priority text not null default 'NORMAL' check (manager_priority in ('LOW','NORMAL','HIGH','URGENT')),
  priority_context text,
  manager_instructions text,
  blocker_reason text,
  blocker_owner_user_id uuid references public.users(id) on delete set null,
  assigned_by_user_id uuid references public.users(id) on delete set null,
  assigned_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(agency_id,job_id,recruiter_user_id)
);
alter table public.requirement_recruiter_assignments enable row level security;
do $$
begin
  if not exists(
    select 1 from pg_policies where schemaname='public'
      and tablename='requirement_recruiter_assignments'
      and policyname='xzrecruiter_data_api_deny'
  ) then
    create policy xzrecruiter_data_api_deny
      on public.requirement_recruiter_assignments for all to anon,authenticated
      using(false) with check(false);
  end if;
end $$;

alter table public.candidate_submissions
  add column if not exists invalidated_at timestamptz,
  add column if not exists withdrawn_at timestamptz;

alter table public.crm_tasks
  add column if not exists job_id uuid references public.recruitment_jobs(id) on delete cascade,
  add column if not exists application_id uuid references public.applications(id) on delete cascade,
  add column if not exists candidate_id uuid references public.candidates(id) on delete cascade,
  add column if not exists task_type text,
  add column if not exists automation_key text;

alter table public.crm_tasks drop constraint if exists crm_task_parent_required;
alter table public.crm_tasks add constraint crm_task_parent_required check(
  client_id is not null or contact_id is not null or opportunity_id is not null or
  job_id is not null or application_id is not null or candidate_id is not null
);

alter table public.candidate_documents
  add column if not exists expires_at timestamptz;

create unique index if not exists uq_xzr_crm_task_automation
  on public.crm_tasks(agency_id,automation_key)
  where automation_key is not null and archived_at is null;

create index if not exists idx_xzr_step8_assignments_active
  on public.requirement_recruiter_assignments(agency_id,assignment_status,recruiter_user_id,job_id);
create index if not exists idx_xzr_step8_job_targets
  on public.recruitment_jobs(agency_id,status,target_fill_date,priority)
  where archived_at is null;
create index if not exists idx_xzr_step8_app_stage_age
  on public.applications(agency_id,job_id,stage_id,stage_entered_at,last_activity_at)
  where archived_at is null;
create index if not exists idx_xzr_step8_tasks_due
  on public.crm_tasks(agency_id,status,due_at,assigned_user_id)
  where archived_at is null;
create index if not exists idx_xzr_step8_submissions_control
  on public.candidate_submissions(agency_id,workflow_status,job_id,created_by_user_id,internal_submitted_at,client_submitted_at);
create index if not exists idx_xzr_step8_interviews_control
  on public.interviews(agency_id,status,scheduled_at,application_id);
create index if not exists idx_xzr_step8_offers_control
  on public.offers(agency_id,application_id,status,sent_at,expires_at);
create index if not exists idx_xzr_step8_placements_control
  on public.placements(agency_id,status,start_date,recruiter_user_id);
create index if not exists idx_xzr_step8_activity_control
  on public.recruitment_activity_events(agency_id,occurred_at desc,entity_type,entity_id);
create index if not exists idx_xzr_step8_documents_expiry
  on public.candidate_documents(agency_id,expires_at,candidate_id)
  where archived_at is null and expires_at is not null;

create table if not exists public.automation_control_configs (
  agency_id uuid primary key references public.agencies(id) on delete cascade,
  target_attention_hours_before_cutoff integer not null default 4 check (target_attention_hours_before_cutoff between 1 and 12),
  target_risk_hours_before_cutoff integer not null default 2 check (target_risk_hours_before_cutoff between 1 and 12),
  screening_attention_hours integer not null default 12 check (screening_attention_hours between 1 and 168),
  screening_risk_hours integer not null default 24 check (screening_risk_hours between 1 and 336),
  followup_risk_hours integer not null default 24 check (followup_risk_hours between 1 and 336),
  am_review_attention_hours integer not null default 4 check (am_review_attention_hours between 1 and 168),
  am_review_risk_hours integer not null default 8 check (am_review_risk_hours between 1 and 336),
  client_feedback_attention_hours integer not null default 24 check (client_feedback_attention_hours between 1 and 720),
  client_feedback_risk_hours integer not null default 48 check (client_feedback_risk_hours between 1 and 1440),
  pipeline_stagnation_hours integer not null default 24 check (pipeline_stagnation_hours between 1 and 720),
  requirement_no_activity_hours integer not null default 24 check (requirement_no_activity_hours between 1 and 720),
  deadline_attention_days integer not null default 3 check (deadline_attention_days between 1 and 30),
  deadline_risk_days integer not null default 1 check (deadline_risk_days between 0 and 14),
  min_viable_pipeline integer not null default 2 check (min_viable_pipeline between 0 and 50),
  alert_cooldown_minutes integer not null default 120 check (alert_cooldown_minutes between 15 and 10080),
  interview_reminder_hours integer not null default 24 check (interview_reminder_hours between 1 and 168),
  offer_action_hours integer not null default 24 check (offer_action_hours between 1 and 336),
  joining_action_days integer not null default 3 check (joining_action_days between 1 and 30),
  business_day_cutoff_local time not null default '18:00',
  enabled boolean not null default true,
  updated_by_user_id uuid references public.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.requirement_health_current (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  health_status text not null check (health_status in ('HEALTHY','NEEDS_ATTENTION','AT_RISK','BLOCKED','ON_HOLD')),
  reason_codes jsonb not null default '[]'::jsonb,
  facts jsonb not null default '{}'::jsonb,
  next_actions jsonb not null default '[]'::jsonb,
  source_fingerprint text not null,
  computed_at timestamptz not null default now(),
  primary key(agency_id,job_id)
);

create table if not exists public.automation_runs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid references public.agencies(id) on delete cascade,
  run_kind text not null default 'SCHEDULED' check (run_kind in ('SCHEDULED','MANUAL','EVENT')),
  run_status text not null default 'RUNNING' check (run_status in ('RUNNING','SUCCEEDED','FAILED','PARTIAL')),
  worker_id text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  detected_count integer not null default 0,
  created_count integer not null default 0,
  resolved_count integer not null default 0,
  task_count integer not null default 0,
  error_code text,
  error_summary text,
  metrics jsonb not null default '{}'::jsonb
);

create table if not exists public.automation_alerts (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  dedupe_key text not null,
  rule_code text not null,
  category text not null check (category in (
    'TARGET_ALERT','FOLLOW_UP_REMINDER','SCREENING_REMINDER','AM_REVIEW_REMINDER',
    'CLIENT_FEEDBACK_REMINDER','INTERVIEW_REMINDER','DOCUMENT_EXPIRY',
    'REQUIREMENT_HEALTH','PIPELINE_STAGNATION','DEADLINE_RISK','OFFER_ACTION','JOINING_ACTION'
  )),
  severity text not null check (severity in ('INFO','ATTENTION','URGENT')),
  lifecycle text not null default 'OPEN' check (lifecycle in ('OPEN','ACKNOWLEDGED','RESOLVED','DISMISSED')),
  entity_type text not null,
  entity_id uuid not null,
  job_id uuid references public.recruitment_jobs(id) on delete cascade,
  application_id uuid references public.applications(id) on delete cascade,
  candidate_id uuid references public.candidates(id) on delete cascade,
  owner_user_id uuid references public.users(id) on delete set null,
  target_role text,
  reason_codes jsonb not null default '[]'::jsonb,
  reason_summary text not null,
  recommended_action text not null,
  due_at timestamptz,
  first_detected_at timestamptz not null default now(),
  last_detected_at timestamptz not null default now(),
  last_detected_run_id uuid references public.automation_runs(id) on delete set null,
  acknowledged_by_user_id uuid references public.users(id) on delete set null,
  acknowledged_at timestamptz,
  dismissed_by_user_id uuid references public.users(id) on delete set null,
  dismissed_at timestamptz,
  resolved_at timestamptz,
  resolution_reason text,
  occurrence_count integer not null default 1,
  source_fingerprint text not null,
  metadata jsonb not null default '{}'::jsonb,
  unique(agency_id,dedupe_key)
);

create table if not exists public.automation_domain_events (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  source_activity_event_id uuid not null,
  event_type text not null check (event_type in (
    'REQUIREMENT_ACTIVATED','REQUIREMENT_UPDATED','RECRUITER_ASSIGNED','CANDIDATE_SOURCED',
    'SCREENING_STARTED','SCREENING_COMPLETED','CANDIDATE_QUALIFIED','SUBMISSION_CREATED',
    'SUBMISSION_RETURNED','SUBMISSION_AM_APPROVED','CLIENT_SUBMITTED','CLIENT_FEEDBACK_RECEIVED',
    'INTERVIEW_SCHEDULED','INTERVIEW_COMPLETED','OFFER_CREATED','CANDIDATE_JOINED','TASK_CHANGED'
  )),
  entity_type text not null,
  entity_id uuid not null,
  event_status text not null default 'PENDING' check (event_status in ('PENDING','PROCESSING','PROCESSED','FAILED')),
  attempt_count integer not null default 0 check (attempt_count between 0 and 20),
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(source_activity_event_id)
);

create table if not exists public.automation_alert_events (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  alert_id uuid not null references public.automation_alerts(id) on delete cascade,
  event_type text not null check (event_type in ('CREATED','REFRESHED','ACKNOWLEDGED','RESOLVED','DISMISSED','REOPENED')),
  actor_user_id uuid references public.users(id) on delete set null,
  event_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists idx_xzr_step8_health
  on public.requirement_health_current(agency_id,health_status,computed_at desc);
create index if not exists idx_xzr_step8_alert_queue
  on public.automation_alerts(agency_id,lifecycle,severity,last_detected_at desc);
create index if not exists idx_xzr_step8_alert_owner
  on public.automation_alerts(agency_id,owner_user_id,lifecycle,due_at);
create index if not exists idx_xzr_step8_alert_role
  on public.automation_alerts(agency_id,target_role,lifecycle,severity);
create index if not exists idx_xzr_step8_runs
  on public.automation_runs(agency_id,started_at desc,run_status);
create index if not exists idx_xzr_step8_domain_events_pending
  on public.automation_domain_events(event_status,created_at,agency_id)
  where event_status in ('PENDING','PROCESSING');

alter table public.automation_control_configs enable row level security;
alter table public.requirement_health_current enable row level security;
alter table public.automation_runs enable row level security;
alter table public.automation_alerts enable row level security;
alter table public.automation_alert_events enable row level security;
alter table public.automation_domain_events enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'automation_control_configs','requirement_health_current','automation_runs',
    'automation_alerts','automation_alert_events','automation_domain_events'
  ] loop
    if not exists(
      select 1 from pg_policies where schemaname='public' and tablename=t
        and policyname='xzrecruiter_data_api_deny'
    ) then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon,authenticated using(false) with check(false)',t);
    end if;
    execute format('revoke all on public.%I from public,anon,authenticated',t);
  end loop;
end $$;

-- Alert history is append-only.
create or replace function private.xzrecruiter_step8_immutable_alert_event()
returns trigger language plpgsql security invoker set search_path='pg_temp'
as $$
begin
  raise exception 'immutable_step8_alert_event';
end;
$$;
revoke all on function private.xzrecruiter_step8_immutable_alert_event() from public,anon,authenticated;

drop trigger if exists xzr_step8_alert_events_immutable on public.automation_alert_events;
create trigger xzr_step8_alert_events_immutable
before update or delete on public.automation_alert_events
for each row execute function private.xzrecruiter_step8_immutable_alert_event();

-- Extend the Step-7 centralized capability map for Step-8 surfaces.
create or replace function private.xzrecruiter_has_permission(p_role text,p_permission text)
returns boolean
language sql immutable security invoker set search_path='pg_temp'
as $$
  select case upper(coalesce(p_role,''))
    when 'OWNER' then true
    when 'ADMIN' then true
    when 'RECRUITMENT_MANAGER' then lower(p_permission)=any(array[
      'requirement:create','requirement:approve','requirement:assign',
      'candidate:view','candidate:edit','candidate:screen',
      'submission:create','document:resume_view','document:review','audit:view',
      'manager:view','manager:control','automation:ack'
    ])
    when 'ACCOUNT_MANAGER' then lower(p_permission)=any(array[
      'requirement:create','requirement:approve','requirement:assign',
      'candidate:view','submission:am_review','submission:client_submit',
      'commercial:view','commercial:edit','document:resume_view','document:sensitive_view','document:review','audit:view',
      'automation:ack'
    ])
    when 'RECRUITER' then lower(p_permission)=any(array[
      'candidate:view','candidate:edit','candidate:screen','submission:create',
      'document:resume_view','automation:ack'
    ])
    when 'COMPLIANCE_REVIEWER' then lower(p_permission)=any(array[
      'candidate:view','document:resume_view','document:sensitive_view','document:review','audit:view'
    ])
    when 'CLIENT_USER' then false
    else false
  end;
$$;
revoke all on function private.xzrecruiter_has_permission(text,text) from public,anon,authenticated;


-- Step-8 event outbox: recruitment activity is the canonical domain-event source.
create or replace function private.xzrecruiter_step8_capture_domain_event()
returns trigger
language plpgsql security definer
set search_path='public','private','pg_temp'
as $$
declare v_type text;v_action text:=lower(coalesce(new.action,''));
begin
  v_type:=case
    when v_action in ('requirement.activated','requirement.am_approved','requirement.activated_for_recruiting') then 'REQUIREMENT_ACTIVATED'
    when v_action in ('requirement.assigned','requirement.recruiter_assigned','requirement.assignment_updated') then 'RECRUITER_ASSIGNED'
    when v_action like 'requirement.%' then 'REQUIREMENT_UPDATED'
    when v_action in ('candidate.sourced','candidate.associated_with_requirement') then 'CANDIDATE_SOURCED'
    when v_action in ('screening.started','candidate.screening_started') then 'SCREENING_STARTED'
    when v_action in ('screening.completed','candidate.screening_completed') then 'SCREENING_COMPLETED'
    when v_action in ('candidate.qualified','screening.qualified') then 'CANDIDATE_QUALIFIED'
    when v_action in ('submission.created','submission.generated','submission.internal_submitted') then 'SUBMISSION_CREATED'
    when v_action in ('submission.returned','submission.returned_to_recruiter') then 'SUBMISSION_RETURNED'
    when v_action in ('submission.am_approved','submission.approved') then 'SUBMISSION_AM_APPROVED'
    when v_action in ('submission.client_submitted','client.submitted') then 'CLIENT_SUBMITTED'
    when v_action='client.feedback_received' then 'CLIENT_FEEDBACK_RECEIVED'
    when v_action in ('interview.scheduled','interview.created') then 'INTERVIEW_SCHEDULED'
    when v_action in ('interview.completed','interview.feedback_recorded') then 'INTERVIEW_COMPLETED'
    when v_action in ('offer.created','offer.sent') then 'OFFER_CREATED'
    when v_action in ('candidate.joined','placement.started','joining.confirmed') then 'CANDIDATE_JOINED'
    when v_action in ('follow_up.created','task.completed','manager.task_created') then 'TASK_CHANGED'
    else null end;
  if v_type is null then return new; end if;
  insert into public.automation_domain_events(agency_id,source_activity_event_id,event_type,entity_type,entity_id)
  values(new.agency_id,new.id,v_type,new.entity_type,new.entity_id)
  on conflict(source_activity_event_id) do nothing;
  return new;
end;
$$;
revoke all on function private.xzrecruiter_step8_capture_domain_event() from public,anon,authenticated;

drop trigger if exists xzr_step8_activity_event_outbox on public.recruitment_activity_events;
create trigger xzr_step8_activity_event_outbox
after insert on public.recruitment_activity_events
for each row execute function private.xzrecruiter_step8_capture_domain_event();
