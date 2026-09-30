-- XZ Recruiter locked roadmap Step 3: Recruiter Execution Workspace.
-- Reuses recruitment_jobs, candidates, applications, crm_tasks, candidate_submissions and recruitment_activity_events.
-- No Step-4 candidate intelligence/scoring is introduced.

alter table public.recruitment_jobs
  add column if not exists daily_submission_target integer not null default 0,
  add column if not exists submission_target_total integer not null default 0;
alter table public.recruitment_jobs
  drop constraint if exists recruitment_jobs_daily_submission_target_check;
alter table public.recruitment_jobs
  add constraint recruitment_jobs_daily_submission_target_check
  check (daily_submission_target >= 0 and daily_submission_target <= 1000);
alter table public.recruitment_jobs
  drop constraint if exists recruitment_jobs_submission_target_total_check;
alter table public.recruitment_jobs
  add constraint recruitment_jobs_submission_target_total_check
  check (submission_target_total >= 0 and submission_target_total <= 10000);

alter table public.candidate_submissions
  add column if not exists invalidated_at timestamptz,
  add column if not exists withdrawn_at timestamptz;
create index if not exists idx_xzr_submission_target_credit
  on public.candidate_submissions(agency_id,job_id,created_by_user_id,submitted_at desc)
  where workflow_status='CLIENT_SUBMITTED' and status='SUBMITTED'
    and invalidated_at is null and withdrawn_at is null;

create table if not exists public.requirement_recruiter_assignments (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  recruiter_user_id uuid not null references public.users(id) on delete cascade,
  daily_target integer not null default 0 check (daily_target >= 0 and daily_target <= 1000),
  total_submission_target integer not null default 0 check (total_submission_target >= 0 and total_submission_target <= 10000),
  assignment_priority text check (assignment_priority is null or assignment_priority in ('LOW','NORMAL','HIGH','URGENT')),
  blocker_type text,
  blocker_reason text,
  blocker_owner_user_id uuid references public.users(id) on delete set null,
  assignment_status text not null default 'ACTIVE'
    check (assignment_status in ('ACTIVE','PAUSED','COMPLETED','REMOVED')),
  priority_context text,
  manager_instructions text,
  assigned_by_user_id uuid not null references public.users(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  idempotency_key text,
  unique(agency_id,job_id,recruiter_user_id)
);
create unique index if not exists uq_xzr_requirement_assignment_idempotency
  on public.requirement_recruiter_assignments(agency_id,idempotency_key)
  where idempotency_key is not null;
create index if not exists idx_xzr_requirement_assignments_recruiter
  on public.requirement_recruiter_assignments(agency_id,recruiter_user_id,assignment_status,updated_at desc);
create index if not exists idx_xzr_requirement_assignments_job
  on public.requirement_recruiter_assignments(agency_id,job_id,assignment_status,recruiter_user_id);

alter table public.requirement_recruiter_assignments enable row level security;
drop policy if exists xzrecruiter_data_api_deny on public.requirement_recruiter_assignments;
create policy xzrecruiter_data_api_deny on public.requirement_recruiter_assignments
  for all to anon,authenticated using (false) with check (false);

-- Requirement-specific sourcing provenance belongs to the candidacy/application, not the global candidate profile.
alter table public.applications add column if not exists source_type text;
alter table public.applications add column if not exists source_reference text;
alter table public.applications add column if not exists sourcing_notes text;
alter table public.applications add column if not exists sourced_by_user_id uuid references public.users(id) on delete set null;
alter table public.applications add column if not exists sourced_at timestamptz;
alter table public.applications add column if not exists intake_idempotency_key text;
alter table public.applications drop constraint if exists applications_source_type_check;
alter table public.applications add constraint applications_source_type_check
  check (source_type is null or source_type in (
    'LINKEDIN','MONSTER','DICE','INDEED','NAUKRI','INTERNAL_DATABASE',
    'REFERRAL','APPLICANT','CSV','OTHER'
  ));
create unique index if not exists uq_xzr_application_intake_idempotency
  on public.applications(agency_id,intake_idempotency_key)
  where intake_idempotency_key is not null;
create index if not exists idx_xzr_applications_recruiter_queue
  on public.applications(agency_id,owner_user_id,job_id,last_activity_at desc)
  where archived_at is null;

-- Extend the existing CRM task engine for narrowly-scoped recruitment execution work.
alter table public.crm_tasks add column if not exists task_type text;
alter table public.crm_tasks add column if not exists job_id uuid references public.recruitment_jobs(id) on delete cascade;
alter table public.crm_tasks add column if not exists candidate_id uuid references public.candidates(id) on delete cascade;
alter table public.crm_tasks add column if not exists application_id uuid references public.applications(id) on delete cascade;
alter table public.crm_tasks add column if not exists idempotency_key text;
alter table public.crm_tasks drop constraint if exists crm_tasks_task_type_check;
alter table public.crm_tasks add constraint crm_tasks_task_type_check
  check (task_type is null or task_type in (
    'CONTACT_CANDIDATE','FOLLOW_UP','COLLECT_RESUME','CONFIRM_AVAILABILITY',
    'SCREENING_DUE','MISSING_INFORMATION','MANAGER_CLARIFICATION'
  ));
alter table public.crm_tasks drop constraint if exists crm_task_parent_required;
alter table public.crm_tasks add constraint crm_task_parent_required check (
  client_id is not null or contact_id is not null or opportunity_id is not null or
  job_id is not null or candidate_id is not null or application_id is not null
);
create unique index if not exists uq_xzr_crm_task_idempotency
  on public.crm_tasks(agency_id,idempotency_key)
  where idempotency_key is not null;
create index if not exists idx_xzr_recruiter_tasks_due
  on public.crm_tasks(agency_id,assigned_user_id,status,due_at,priority)
  where archived_at is null;
create index if not exists idx_xzr_recruiter_tasks_job
  on public.crm_tasks(agency_id,job_id,status,due_at)
  where archived_at is null;

create or replace function private.xzrecruiter_can_manage_recruiter_assignment(p_business_role text)
returns boolean
language sql
immutable
security invoker
set search_path='public','private','pg_temp'
as $$
  select upper(coalesce(p_business_role,'')) in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER');
$$;
revoke all on function private.xzrecruiter_can_manage_recruiter_assignment(text) from public,anon,authenticated;

create or replace function private.xzrecruiter_recruiter_job_access(
  p_agency_id uuid,p_user_id uuid,p_business_role text,p_job_id uuid
) returns boolean
language sql
stable
security invoker
set search_path='public','private','pg_temp'
as $$
  select case
    when upper(coalesce(p_business_role,'')) in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER') then
      exists(
        select 1 from public.recruitment_jobs j
        where j.id=p_job_id and j.agency_id=p_agency_id and j.archived_at is null
      )
    when upper(coalesce(p_business_role,''))='RECRUITER' then
      exists(
        select 1
        from public.requirement_recruiter_assignments ra
        join public.recruitment_jobs j on j.id=ra.job_id and j.agency_id=p_agency_id
        where ra.agency_id=p_agency_id
          and ra.job_id=p_job_id
          and ra.recruiter_user_id=p_user_id
          and ra.assignment_status='ACTIVE'
          and j.archived_at is null
          and j.recruiter_ready=true
          and j.requirement_state='OPEN'
          and j.approved_hiring_brief_id is not null
      )
    else false
  end;
$$;
revoke all on function private.xzrecruiter_recruiter_job_access(uuid,uuid,text,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_workspace_day_bounds(
  p_agency_id uuid,
  out timezone_id text,
  out local_date date,
  out starts_at timestamptz,
  out ends_at timestamptz
) returns record
language plpgsql
stable
security invoker
set search_path='public','private','pg_temp'
as $fn$
begin
  select coalesce(s.timezone_id,'UTC')
  into timezone_id
  from public.workspace_global_settings s
  where s.agency_id=p_agency_id;
  timezone_id:=coalesce(timezone_id,'UTC');
  local_date:=(now() at time zone timezone_id)::date;
  starts_at:=local_date::timestamp at time zone timezone_id;
  ends_at:=(local_date+1)::timestamp at time zone timezone_id;
end;
$fn$;
revoke all on function private.xzrecruiter_workspace_day_bounds(uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_save_requirement_assignment(
  p_token text,p_job_id uuid,p_recruiter_user_id uuid,p_daily_target integer,p_total_target integer default 0,
  p_status text default 'ACTIVE',p_priority_context text default null,
  p_manager_instructions text default null,p_idempotency_key text default null,
  p_assignment_priority text default null,p_blocker_type text default null,
  p_blocker_reason text default null,p_blocker_owner_user_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_recruiter_role text;
  v_status text:=upper(coalesce(p_status,'ACTIVE'));v_priority text:=nullif(upper(btrim(coalesce(p_assignment_priority,''))),'');
  v_id uuid;v_existing uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_can_manage_recruiter_assignment(v_business_role) then
    return jsonb_build_object('ok',false,'error','assignment_manager_only');
  end if;
  if v_status not in ('ACTIVE','PAUSED','COMPLETED','REMOVED') then return jsonb_build_object('ok',false,'error','invalid_assignment_status'); end if;
  if coalesce(p_daily_target,0)<0 or coalesce(p_daily_target,0)>1000 then return jsonb_build_object('ok',false,'error','invalid_daily_target'); end if;
  if coalesce(p_total_target,0)<0 or coalesce(p_total_target,0)>10000 then return jsonb_build_object('ok',false,'error','invalid_total_target'); end if;
  if v_priority is not null and v_priority not in ('LOW','NORMAL','HIGH','URGENT') then return jsonb_build_object('ok',false,'error','invalid_assignment_priority'); end if;
  if p_blocker_owner_user_id is not null and not exists(
    select 1 from public.agency_memberships am
    where am.agency_id=v_agency and am.user_id=p_blocker_owner_user_id
  ) then return jsonb_build_object('ok',false,'error','invalid_blocker_owner'); end if;
  if not exists(
    select 1 from public.recruitment_jobs
    where id=p_job_id and agency_id=v_agency and archived_at is null
      and recruiter_ready=true and approved_hiring_brief_id is not null
  ) then return jsonb_build_object('ok',false,'error','approved_requirement_required'); end if;
  if not exists(
    select 1 from public.agency_memberships am
    where am.agency_id=v_agency and am.user_id=p_recruiter_user_id
  ) then return jsonb_build_object('ok',false,'error','recruiter_not_member'); end if;

  select private.xzrecruiter_business_role(v_agency,p_recruiter_user_id,am.role)
  into v_recruiter_role
  from public.agency_memberships am
  where am.agency_id=v_agency and am.user_id=p_recruiter_user_id
  limit 1;
  if v_recruiter_role<>'RECRUITER' then return jsonb_build_object('ok',false,'error','assignee_not_recruiter'); end if;

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is not null then
    select id into v_existing
    from public.requirement_recruiter_assignments
    where agency_id=v_agency and idempotency_key=p_idempotency_key
    limit 1;
    if v_existing is not null then return jsonb_build_object('ok',true,'id',v_existing,'reused',true); end if;
  end if;

  insert into public.requirement_recruiter_assignments(
    agency_id,job_id,recruiter_user_id,daily_target,total_submission_target,assignment_priority,
    blocker_type,blocker_reason,blocker_owner_user_id,assignment_status,priority_context,
    manager_instructions,assigned_by_user_id,idempotency_key
  ) values(
    v_agency,p_job_id,p_recruiter_user_id,coalesce(p_daily_target,0),coalesce(p_total_target,0),v_priority,
    nullif(left(btrim(coalesce(p_blocker_type,'')),120),''),
    nullif(left(btrim(coalesce(p_blocker_reason,'')),1500),''),
    p_blocker_owner_user_id,v_status,
    nullif(left(coalesce(p_priority_context,''),500),''),
    nullif(left(coalesce(p_manager_instructions,''),2000),''),
    v_user,nullif(left(coalesce(p_idempotency_key,''),160),'')
  )
  on conflict(agency_id,job_id,recruiter_user_id) do update
  set daily_target=excluded.daily_target,total_submission_target=excluded.total_submission_target,
      assignment_priority=excluded.assignment_priority,blocker_type=excluded.blocker_type,
      blocker_reason=excluded.blocker_reason,blocker_owner_user_id=excluded.blocker_owner_user_id,
      assignment_status=excluded.assignment_status,priority_context=excluded.priority_context,
      manager_instructions=excluded.manager_instructions,assigned_by_user_id=v_user,updated_at=now()
  returning id into v_id;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',p_job_id,'requirement.recruiter_assigned','Recruiter assignment saved',
    jsonb_build_object(
      'assignment_id',v_id,'recruiter_user_id',p_recruiter_user_id,'daily_target',coalesce(p_daily_target,0),
      'total_target',coalesce(p_total_target,0),'assignment_status',v_status,
      'assignment_priority',v_priority,'blocker_type',nullif(p_blocker_type,''),
      'blocker_reason',nullif(p_blocker_reason,''),'blocker_owner_user_id',p_blocker_owner_user_id,
      'actor_business_role',v_business_role
    )
  );
  return jsonb_build_object('ok',true,'id',v_id,'reused',false);
end;
$fn$;

create or replace function public.xzrecruiter_set_requirement_daily_target(
  p_token text,p_job_id uuid,p_daily_target integer,p_total_target integer default 0
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_before integer;v_before_total integer;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_can_manage_recruiter_assignment(v_business_role) then
    return jsonb_build_object('ok',false,'error','assignment_manager_only');
  end if;
  if coalesce(p_daily_target,0)<0 or coalesce(p_daily_target,0)>1000 then return jsonb_build_object('ok',false,'error','invalid_daily_target'); end if;
  if coalesce(p_total_target,0)<0 or coalesce(p_total_target,0)>10000 then return jsonb_build_object('ok',false,'error','invalid_total_target'); end if;
  select daily_submission_target,submission_target_total into v_before,v_before_total
  from public.recruitment_jobs
  where id=p_job_id and agency_id=v_agency and archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
  update public.recruitment_jobs
  set daily_submission_target=coalesce(p_daily_target,0),submission_target_total=coalesce(p_total_target,0),updated_at=now()
  where id=p_job_id and agency_id=v_agency;
  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',p_job_id,'requirement.target_updated','Daily submission target updated',
    jsonb_build_object(
      'daily_before',v_before,'daily_after',coalesce(p_daily_target,0),
      'total_before',v_before_total,'total_after',coalesce(p_total_target,0),
      'actor_business_role',v_business_role
    )
  );
  return jsonb_build_object('ok',true,'daily_target',coalesce(p_daily_target,0),'total_target',coalesce(p_total_target,0));
end;
$fn$;

create or replace function public.xzrecruiter_recruiter_home(
  p_token text,p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_timezone text;v_local_date date;
  v_start timestamptz;v_end timestamptz;v_limit integer:=greatest(1,least(coalesce(p_limit,50),100));
  v_requirements jsonb:='[]'::jsonb;v_tasks jsonb:='[]'::jsonb;v_interviews jsonb:='[]'::jsonb;
  v_target integer:=0;v_done integer:=0;v_due integer:=0;v_screening integer:=0;v_interview_actions integer:=0;v_attention integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','recruiter_workspace_forbidden');
  end if;
  select timezone_id,local_date,starts_at,ends_at
  into v_timezone,v_local_date,v_start,v_end
  from private.xzrecruiter_workspace_day_bounds(v_agency);

  with assigned as (
    select ra.*,j.title,j.client_id,j.priority,j.openings,j.target_fill_date,j.status,j.requirement_state,
      j.daily_submission_target,j.submission_target_total,j.opened_at,j.approved_hiring_brief_id,
      c.name account_name,
      hb.hiring_brief->>'roleSummary' brief_summary,
      coalesce(hb.hiring_brief->'mustHaveCriteria','[]'::jsonb) must_haves,
      coalesce((
        select count(distinct cs.application_id)
        from public.candidate_submissions cs
        join public.applications a on a.id=cs.application_id and a.agency_id=v_agency
        left join public.pipeline_stages psx on psx.id=a.stage_id and psx.agency_id=v_agency
        where cs.agency_id=v_agency and cs.job_id=j.id
          and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
          and cs.invalidated_at is null and cs.withdrawn_at is null
          and cs.submitted_at>=v_start and cs.submitted_at<v_end
          and cs.created_by_user_id=ra.recruiter_user_id
          and private.xzrecruiter_canonical_candidacy_state(coalesce(psx.code,a.stage)) not in ('WITHDRAWN','REJECTED')
      ),0)::integer valid_submissions_today,
      coalesce((
        select count(distinct cs.application_id)
        from public.candidate_submissions cs
        join public.applications a on a.id=cs.application_id and a.agency_id=v_agency
        left join public.pipeline_stages psx on psx.id=a.stage_id and psx.agency_id=v_agency
        where cs.agency_id=v_agency and cs.job_id=j.id
          and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
          and cs.invalidated_at is null and cs.withdrawn_at is null
          and cs.created_by_user_id=ra.recruiter_user_id
          and private.xzrecruiter_canonical_candidacy_state(coalesce(psx.code,a.stage)) not in ('WITHDRAWN','REJECTED')
      ),0)::integer valid_submissions_total,
      coalesce((
        select count(*)
        from public.applications ap
        where ap.agency_id=v_agency and ap.job_id=j.id and ap.owner_user_id=ra.recruiter_user_id and ap.archived_at is null
      ),0)::integer pipeline_candidates,
      coalesce((
        select count(*)
        from public.crm_tasks t
        where t.agency_id=v_agency and t.job_id=j.id and t.assigned_user_id=ra.recruiter_user_id
          and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS')
          and t.due_at is not null and t.due_at<now()
      ),0)::integer overdue_tasks,
      coalesce((
        select count(*)
        from public.crm_tasks t
        where t.agency_id=v_agency and t.job_id=j.id and t.assigned_user_id=ra.recruiter_user_id
          and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS')
          and t.due_at is not null and t.due_at<v_end
      ),0)::integer due_tasks_today,
      coalesce((
        select count(*)
        from public.applications a
        left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
        where a.agency_id=v_agency and a.job_id=j.id and a.owner_user_id=ra.recruiter_user_id
          and a.archived_at is null
          and private.xzrecruiter_canonical_candidacy_state(coalesce(ps.code,a.stage))='SCREENING'
      ),0)::integer screening_pending,
      coalesce((
        select count(*)
        from public.crm_tasks t
        where t.agency_id=v_agency and t.job_id=j.id and t.assigned_user_id=ra.recruiter_user_id
          and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS')
          and t.task_type in ('MISSING_INFORMATION','MANAGER_CLARIFICATION')
      ),0)::integer blocker_count,
      greatest(0,extract(epoch from (now()-coalesce(j.opened_at,j.created_at)))/3600)::integer age_hours
    from public.requirement_recruiter_assignments ra
    join public.recruitment_jobs j on j.id=ra.job_id and j.agency_id=v_agency and j.archived_at is null
    left join public.recruitment_clients c on c.id=j.client_id and c.agency_id=v_agency
    left join public.requirement_hiring_briefs hb on hb.id=j.approved_hiring_brief_id and hb.agency_id=v_agency and hb.brief_status='APPROVED'
    where ra.agency_id=v_agency
      and ra.assignment_status='ACTIVE'
      and j.approved_hiring_brief_id is not null
      and j.recruiter_ready=true
      and (
        v_business_role<>'RECRUITER'
        or ra.recruiter_user_id=v_user
      )
  ), scored as (
    select a.*,
      greatest(0,a.daily_target-a.valid_submissions_today)::integer remaining_target,
      greatest(0,a.total_submission_target-a.valid_submissions_total)::integer remaining_total_target,
      (
        greatest(0,a.daily_target-a.valid_submissions_today)*20
        + case coalesce(a.assignment_priority,a.priority,'NORMAL') when 'URGENT' then 32 when 'HIGH' then 24 when 'NORMAL' then 16 else 8 end
        + case
            when a.target_fill_date is null then 0
            when a.target_fill_date<v_local_date then 30
            when a.target_fill_date<=v_local_date+1 then 25
            when a.target_fill_date<=v_local_date+3 then 20
            when a.target_fill_date<=v_local_date+7 then 10
            else 0
          end
        + least(5,floor(a.age_hours/24.0))::integer
        + least(5,a.pipeline_candidates)
        - case when a.blocker_count>0 or nullif(btrim(coalesce(a.blocker_reason,'')),'') is not null or a.status='ON_HOLD' then 2 else 0 end
      )::integer priority_score
    from assigned a
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.priority_score desc,x.remaining_target desc,x.title asc),'[]'::jsonb),
         coalesce(sum(x.daily_target),0)::integer,
         coalesce(sum(x.valid_submissions_today),0)::integer,
         coalesce(sum(x.due_tasks_today),0)::integer,
         coalesce(sum(x.screening_pending),0)::integer,
         coalesce(sum(case when x.remaining_target>0 or x.due_tasks_today>0 or x.screening_pending>0 or x.blocker_count>0 or nullif(btrim(coalesce(x.blocker_reason,'')),'') is not null or x.status='ON_HOLD' then 1 else 0 end),0)::integer
  into v_requirements,v_target,v_done,v_due,v_screening,v_attention
  from (
    select id assignment_id,job_id,recruiter_user_id,title,account_name,account_name client_name,
      coalesce(assignment_priority,priority,'NORMAL') priority,openings,
      target_fill_date,target_fill_date deadline,status,status requirement_status,
      requirement_state,daily_submission_target requirement_daily_target,submission_target_total requirement_total_target,
      daily_target,total_submission_target total_target,
      valid_submissions_today,valid_submissions_total,remaining_target,remaining_total_target,
      overdue_tasks,due_tasks_today,screening_pending,
      (blocker_count + case when nullif(btrim(coalesce(blocker_reason,'')),'') is not null then 1 else 0 end)::integer blocker_count,
      age_hours,priority_score,
      priority_context,manager_instructions,blocker_type,blocker_reason,blocker_owner_user_id,
      brief_summary,must_haves,pipeline_candidates
    from scored
    order by priority_score desc,remaining_target desc,title asc
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_at asc nulls last,x.created_at desc),'[]'::jsonb)
  into v_tasks
  from (
    select t.id,t.job_id,t.candidate_id,t.application_id,t.task_type,t.title,t.description,t.status,t.priority,
      t.due_at,t.created_at,j.title job_title,c.full_name candidate_name,
      (t.due_at is not null and t.due_at<now() and t.status in ('OPEN','IN_PROGRESS')) overdue,
      (t.due_at is not null and t.due_at<v_end and t.status in ('OPEN','IN_PROGRESS')) due_today
    from public.crm_tasks t
    left join public.recruitment_jobs j on j.id=t.job_id and j.agency_id=v_agency
    left join public.candidates c on c.id=t.candidate_id and c.agency_id=v_agency
    where t.agency_id=v_agency and t.archived_at is null and t.status in ('OPEN','IN_PROGRESS')
      and t.assigned_user_id=case when v_business_role='RECRUITER' then v_user else t.assigned_user_id end
      and (
        v_business_role<>'RECRUITER'
        or exists(
          select 1 from public.requirement_recruiter_assignments ra
          where ra.agency_id=v_agency and ra.job_id=t.job_id and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
        )
      )
    order by t.due_at asc nulls last,t.created_at desc
    limit 30
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at asc),'[]'::jsonb),count(*)::integer
  into v_interviews,v_interview_actions
  from (
    select i.id,i.application_id,i.scheduled_at,i.timezone,i.status,j.id job_id,j.title job_title,c.full_name candidate_name
    from public.interviews i
    join public.applications a on a.id=i.application_id and a.agency_id=v_agency and a.archived_at is null
    join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
    join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency
    where i.agency_id=v_agency and i.status='SCHEDULED'
      and i.scheduled_at>=v_start and i.scheduled_at<v_end+interval '1 day'
      and (
        v_business_role<>'RECRUITER'
        or exists(
          select 1 from public.requirement_recruiter_assignments ra
          where ra.agency_id=v_agency and ra.job_id=j.id and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
        )
      )
    order by i.scheduled_at
    limit 20
  ) x;

  return jsonb_build_object(
    'ok',true,'business_role',v_business_role,'timezone',v_timezone,'business_date',v_local_date,
    'today',jsonb_build_object(
      'daily_target',v_target,'valid_submissions_completed',v_done,'remaining_target',greatest(0,v_target-v_done),
      'jobs_requiring_attention',v_attention,'due_followups',v_due,
      'screening_actions_due',v_screening,'interview_actions',coalesce(v_interview_actions,0)
    ),
    'requirements',v_requirements,'tasks',v_tasks,'interviews',v_interviews
  );
end;
$fn$;

create or replace function public.xzrecruiter_recruiter_requirement_context(
  p_token text,p_job_id uuid,p_queue_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_timezone text;v_local_date date;
  v_start timestamptz;v_end timestamptz;v_limit integer:=greatest(1,least(coalesce(p_queue_limit,50),100));
  v_job jsonb;v_brief jsonb;v_criteria jsonb;v_assignment jsonb;v_assignments jsonb;v_recruiters jsonb;v_action_owners jsonb;
  v_queue jsonb;v_tasks jsonb;v_blockers jsonb;v_valid integer:=0;v_valid_total integer:=0;v_target integer:=0;v_total_target integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  select timezone_id,local_date,starts_at,ends_at
  into v_timezone,v_local_date,v_start,v_end
  from private.xzrecruiter_workspace_day_bounds(v_agency);

  select jsonb_build_object(
    'id',j.id,'title',j.title,'client_id',j.client_id,'account_name',c.name,'status',j.status,'priority',j.priority,
    'openings',j.openings,'target_fill_date',j.target_fill_date,'location',j.location,'city',j.city,'region',j.region,
    'country_code',j.country_code,'timezone',j.timezone,'workplace_type',j.workplace_type,'employment_type',j.employment_type,
    'salary_min',j.salary_min,'salary_max',j.salary_max,'salary_currency',j.salary_currency,'salary_period',j.salary_period,
    'experience_min',j.experience_min,'experience_max',j.experience_max,'work_authorization_requirements',j.work_authorization_requirements,
    'requirement_state',j.requirement_state,'recruiter_ready',j.recruiter_ready,
    'daily_submission_target',j.daily_submission_target,'submission_target_daily',j.daily_submission_target,
    'submission_target_total',j.submission_target_total,
    'approved_hiring_brief_id',j.approved_hiring_brief_id
  )
  into v_job
  from public.recruitment_jobs j
  left join public.recruitment_clients c on c.id=j.client_id and c.agency_id=v_agency
  where j.id=p_job_id and j.agency_id=v_agency and j.archived_at is null;
  if v_job is null then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  select jsonb_build_object(
    'id',hb.id,'version_number',hb.version_number,'brief_status',hb.brief_status,
    'structured_data',hb.structured_data,'hiring_brief',hb.hiring_brief,
    'search_blueprint',hb.search_blueprint,'approved_at',hb.approved_at,'approval_note',hb.approval_note
  ) into v_brief
  from public.requirement_hiring_briefs hb
  where hb.id=(v_job->>'approved_hiring_brief_id')::uuid
    and hb.agency_id=v_agency and hb.job_id=p_job_id and hb.brief_status='APPROVED';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'kind',c.criterion_kind,'label',c.label,'field',c.field_key,'value',c.value_text,
    'confidence',c.confidence,'evidence',c.evidence,'status',c.extraction_status,
    'enforcement',c.enforcement,'amConfirmed',c.am_confirmed
  ) order by c.sort_order,c.created_at),'[]'::jsonb)
  into v_criteria
  from public.requirement_criteria c
  where c.agency_id=v_agency and c.brief_id=(v_job->>'approved_hiring_brief_id')::uuid;

  select to_jsonb(x) into v_assignment
  from (
    select ra.id,ra.daily_target,ra.total_submission_target,ra.total_submission_target total_target,ra.assignment_priority priority,
      ra.blocker_type,ra.blocker_reason,ra.blocker_owner_user_id,ra.assignment_status,ra.priority_context,ra.manager_instructions,
      ra.assigned_at,ra.recruiter_user_id,u.display_name recruiter_name
    from public.requirement_recruiter_assignments ra
    left join public.users u on u.id=ra.recruiter_user_id
    where ra.agency_id=v_agency and ra.job_id=p_job_id
      and ra.recruiter_user_id=case when v_business_role='RECRUITER' then v_user else ra.recruiter_user_id end
      and (v_business_role<>'RECRUITER' or ra.assignment_status='ACTIVE')
    order by ra.updated_at desc limit 1
  ) x;

  if private.xzrecruiter_can_manage_recruiter_assignment(v_business_role) then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.recruiter_name),'[]'::jsonb)
    into v_assignments
    from (
      select ra.id,ra.recruiter_user_id,u.display_name recruiter_name,ra.daily_target,
        ra.total_submission_target,ra.total_submission_target total_target,ra.assignment_priority priority,ra.blocker_type,ra.blocker_reason,
        ra.blocker_owner_user_id,ra.assignment_status,ra.priority_context,ra.manager_instructions,ra.assigned_at,ra.updated_at
      from public.requirement_recruiter_assignments ra
      left join public.users u on u.id=ra.recruiter_user_id
      where ra.agency_id=v_agency and ra.job_id=p_job_id
    ) x;

    select coalesce(jsonb_agg(to_jsonb(x) order by x.display_name),'[]'::jsonb)
    into v_recruiters
    from (
      select am.user_id,u.display_name,u.email
      from public.agency_memberships am
      join public.users u on u.id=am.user_id
      where am.agency_id=v_agency
        and private.xzrecruiter_business_role(v_agency,am.user_id,am.role)='RECRUITER'
    ) x;

    select coalesce(jsonb_agg(to_jsonb(x) order by x.display_name),'[]'::jsonb)
    into v_action_owners
    from (
      select am.user_id,u.display_name,u.email,
        private.xzrecruiter_business_role(v_agency,am.user_id,am.role) business_role
      from public.agency_memberships am
      join public.users u on u.id=am.user_id
      where am.agency_id=v_agency
        and private.xzrecruiter_business_role(v_agency,am.user_id,am.role)
          in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER','RECRUITER')
    ) x;
  else
    v_assignments:='[]'::jsonb;v_recruiters:='[]'::jsonb;v_action_owners:='[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.last_activity_at desc),'[]'::jsonb)
  into v_queue
  from (
    select a.id application_id,a.candidate_id,c.full_name,c.email,c.phone,c.current_title,c.current_company,
      a.source_type,a.source_reference,a.sourcing_notes,a.sourced_at,a.stage,a.status,a.last_activity_at,
      ps.code stage_code,
      private.xzrecruiter_canonical_candidacy_state(coalesce(ps.code,a.stage)) canonical_state,
      case
        when private.xzrecruiter_canonical_candidacy_state(coalesce(ps.code,a.stage)) in ('NEW','SOURCED') then 'NEW_WORK'
        when private.xzrecruiter_canonical_candidacy_state(coalesce(ps.code,a.stage))='SCREENING' then 'SCREENING_PENDING'
        when private.xzrecruiter_canonical_candidacy_state(coalesce(ps.code,a.stage))='QUALIFIED' then 'READY_FOR_NEXT_ACTION'
        when private.xzrecruiter_canonical_candidacy_state(coalesce(ps.code,a.stage)) in ('REJECTED','WITHDRAWN','CLIENT_SUBMITTED','INTERVIEW','OFFER','JOINED') then 'COMPLETED_NO_ACTION'
        else 'SOURCING'
      end queue_group,
      exists(
        select 1 from public.crm_tasks t
        where t.agency_id=v_agency and t.application_id=a.id and t.archived_at is null
          and t.status in ('OPEN','IN_PROGRESS') and t.task_type in ('MISSING_INFORMATION','MANAGER_CLARIFICATION')
      ) blocked
    from public.applications a
    join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency and c.archived_at is null
    left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
    where a.agency_id=v_agency and a.job_id=p_job_id and a.archived_at is null
      and (v_business_role<>'RECRUITER' or a.owner_user_id=v_user)
    order by a.last_activity_at desc
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_at asc nulls last,x.created_at desc),'[]'::jsonb)
  into v_tasks
  from (
    select t.id,t.task_type,t.title,t.description,t.status,t.priority,t.due_at,t.assigned_user_id,t.candidate_id,
      t.application_id,t.created_at,t.completed_at,c.full_name candidate_name,
      (t.due_at is not null and t.due_at<now() and t.status in ('OPEN','IN_PROGRESS')) overdue,
      (t.due_at is not null and t.due_at<v_end and t.status in ('OPEN','IN_PROGRESS')) due_today
    from public.crm_tasks t
    left join public.candidates c on c.id=t.candidate_id and c.agency_id=v_agency
    where t.agency_id=v_agency and t.job_id=p_job_id and t.archived_at is null
      and (v_business_role<>'RECRUITER' or t.assigned_user_id=v_user)
    order by t.due_at asc nulls last,t.created_at desc
    limit 50
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.owner,x.reason),'[]'::jsonb)
  into v_blockers
  from (
    select coalesce(u.display_name,'MANAGER')::text owner,ra.blocker_reason::text reason,
      coalesce(nullif(ra.blocker_type,''),'ASSIGNMENT_BLOCKER')::text blocker_type
    from public.requirement_recruiter_assignments ra
    left join public.users u on u.id=ra.blocker_owner_user_id
    where ra.agency_id=v_agency and ra.job_id=p_job_id and ra.assignment_status='ACTIVE'
      and nullif(btrim(coalesce(ra.blocker_reason,'')),'') is not null
      and (v_business_role<>'RECRUITER' or ra.recruiter_user_id=v_user)
    union all
    select 'ACCOUNT_MANAGER'::text owner,'Requirement is on hold'::text reason,'REQUIREMENT_ON_HOLD'::text blocker_type
    where (v_job->>'status')='ON_HOLD'
    union all
    select case when t.task_type='MANAGER_CLARIFICATION' then 'MANAGER' else 'RECRUITER' end owner,
      t.title reason,t.task_type blocker_type
    from public.crm_tasks t
    where t.agency_id=v_agency and t.job_id=p_job_id and t.archived_at is null
      and t.status in ('OPEN','IN_PROGRESS') and t.task_type in ('MISSING_INFORMATION','MANAGER_CLARIFICATION')
      and (v_business_role<>'RECRUITER' or t.assigned_user_id=v_user)
  ) x;

  if v_business_role='RECRUITER' then
    v_target:=coalesce((v_assignment->>'daily_target')::integer,0);
    v_total_target:=coalesce((v_assignment->>'total_submission_target')::integer,(v_assignment->>'total_target')::integer,0);
    select count(distinct cs.application_id)::integer into v_valid
    from public.candidate_submissions cs
    join public.applications a on a.id=cs.application_id and a.agency_id=v_agency
    left join public.pipeline_stages psx on psx.id=a.stage_id and psx.agency_id=v_agency
    where cs.agency_id=v_agency and cs.job_id=p_job_id
      and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
      and cs.invalidated_at is null and cs.withdrawn_at is null
      and cs.created_by_user_id=v_user
      and cs.submitted_at>=v_start and cs.submitted_at<v_end
      and private.xzrecruiter_canonical_candidacy_state(coalesce(psx.code,a.stage)) not in ('WITHDRAWN','REJECTED');
    select count(distinct cs.application_id)::integer into v_valid_total
    from public.candidate_submissions cs
    join public.applications a on a.id=cs.application_id and a.agency_id=v_agency
    left join public.pipeline_stages psx on psx.id=a.stage_id and psx.agency_id=v_agency
    where cs.agency_id=v_agency and cs.job_id=p_job_id
      and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
      and cs.invalidated_at is null and cs.withdrawn_at is null
      and cs.created_by_user_id=v_user
      and private.xzrecruiter_canonical_candidacy_state(coalesce(psx.code,a.stage)) not in ('WITHDRAWN','REJECTED');
  else
    v_target:=coalesce((v_job->>'daily_submission_target')::integer,0);
    v_total_target:=coalesce((v_job->>'submission_target_total')::integer,0);
    select count(distinct cs.application_id)::integer into v_valid
    from public.candidate_submissions cs
    join public.applications a on a.id=cs.application_id and a.agency_id=v_agency
    left join public.pipeline_stages psx on psx.id=a.stage_id and psx.agency_id=v_agency
    where cs.agency_id=v_agency and cs.job_id=p_job_id
      and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
      and cs.invalidated_at is null and cs.withdrawn_at is null
      and cs.submitted_at>=v_start and cs.submitted_at<v_end
      and private.xzrecruiter_canonical_candidacy_state(coalesce(psx.code,a.stage)) not in ('WITHDRAWN','REJECTED');
    select count(distinct cs.application_id)::integer into v_valid_total
    from public.candidate_submissions cs
    join public.applications a on a.id=cs.application_id and a.agency_id=v_agency
    left join public.pipeline_stages psx on psx.id=a.stage_id and psx.agency_id=v_agency
    where cs.agency_id=v_agency and cs.job_id=p_job_id
      and cs.workflow_status='CLIENT_SUBMITTED' and cs.status='SUBMITTED'
      and cs.invalidated_at is null and cs.withdrawn_at is null
      and private.xzrecruiter_canonical_candidacy_state(coalesce(psx.code,a.stage)) not in ('WITHDRAWN','REJECTED');
  end if;

  return jsonb_build_object(
    'ok',true,'business_role',v_business_role,'timezone',v_timezone,'business_date',v_local_date,
    'can_manage_assignments',private.xzrecruiter_can_manage_recruiter_assignment(v_business_role),
    'job',v_job,'brief',coalesce(v_brief,'{}'::jsonb),'criteria',coalesce(v_criteria,'[]'::jsonb),
    'assignment',coalesce(v_assignment,'{}'::jsonb),'assignments',coalesce(v_assignments,'[]'::jsonb),
    'eligible_recruiters',coalesce(v_recruiters,'[]'::jsonb),
    'eligible_action_owners',coalesce(v_action_owners,'[]'::jsonb),
    'execution',jsonb_build_object(
      'daily_target',v_target,'valid_submissions_today',coalesce(v_valid,0),
      'remaining_target',greatest(0,v_target-coalesce(v_valid,0)),
      'total_target',v_total_target,'valid_submissions_total',coalesce(v_valid_total,0),
      'remaining_total_target',greatest(0,v_total_target-coalesce(v_valid_total,0))
    ),
    'queue',coalesce(v_queue,'[]'::jsonb),'tasks',coalesce(v_tasks,'[]'::jsonb),
    'blockers',coalesce(v_blockers,'[]'::jsonb)
  );
end;
$fn$;

create or replace function public.xzrecruiter_recruiter_candidate_search(
  p_token text,p_job_id uuid,p_query text default '',p_limit integer default 20
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_q text:=lower(btrim(coalesce(p_query,'')));v_limit integer:=greatest(1,least(coalesce(p_limit,20),30));v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  if length(v_q)<2 then return jsonb_build_object('ok',true,'rows','[]'::jsonb); end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb)
  into v_rows
  from (
    select c.id,c.full_name,
      case when v_business_role<>'RECRUITER' or c.owner_user_id=v_user or exists(
        select 1 from public.applications ax
        join public.requirement_recruiter_assignments rax on rax.job_id=ax.job_id and rax.agency_id=v_agency
        where ax.agency_id=v_agency and ax.candidate_id=c.id and ax.archived_at is null
          and rax.recruiter_user_id=v_user and rax.assignment_status='ACTIVE'
      ) then c.email else null end email,
      case when v_business_role<>'RECRUITER' or c.owner_user_id=v_user or exists(
        select 1 from public.applications ax
        join public.requirement_recruiter_assignments rax on rax.job_id=ax.job_id and rax.agency_id=v_agency
        where ax.agency_id=v_agency and ax.candidate_id=c.id and ax.archived_at is null
          and rax.recruiter_user_id=v_user and rax.assignment_status='ACTIVE'
      ) then c.phone else null end phone,
      c.current_title,c.current_company,c.city,c.country_code,c.updated_at,
      exists(
        select 1 from public.applications a
        where a.agency_id=v_agency and a.candidate_id=c.id and a.job_id=p_job_id and a.archived_at is null
      ) already_on_requirement,
      (v_business_role<>'RECRUITER' or c.owner_user_id=v_user or exists(
        select 1 from public.applications ax
        join public.requirement_recruiter_assignments rax on rax.job_id=ax.job_id and rax.agency_id=v_agency
        where ax.agency_id=v_agency and ax.candidate_id=c.id and ax.archived_at is null
          and rax.recruiter_user_id=v_user and rax.assignment_status='ACTIVE'
      )) reusable_without_manager
    from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and (
        lower(coalesce(c.full_name,'')) like '%'||v_q||'%'
        or lower(coalesce(c.email,'')) like '%'||v_q||'%'
        or lower(coalesce(c.phone,'')) like '%'||v_q||'%'
        or lower(coalesce(c.current_title,'')) like '%'||v_q||'%'
        or lower(coalesce(c.current_company,'')) like '%'||v_q||'%'
      )
    order by c.updated_at desc
    limit v_limit
  ) x;
  return jsonb_build_object('ok',true,'rows',v_rows);
end;
$fn$;

create or replace function public.xzrecruiter_recruiter_intake_candidate(
  p_token text,p_job_id uuid,p_candidate jsonb,p_source_type text,p_source_reference text default null,
  p_sourcing_notes text default null,p_idempotency_key text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_source text:=upper(coalesce(p_source_type,''));
  v_candidate uuid;v_existing uuid;v_app uuid;v_name text;v_email text;v_phone text;v_pipeline uuid;v_stage uuid;v_stage_name text;v_client uuid;
  v_reused boolean:=false;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','recruiter_intake_forbidden');
  end if;
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  if not exists(
    select 1 from public.recruitment_jobs
    where id=p_job_id and agency_id=v_agency and archived_at is null
      and recruiter_ready=true and approved_hiring_brief_id is not null and status<>'CANCELLED'
  ) then return jsonb_build_object('ok',false,'error','approved_requirement_required'); end if;
  if v_source not in ('LINKEDIN','MONSTER','DICE','INDEED','NAUKRI','INTERNAL_DATABASE','REFERRAL','APPLICANT','CSV','OTHER') then
    return jsonb_build_object('ok',false,'error','invalid_source_type');
  end if;

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is not null then
    select a.id,a.candidate_id into v_app,v_candidate
    from public.applications a
    where a.agency_id=v_agency and a.intake_idempotency_key=p_idempotency_key
    limit 1;
    if v_app is not null then
      return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',true,'idempotent',true);
    end if;
  end if;

  if nullif(p_candidate->>'id','') is not null then
    v_candidate:=(p_candidate->>'id')::uuid;
    if not exists(
      select 1 from public.candidates c
      where c.id=v_candidate and c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
        and (
          v_business_role<>'RECRUITER'
          or c.owner_user_id=v_user
          or exists(
            select 1 from public.applications a
            join public.requirement_recruiter_assignments ra on ra.job_id=a.job_id and ra.agency_id=v_agency
            where a.agency_id=v_agency and a.candidate_id=c.id and a.archived_at is null
              and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
          )
        )
    ) then return jsonb_build_object('ok',false,'error','candidate_access_forbidden'); end if;
    v_reused:=true;
  else
    v_name:=btrim(coalesce(p_candidate->>'fullName',''));
    v_email:=nullif(lower(btrim(coalesce(p_candidate->>'email',''))),'');
    v_phone:=nullif(regexp_replace(coalesce(p_candidate->>'phone',''),'[^0-9+]','','g'),'');
    if v_name='' or (v_email is null and v_phone is null) then
      return jsonb_build_object('ok',false,'error','name_and_contact_required');
    end if;

    select c.id into v_existing
    from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and ((v_email is not null and lower(c.email)=v_email) or (v_phone is not null and c.phone=v_phone))
    order by c.updated_at desc limit 1;

    if v_existing is not null then
      if v_business_role='RECRUITER' and not exists(
        select 1 from public.candidates c
        where c.id=v_existing and c.agency_id=v_agency
          and (
            c.owner_user_id=v_user
            or exists(
              select 1 from public.applications a
              join public.requirement_recruiter_assignments ra on ra.job_id=a.job_id and ra.agency_id=v_agency
              where a.agency_id=v_agency and a.candidate_id=c.id and a.archived_at is null
                and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
            )
          )
      ) then return jsonb_build_object('ok',false,'error','duplicate_requires_manager'); end if;
      v_candidate:=v_existing;v_reused:=true;
    else
      v_candidate:=gen_random_uuid();
      insert into public.candidates(
        id,agency_id,full_name,email,phone,current_title,current_company,source,dedupe_key,
        created_by_user_id,owner_user_id,consent_status,updated_by_user_id
      ) values(
        v_candidate,v_agency,v_name,v_email,v_phone,nullif(p_candidate->>'currentTitle',''),
        nullif(p_candidate->>'currentCompany',''),v_source,
        encode(extensions.digest(lower(v_name)||'|'||coalesce(v_email,'')||'|'||coalesce(v_phone,''),'sha256'),'hex'),
        v_user,v_user,'UNKNOWN',v_user
      );
      perform private.xzrecruiter_log_activity(
        v_agency,v_user,'candidate',v_candidate,'candidate.sourced','Candidate sourced',
        jsonb_build_object('source_type',v_source,'source_reference',left(coalesce(p_source_reference,''),500),'job_id',p_job_id)
      );
    end if;
  end if;

  select a.id into v_app
  from public.applications a
  where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=v_candidate and a.archived_at is null
  limit 1;
  if v_app is not null then
    return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',true,'already_associated',true);
  end if;

  select pipeline_id,client_id into v_pipeline,v_client
  from public.recruitment_jobs
  where id=p_job_id and agency_id=v_agency and archived_at is null;
  if v_pipeline is null then
    select id into v_pipeline
    from public.recruitment_pipelines
    where agency_id=v_agency and pipeline_kind='RECRUITMENT' and is_default=true and active=true
    limit 1;
  end if;
  select id,name into v_stage,v_stage_name
  from public.pipeline_stages
  where agency_id=v_agency and pipeline_id=v_pipeline and code in ('SOURCED','APPLIED','NEW')
  order by case code when 'SOURCED' then 0 when 'APPLIED' then 1 else 2 end
  limit 1;

  v_app:=gen_random_uuid();
  insert into public.applications(
    id,agency_id,job_id,candidate_id,stage,status,match_evidence,owner_user_id,created_by_user_id,
    client_id,pipeline_id,stage_id,stage_entered_at,last_activity_at,source_type,source_reference,
    sourcing_notes,sourced_by_user_id,sourced_at,intake_idempotency_key
  ) values(
    v_app,v_agency,p_job_id,v_candidate,coalesce(v_stage_name,'Sourced'),'ACTIVE','{}'::jsonb,v_user,v_user,
    v_client,v_pipeline,v_stage,now(),now(),v_source,nullif(left(coalesce(p_source_reference,''),1000),''),
    nullif(left(coalesce(p_sourcing_notes,''),2000),''),v_user,now(),
    nullif(left(coalesce(p_idempotency_key,''),160),'')
  );
  insert into public.application_stage_history(
    agency_id,application_id,to_stage_id,to_stage,changed_by_user_id
  ) values(v_agency,v_app,v_stage,coalesce(v_stage_name,'Sourced'),v_user);

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_app,'candidate.associated_with_requirement','Sourced candidate associated with requirement',
    jsonb_build_object(
      'candidate_id',v_candidate,'job_id',p_job_id,'source_type',v_source,
      'source_reference',left(coalesce(p_source_reference,''),500),'candidate_reused',v_reused
    )
  );
  return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',v_reused,'already_associated',false);
exception
  when unique_violation then
    select a.id,a.candidate_id into v_app,v_candidate
    from public.applications a
    where a.agency_id=v_agency
      and (
        a.intake_idempotency_key=p_idempotency_key
        or (a.job_id=p_job_id and a.candidate_id=v_candidate and a.archived_at is null)
      )
    order by a.created_at desc limit 1;
    if v_app is not null then return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',true,'idempotent',true); end if;
    return jsonb_build_object('ok',false,'error','candidate_intake_conflict');
end;
$fn$;

create or replace function public.xzrecruiter_save_execution_task(
  p_token text,p_task jsonb
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_id uuid;v_job uuid;v_candidate uuid;v_app uuid;
  v_assignee uuid;v_type text;v_title text;v_status text;v_priority text;v_existing uuid;v_idem text;v_timezone text;v_due timestamptz;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','task_forbidden');
  end if;

  v_job:=nullif(p_task->>'jobId','')::uuid;
  v_candidate:=nullif(p_task->>'candidateId','')::uuid;
  v_app:=nullif(p_task->>'applicationId','')::uuid;
  v_assignee:=coalesce(nullif(p_task->>'assignedUserId','')::uuid,v_user);
  v_type:=upper(coalesce(p_task->>'taskType',''));
  v_title:=btrim(coalesce(p_task->>'title',''));
  v_status:=upper(coalesce(nullif(p_task->>'status',''),'OPEN'));
  v_priority:=upper(coalesce(nullif(p_task->>'priority',''),'NORMAL'));
  v_idem:=nullif(btrim(coalesce(p_task->>'idempotencyKey','')),'');
  if v_job is null then return jsonb_build_object('ok',false,'error','job_required'); end if;
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,v_job) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  if v_business_role='RECRUITER' and v_assignee<>v_user then return jsonb_build_object('ok',false,'error','recruiter_self_assignment_only'); end if;
  if v_type not in ('CONTACT_CANDIDATE','FOLLOW_UP','COLLECT_RESUME','CONFIRM_AVAILABILITY','SCREENING_DUE','MISSING_INFORMATION','MANAGER_CLARIFICATION') then
    return jsonb_build_object('ok',false,'error','invalid_task_type');
  end if;
  if v_title='' then return jsonb_build_object('ok',false,'error','title_required'); end if;
  if v_status not in ('OPEN','IN_PROGRESS') then return jsonb_build_object('ok',false,'error','invalid_new_task_status'); end if;
  if v_priority not in ('LOW','NORMAL','HIGH','URGENT') then return jsonb_build_object('ok',false,'error','invalid_task_priority'); end if;
  if not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_assignee) then
    return jsonb_build_object('ok',false,'error','invalid_assignee');
  end if;
  select coalesce(timezone_id,'UTC') into v_timezone
  from public.workspace_global_settings where agency_id=v_agency;
  v_timezone:=coalesce(v_timezone,'UTC');
  if nullif(p_task->>'dueLocal','') is not null then
    begin
      v_due:=(p_task->>'dueLocal')::timestamp at time zone v_timezone;
    exception when others then
      return jsonb_build_object('ok',false,'error','invalid_due_local');
    end;
  end if;
  if v_app is not null and not exists(
    select 1 from public.applications
    where id=v_app and agency_id=v_agency and job_id=v_job and archived_at is null
      and (v_business_role<>'RECRUITER' or owner_user_id=v_user)
  ) then return jsonb_build_object('ok',false,'error','application_access_forbidden'); end if;
  if v_candidate is not null and not exists(
    select 1 from public.candidates c
    where c.id=v_candidate and c.agency_id=v_agency and c.archived_at is null
      and (
        v_business_role<>'RECRUITER' or c.owner_user_id=v_user
        or exists(
          select 1 from public.applications a
          where a.agency_id=v_agency and a.candidate_id=c.id and a.job_id=v_job and a.owner_user_id=v_user and a.archived_at is null
        )
      )
  ) then return jsonb_build_object('ok',false,'error','candidate_access_forbidden'); end if;

  if v_idem is not null then
    select id into v_existing
    from public.crm_tasks
    where agency_id=v_agency and idempotency_key=v_idem
    limit 1;
    if v_existing is not null then return jsonb_build_object('ok',true,'id',v_existing,'reused',true); end if;
  end if;

  v_id:=gen_random_uuid();
  insert into public.crm_tasks(
    id,agency_id,title,description,status,priority,due_at,assigned_user_id,created_by_user_id,
    task_type,job_id,candidate_id,application_id,idempotency_key
  ) values(
    v_id,v_agency,left(v_title,500),nullif(left(coalesce(p_task->>'description',''),2000),''),
    v_status,v_priority,v_due,v_assignee,v_user,
    v_type,v_job,v_candidate,v_app,left(v_idem,160)
  );
  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'crm_task',v_id,'followup.created','Recruiter execution task created',
    jsonb_build_object('job_id',v_job,'candidate_id',v_candidate,'application_id',v_app,'task_type',v_type,'assigned_user_id',v_assignee)
  );
  return jsonb_build_object('ok',true,'id',v_id,'reused',false);
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','invalid_task_reference');
end;
$fn$;

create or replace function public.xzrecruiter_set_execution_task_status(
  p_token text,p_task_id uuid,p_status text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_current text;v_assignee uuid;v_job uuid;
  v_next text:=upper(coalesce(p_status,''));
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  select status,assigned_user_id,job_id into v_current,v_assignee,v_job
  from public.crm_tasks
  where id=p_task_id and agency_id=v_agency and archived_at is null;
  if v_current is null then return jsonb_build_object('ok',false,'error','task_not_found'); end if;
  if v_business_role='RECRUITER' and v_assignee<>v_user then return jsonb_build_object('ok',false,'error','task_access_forbidden'); end if;
  if v_business_role='RECRUITER' and not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,v_job) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','task_forbidden');
  end if;
  if v_current=v_next then return jsonb_build_object('ok',true,'status',v_current,'reused',true); end if;
  if not (
    (v_current='OPEN' and v_next in ('IN_PROGRESS','DONE','CANCELLED')) or
    (v_current='IN_PROGRESS' and v_next in ('OPEN','DONE','CANCELLED'))
  ) then return jsonb_build_object('ok',false,'error','invalid_task_transition','from_status',v_current,'to_status',v_next); end if;

  update public.crm_tasks
  set status=v_next,completed_at=case when v_next='DONE' then now() else null end,updated_at=now()
  where id=p_task_id and agency_id=v_agency;
  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'crm_task',p_task_id,'task.completed',
    case when v_next='DONE' then 'Recruiter task completed' else 'Recruiter task status changed' end,
    jsonb_build_object('before',v_current,'after',v_next,'job_id',v_job)
  );
  return jsonb_build_object('ok',true,'status',v_next,'reused',false);
end;
$fn$;

-- Explicit function privileges: SECURITY DEFINER endpoints are not left to implicit PUBLIC EXECUTE.
revoke all on function public.xzrecruiter_save_requirement_assignment(text,uuid,uuid,integer,integer,text,text,text,text,text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_set_requirement_daily_target(text,uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_recruiter_home(text,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_recruiter_requirement_context(text,uuid,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_recruiter_candidate_search(text,uuid,text,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_recruiter_intake_candidate(text,uuid,jsonb,text,text,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_execution_task(text,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_set_execution_task_status(text,uuid,text) from public,anon,authenticated;

grant execute on function public.xzrecruiter_save_requirement_assignment(text,uuid,uuid,integer,integer,text,text,text,text,text,text,text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_set_requirement_daily_target(text,uuid,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_recruiter_home(text,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_recruiter_requirement_context(text,uuid,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_recruiter_candidate_search(text,uuid,text,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_recruiter_intake_candidate(text,uuid,jsonb,text,text,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_execution_task(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_set_execution_task_status(text,uuid,text) to anon,authenticated;


create or replace function public.xzrecruiter_prepare_execution_resume(
  p_token text,p_job_id uuid,p_candidate_id uuid,p_filename text,p_mime_type text,p_size_bytes bigint,p_checksum text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_doc uuid;v_run uuid;v_version integer;v_path text;v_existing uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','resume_upload_forbidden');
  end if;
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  if not exists(
    select 1 from public.applications a
    where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=p_candidate_id and a.archived_at is null
      and (v_business_role<>'RECRUITER' or a.owner_user_id=v_user)
  ) then return jsonb_build_object('ok',false,'error','candidate_access_forbidden'); end if;
  if coalesce(p_size_bytes,0)<=0 or p_size_bytes>8388608 then return jsonb_build_object('ok',false,'error','invalid_file_size'); end if;
  if p_mime_type not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain') then
    return jsonb_build_object('ok',false,'error','unsupported_file_type');
  end if;

  select id into v_existing
  from public.candidate_documents
  where agency_id=v_agency and candidate_id=p_candidate_id and document_type='RESUME'
    and checksum=p_checksum and archived_at is null
  order by version_number desc limit 1;
  if v_existing is not null then
    select id into v_run from public.candidate_parse_runs
    where agency_id=v_agency and candidate_id=p_candidate_id and document_id=v_existing
    order by created_at desc limit 1;
    return jsonb_build_object('ok',true,'document_id',v_existing,'parse_run_id',v_run,'reused',true);
  end if;

  select coalesce(max(version_number),0)+1 into v_version
  from public.candidate_documents
  where agency_id=v_agency and candidate_id=p_candidate_id and document_type='RESUME';

  v_doc:=gen_random_uuid();
  v_run:=gen_random_uuid();
  v_path:='candidates/'||v_agency::text||'/'||p_candidate_id::text||'/resume/'||v_doc::text||'/'||
    regexp_replace(coalesce(nullif(p_filename,''),'resume'),'[^A-Za-z0-9._-]+','_','g');

  update public.candidate_documents
  set is_primary=false
  where agency_id=v_agency and candidate_id=p_candidate_id and document_type='RESUME' and is_primary=true;

  insert into public.candidate_documents(
    id,agency_id,candidate_id,document_type,version_number,filename,storage_path,mime_type,size_bytes,checksum,is_primary,uploaded_by_user_id
  ) values(
    v_doc,v_agency,p_candidate_id,'RESUME',v_version,coalesce(nullif(p_filename,''),'resume'),v_path,p_mime_type,p_size_bytes,p_checksum,true,v_user
  );
  insert into public.candidate_parse_runs(
    id,agency_id,candidate_id,document_id,provider,parser_version,status,review_state
  ) values(v_run,v_agency,p_candidate_id,v_doc,'LOCAL','step3-existing-parser','PENDING','NEEDS_REVIEW');

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'candidate',p_candidate_id,'candidate.resume_uploaded','Resume uploaded for sourced candidate',
    jsonb_build_object('job_id',p_job_id,'document_id',v_doc,'version',v_version)
  );
  return jsonb_build_object('ok',true,'document_id',v_doc,'parse_run_id',v_run,'version_number',v_version,'storage_path',v_path,'reused',false);
end;
$fn$;

create or replace function public.xzrecruiter_finalize_execution_resume(
  p_token text,p_job_id uuid,p_parse_run_id uuid,p_extracted_data jsonb,p_field_confidence jsonb,p_field_evidence jsonb,p_error text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_candidate uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','resume_upload_forbidden');
  end if;
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;

  select candidate_id into v_candidate
  from public.candidate_parse_runs
  where id=p_parse_run_id and agency_id=v_agency;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','parse_run_not_found'); end if;
  if not exists(
    select 1 from public.applications a
    where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=v_candidate and a.archived_at is null
      and (v_business_role<>'RECRUITER' or a.owner_user_id=v_user)
  ) then return jsonb_build_object('ok',false,'error','candidate_access_forbidden'); end if;

  update public.candidate_parse_runs
  set status=case when p_error is null then 'COMPLETED' else 'FAILED' end,
      extracted_data=case when p_error is null then coalesce(p_extracted_data,'{}'::jsonb) else extracted_data end,
      field_confidence=case when p_error is null then coalesce(p_field_confidence,'{}'::jsonb) else field_confidence end,
      field_evidence=case when p_error is null then coalesce(p_field_evidence,'{}'::jsonb) else field_evidence end,
      error_message=nullif(left(coalesce(p_error,''),500),''),
      updated_at=now()
  where id=p_parse_run_id and agency_id=v_agency;
  return jsonb_build_object('ok',true,'status',case when p_error is null then 'COMPLETED' else 'FAILED' end);
end;
$fn$;

revoke all on function public.xzrecruiter_prepare_execution_resume(text,uuid,uuid,text,text,bigint,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_finalize_execution_resume(text,uuid,uuid,jsonb,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_prepare_execution_resume(text,uuid,uuid,text,text,bigint,text) to anon,authenticated;
grant execute on function public.xzrecruiter_finalize_execution_resume(text,uuid,uuid,jsonb,jsonb,jsonb,text) to anon,authenticated;


-- Step-3 recruiter isolation hardening for legacy broad ATS RPCs.
-- Managers/admins retain legacy behavior; RECRUITER sessions are denied broad list/mutation
-- and are scoped for single assigned requirement/candidate reads.
do $do$
begin
  if to_regprocedure('public.xzrecruiter_ats_context(text,text,text,integer,integer)') is not null
     and to_regprocedure('public.xzrecruiter_ats_context_step3_legacy(text,text,text,integer,integer)') is null then
    execute 'alter function public.xzrecruiter_ats_context(text,text,text,integer,integer) rename to xzrecruiter_ats_context_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_candidate_search(text,text,jsonb,integer,integer)') is not null
     and to_regprocedure('public.xzrecruiter_candidate_search_step3_legacy(text,text,jsonb,integer,integer)') is null then
    execute 'alter function public.xzrecruiter_candidate_search(text,text,jsonb,integer,integer) rename to xzrecruiter_candidate_search_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_job_search(text,text,jsonb,integer,integer)') is not null
     and to_regprocedure('public.xzrecruiter_job_search_step3_legacy(text,text,jsonb,integer,integer)') is null then
    execute 'alter function public.xzrecruiter_job_search(text,text,jsonb,integer,integer) rename to xzrecruiter_job_search_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_candidate_profile_context(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_candidate_profile_context_step3_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_candidate_profile_context(text,uuid) rename to xzrecruiter_candidate_profile_context_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_job_profile_context(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_job_profile_context_step3_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_job_profile_context(text,uuid) rename to xzrecruiter_job_profile_context_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_candidate_document_access(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_candidate_document_access_step3_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_candidate_document_access(text,uuid) rename to xzrecruiter_candidate_document_access_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_candidate_closeout_context(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_candidate_closeout_context_step3_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_candidate_closeout_context(text,uuid) rename to xzrecruiter_candidate_closeout_context_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_save_candidate(text,jsonb)') is not null
     and to_regprocedure('public.xzrecruiter_save_candidate_step3_legacy(text,jsonb)') is null then
    execute 'alter function public.xzrecruiter_save_candidate(text,jsonb) rename to xzrecruiter_save_candidate_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_update_candidate_profile(text,uuid,jsonb)') is not null
     and to_regprocedure('public.xzrecruiter_update_candidate_profile_step3_legacy(text,uuid,jsonb)') is null then
    execute 'alter function public.xzrecruiter_update_candidate_profile(text,uuid,jsonb) rename to xzrecruiter_update_candidate_profile_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_archive_candidate(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_archive_candidate_step3_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_archive_candidate(text,uuid) rename to xzrecruiter_archive_candidate_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_save_job(text,jsonb)') is not null
     and to_regprocedure('public.xzrecruiter_save_job_step3_legacy(text,jsonb)') is null then
    execute 'alter function public.xzrecruiter_save_job(text,jsonb) rename to xzrecruiter_save_job_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_update_job_profile(text,uuid,jsonb)') is not null
     and to_regprocedure('public.xzrecruiter_update_job_profile_step3_legacy(text,uuid,jsonb)') is null then
    execute 'alter function public.xzrecruiter_update_job_profile(text,uuid,jsonb) rename to xzrecruiter_update_job_profile_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_prepare_candidate_document(text,uuid,text,text,bigint,text)') is not null
     and to_regprocedure('public.xzrecruiter_prepare_candidate_document_step3_legacy(text,uuid,text,text,bigint,text)') is null then
    execute 'alter function public.xzrecruiter_prepare_candidate_document(text,uuid,text,text,bigint,text) rename to xzrecruiter_prepare_candidate_document_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_finalize_candidate_parse(text,uuid,jsonb,jsonb,jsonb,text)') is not null
     and to_regprocedure('public.xzrecruiter_finalize_candidate_parse_step3_legacy(text,uuid,jsonb,jsonb,jsonb,text)') is null then
    execute 'alter function public.xzrecruiter_finalize_candidate_parse(text,uuid,jsonb,jsonb,jsonb,text) rename to xzrecruiter_finalize_candidate_parse_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_apply_candidate_parse(text,uuid,jsonb)') is not null
     and to_regprocedure('public.xzrecruiter_apply_candidate_parse_step3_legacy(text,uuid,jsonb)') is null then
    execute 'alter function public.xzrecruiter_apply_candidate_parse(text,uuid,jsonb) rename to xzrecruiter_apply_candidate_parse_step3_legacy';
  end if;
  if to_regprocedure('public.xzrecruiter_issue_candidate_portal_access(text,uuid)') is not null
     and to_regprocedure('public.xzrecruiter_issue_candidate_portal_access_step3_legacy(text,uuid)') is null then
    execute 'alter function public.xzrecruiter_issue_candidate_portal_access(text,uuid) rename to xzrecruiter_issue_candidate_portal_access_step3_legacy';
  end if;
end
$do$;

create or replace function private.xzrecruiter_step3_legacy_recruiter_guard(
  p_token text
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  return jsonb_build_object('ok',true,'agency_id',v_agency,'user_id',v_user,'business_role',v_business_role);
end;
$fn$;
revoke all on function private.xzrecruiter_step3_legacy_recruiter_guard(text) from public,anon,authenticated;

create or replace function public.xzrecruiter_ats_context(
  p_token text,p_module text,p_query text default '',p_limit integer default 50,p_offset integer default 0
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_ats_context_step3_legacy(p_token,p_module,p_query,p_limit,p_offset);
end;
$fn$;

create or replace function public.xzrecruiter_candidate_search(
  p_token text,p_query text default '',p_filters jsonb default '{}'::jsonb,p_limit integer default 50,p_offset integer default 0
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_candidate_search_step3_legacy(p_token,p_query,p_filters,p_limit,p_offset);
end;
$fn$;

create or replace function public.xzrecruiter_job_search(
  p_token text,p_query text default '',p_filters jsonb default '{}'::jsonb,p_limit integer default 50,p_offset integer default 0
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_job_search_step3_legacy(p_token,p_query,p_filters,p_limit,p_offset);
end;
$fn$;

create or replace function public.xzrecruiter_job_profile_context(
  p_token text,p_job_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_guard jsonb;v_agency uuid;v_user uuid;v_role text;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  v_agency:=(v_guard->>'agency_id')::uuid;v_user:=(v_guard->>'user_id')::uuid;v_role:=v_guard->>'business_role';
  if v_role='RECRUITER' and not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  return public.xzrecruiter_job_profile_context_step3_legacy(p_token,p_job_id);
end;
$fn$;

create or replace function public.xzrecruiter_candidate_profile_context(
  p_token text,p_candidate_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_guard jsonb;v_agency uuid;v_user uuid;v_role text;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  v_agency:=(v_guard->>'agency_id')::uuid;v_user:=(v_guard->>'user_id')::uuid;v_role:=v_guard->>'business_role';
  if v_role='RECRUITER' and not exists(
    select 1 from public.candidates c
    where c.id=p_candidate_id and c.agency_id=v_agency and c.archived_at is null
      and (
        c.owner_user_id=v_user
        or exists(
          select 1 from public.applications a
          join public.requirement_recruiter_assignments ra on ra.job_id=a.job_id and ra.agency_id=v_agency
          where a.agency_id=v_agency and a.candidate_id=c.id and a.archived_at is null
            and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
        )
      )
  ) then return jsonb_build_object('ok',false,'error','candidate_access_forbidden'); end if;
  return public.xzrecruiter_candidate_profile_context_step3_legacy(p_token,p_candidate_id);
end;
$fn$;

create or replace function public.xzrecruiter_candidate_document_access(
  p_token text,p_document_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_guard jsonb;v_agency uuid;v_user uuid;v_role text;v_candidate uuid;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  v_agency:=(v_guard->>'agency_id')::uuid;v_user:=(v_guard->>'user_id')::uuid;v_role:=v_guard->>'business_role';
  if v_role='RECRUITER' then
    select candidate_id into v_candidate from public.candidate_documents where id=p_document_id and agency_id=v_agency and archived_at is null;
    if v_candidate is null or not exists(
      select 1 from public.candidates c
      where c.id=v_candidate and c.agency_id=v_agency and (
        c.owner_user_id=v_user or exists(
          select 1 from public.applications a
          join public.requirement_recruiter_assignments ra on ra.job_id=a.job_id and ra.agency_id=v_agency
          where a.agency_id=v_agency and a.candidate_id=c.id and a.archived_at is null
            and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
        )
      )
    ) then return jsonb_build_object('ok',false,'error','candidate_document_access_forbidden'); end if;
  end if;
  return public.xzrecruiter_candidate_document_access_step3_legacy(p_token,p_document_id);
end;
$fn$;

create or replace function public.xzrecruiter_candidate_closeout_context(
  p_token text,p_candidate_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_profile jsonb;
begin
  v_profile:=public.xzrecruiter_candidate_profile_context(p_token,p_candidate_id);
  if coalesce(v_profile->>'ok','false')<>'true' then return v_profile; end if;
  return public.xzrecruiter_candidate_closeout_context_step3_legacy(p_token,p_candidate_id);
end;
$fn$;

create or replace function public.xzrecruiter_save_candidate(p_token text,p_candidate jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_save_candidate_step3_legacy(p_token,p_candidate);
end;$fn$;

create or replace function public.xzrecruiter_update_candidate_profile(p_token text,p_candidate_id uuid,p_profile jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_update_candidate_profile_step3_legacy(p_token,p_candidate_id,p_profile);
end;$fn$;

create or replace function public.xzrecruiter_archive_candidate(p_token text,p_candidate_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_archive_candidate_step3_legacy(p_token,p_candidate_id);
end;$fn$;

create or replace function public.xzrecruiter_save_job(p_token text,p_job jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','protected_requirement'); end if;
  return public.xzrecruiter_save_job_step3_legacy(p_token,p_job);
end;$fn$;

create or replace function public.xzrecruiter_update_job_profile(p_token text,p_job_id uuid,p_job jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','protected_requirement'); end if;
  return public.xzrecruiter_update_job_profile_step3_legacy(p_token,p_job_id,p_job);
end;$fn$;

create or replace function public.xzrecruiter_prepare_candidate_document(
  p_token text,p_candidate_id uuid,p_filename text,p_mime_type text,p_size_bytes bigint,p_checksum text
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_prepare_candidate_document_step3_legacy(p_token,p_candidate_id,p_filename,p_mime_type,p_size_bytes,p_checksum);
end;$fn$;

create or replace function public.xzrecruiter_finalize_candidate_parse(
  p_token text,p_parse_run_id uuid,p_extracted_data jsonb,p_field_confidence jsonb,p_field_evidence jsonb,p_error text default null
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_finalize_candidate_parse_step3_legacy(p_token,p_parse_run_id,p_extracted_data,p_field_confidence,p_field_evidence,p_error);
end;$fn$;

create or replace function public.xzrecruiter_apply_candidate_parse(
  p_token text,p_parse_run_id uuid,p_fields jsonb
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_apply_candidate_parse_step3_legacy(p_token,p_parse_run_id,p_fields);
end;$fn$;

create or replace function public.xzrecruiter_issue_candidate_portal_access(
  p_token text,p_candidate_id uuid
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_guard jsonb;
begin
  v_guard:=private.xzrecruiter_step3_legacy_recruiter_guard(p_token);
  if coalesce(v_guard->>'ok','false')<>'true' then return v_guard; end if;
  if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required'); end if;
  return public.xzrecruiter_issue_candidate_portal_access_step3_legacy(p_token,p_candidate_id);
end;$fn$;

-- Remove direct access to renamed implementations.
revoke all on function public.xzrecruiter_ats_context_step3_legacy(text,text,text,integer,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_candidate_search_step3_legacy(text,text,jsonb,integer,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_job_search_step3_legacy(text,text,jsonb,integer,integer) from public,anon,authenticated;
revoke all on function public.xzrecruiter_candidate_profile_context_step3_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_job_profile_context_step3_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_candidate_document_access_step3_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_candidate_closeout_context_step3_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_candidate_step3_legacy(text,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_update_candidate_profile_step3_legacy(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_archive_candidate_step3_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_job_step3_legacy(text,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_update_job_profile_step3_legacy(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_prepare_candidate_document_step3_legacy(text,uuid,text,text,bigint,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_finalize_candidate_parse_step3_legacy(text,uuid,jsonb,jsonb,jsonb,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_apply_candidate_parse_step3_legacy(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_issue_candidate_portal_access_step3_legacy(text,uuid) from public,anon,authenticated;

grant execute on function public.xzrecruiter_ats_context(text,text,text,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_search(text,text,jsonb,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_job_search(text,text,jsonb,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_profile_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_job_profile_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_document_access(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_closeout_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_save_candidate(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_update_candidate_profile(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_candidate(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_save_job(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_update_job_profile(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_prepare_candidate_document(text,uuid,text,text,bigint,text) to anon,authenticated;
grant execute on function public.xzrecruiter_finalize_candidate_parse(text,uuid,jsonb,jsonb,jsonb,text) to anon,authenticated;
grant execute on function public.xzrecruiter_apply_candidate_parse(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_issue_candidate_portal_access(text,uuid) to anon,authenticated;
