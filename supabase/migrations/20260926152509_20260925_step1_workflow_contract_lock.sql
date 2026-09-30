-- XZ Recruiter Step 1 (2026-09-25): canonical workflow/product contract lock.
-- Additive compatibility layer: preserves the existing ATS as background infrastructure
-- while enforcing Recruiter -> AM Quality Gate -> Client ownership.
-- This migration does NOT implement roadmap Steps 2-9.

-- 1) Canonical business-role vocabulary. Keep every valid legacy role and add Compliance Reviewer.
alter table public.workspace_member_profiles
  drop constraint if exists workspace_member_profiles_business_role_check;

alter table public.workspace_member_profiles
  add constraint workspace_member_profiles_business_role_check
  check (business_role in (
    'OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER','SOURCER',
    'BUSINESS_DEVELOPMENT','ACCOUNT_MANAGER','HIRING_MANAGER','INTERVIEWER',
    'VIEWER_ANALYST','COMPLIANCE_REVIEWER'
  ));

-- 2) Candidate submission remains one durable record, but internal recruiter handoff,
-- AM review, and actual client release are now explicit states.
alter table public.candidate_submissions
  add column if not exists workflow_status text not null default 'DRAFT',
  add column if not exists internal_submitted_at timestamptz,
  add column if not exists am_review_status text not null default 'NOT_REQUESTED',
  add column if not exists am_reviewed_by_user_id uuid references public.users(id) on delete set null,
  add column if not exists am_reviewed_at timestamptz,
  add column if not exists am_review_note text,
  add column if not exists client_submitted_at timestamptz;

-- Existing production records with legacy client-facing statuses remain client submissions.
update public.candidate_submissions
set workflow_status = case
  when status in ('SUBMITTED','CLIENT_VIEWED','FEEDBACK_REQUESTED','INTERVIEW_REQUESTED','ADVANCED')
    then 'CLIENT_SUBMITTED'
  else 'DRAFT'
end,
client_submitted_at = case
  when status in ('SUBMITTED','CLIENT_VIEWED','FEEDBACK_REQUESTED','INTERVIEW_REQUESTED','ADVANCED')
    then coalesce(client_submitted_at, submitted_at, updated_at, created_at)
  else client_submitted_at
end
where workflow_status = 'DRAFT'
  and status <> 'DRAFT';

alter table public.candidate_submissions
  drop constraint if exists candidate_submissions_workflow_status_check;
alter table public.candidate_submissions
  add constraint candidate_submissions_workflow_status_check
  check (workflow_status in (
    'DRAFT','INTERNAL_SUBMITTED','RETURNED_TO_RECRUITER',
    'AM_APPROVED','AM_REJECTED','CLIENT_SUBMITTED'
  ));

alter table public.candidate_submissions
  drop constraint if exists candidate_submissions_am_review_status_check;
alter table public.candidate_submissions
  add constraint candidate_submissions_am_review_status_check
  check (am_review_status in (
    'NOT_REQUESTED','PENDING','RETURNED_TO_RECRUITER','APPROVED','REJECTED'
  ));

create index if not exists idx_xzrecruiter_submission_workflow
  on public.candidate_submissions(agency_id, application_id, workflow_status, updated_at desc);

-- 3) Resolve the business role independently from coarse legacy RBAC.
create or replace function private.xzrecruiter_business_role(
  p_agency_id uuid,
  p_user_id uuid,
  p_membership_role text
) returns text
language sql
stable
security invoker
set search_path = 'public','pg_temp'
as $$
  select case
    when upper(coalesce(p_membership_role,'')) in ('OWNER','ADMIN')
      then upper(p_membership_role)
    else coalesce(
      (
        select upper(wmp.business_role)
        from public.workspace_member_profiles wmp
        where wmp.agency_id = p_agency_id
          and wmp.user_id = p_user_id
        limit 1
      ),
      case
        when upper(coalesce(p_membership_role,'')) in ('RECRUITER','MEMBER') then 'RECRUITER'
        when upper(coalesce(p_membership_role,'')) = 'VIEWER' then 'VIEWER_ANALYST'
        else 'VIEWER_ANALYST'
      end
    )
  end;
$$;
revoke all on function private.xzrecruiter_business_role(uuid,uuid,text) from public,anon,authenticated;

-- 4) Canonical stage aliases let the legacy board remain storage/history,
-- but stop it from becoming a second, freely configurable operating model.
create or replace function private.xzrecruiter_canonical_candidacy_state(p_stage_code text)
returns text
language sql
immutable
security invoker
set search_path = 'pg_temp'
as $$
  select case upper(coalesce(p_stage_code,''))
    when 'NEW' then 'SOURCED'
    when 'APPLIED' then 'SOURCED'
    when 'SCREENING' then 'SCREENING'
    when 'QUALIFIED' then 'QUALIFIED'
    when 'SHORTLISTED' then 'QUALIFIED'
    when 'SUBMITTED' then 'CLIENT_SUBMITTED'
    when 'INTERVIEW' then 'INTERVIEW'
    when 'OFFER' then 'OFFER'
    when 'PLACED' then 'JOINED'
    when 'HIRED' then 'JOINED'
    when 'REJECTED' then 'REJECTED'
    when 'WITHDRAWN' then 'WITHDRAWN'
    else null
  end;
$$;
revoke all on function private.xzrecruiter_canonical_candidacy_state(text) from public,anon,authenticated;

create or replace function private.xzrecruiter_candidacy_transition_allowed(
  p_from_state text,
  p_to_state text,
  p_business_role text
) returns boolean
language sql
immutable
security invoker
set search_path = 'pg_temp'
as $$
  select case
    when upper(coalesce(p_business_role,'')) in ('OWNER','ADMIN') then
      (p_from_state,p_to_state) in (
        ('SOURCED','SCREENING'),
        ('SCREENING','QUALIFIED'),('SCREENING','REJECTED'),('SCREENING','WITHDRAWN'),
        ('QUALIFIED','CLIENT_SUBMITTED'),('QUALIFIED','REJECTED'),('QUALIFIED','WITHDRAWN'),
        ('CLIENT_SUBMITTED','INTERVIEW'),('CLIENT_SUBMITTED','REJECTED'),('CLIENT_SUBMITTED','WITHDRAWN'),
        ('INTERVIEW','OFFER'),('INTERVIEW','REJECTED'),('INTERVIEW','WITHDRAWN'),
        ('OFFER','JOINED'),('OFFER','WITHDRAWN')
      )
    when upper(coalesce(p_business_role,'')) in ('RECRUITER','RECRUITMENT_MANAGER') then
      (p_from_state,p_to_state) in (
        ('SOURCED','SCREENING'),
        ('SCREENING','QUALIFIED'),('SCREENING','REJECTED'),('SCREENING','WITHDRAWN'),
        ('QUALIFIED','REJECTED'),('QUALIFIED','WITHDRAWN')
      )
    when upper(coalesce(p_business_role,'')) = 'ACCOUNT_MANAGER' then
      (p_from_state,p_to_state) in (
        ('QUALIFIED','CLIENT_SUBMITTED'),('QUALIFIED','REJECTED'),('QUALIFIED','WITHDRAWN'),
        ('CLIENT_SUBMITTED','INTERVIEW'),('CLIENT_SUBMITTED','REJECTED'),('CLIENT_SUBMITTED','WITHDRAWN'),
        ('INTERVIEW','OFFER'),('INTERVIEW','REJECTED'),('INTERVIEW','WITHDRAWN'),
        ('OFFER','JOINED'),('OFFER','WITHDRAWN')
      )
    else false
  end;
$$;
revoke all on function private.xzrecruiter_candidacy_transition_allowed(text,text,text) from public,anon,authenticated;

-- 5) Canonical guarded application movement.
-- The mature Step-4 function still performs evidence checks, history writes and audit logging.
create or replace function public.xzrecruiter_move_application_workflow(
  p_token text,
  p_application_id uuid,
  p_stage_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = 'public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;
  v_user uuid;
  v_membership_role text;
  v_business_role text;
  v_pipeline uuid;
  v_from_stage uuid;
  v_from_code text;
  v_to_code text;
  v_from_state text;
  v_to_state text;
  v_has_client_submission boolean := false;
begin
  select agency_id,user_id,role
  into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);

  if v_agency is null then
    return jsonb_build_object('ok',false,'error','unauthorized');
  end if;

  v_business_role := private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);

  select a.pipeline_id,a.stage_id,ps.code
  into v_pipeline,v_from_stage,v_from_code
  from public.applications a
  left join public.pipeline_stages ps
    on ps.id=a.stage_id and ps.agency_id=v_agency
  where a.id=p_application_id
    and a.agency_id=v_agency
    and a.archived_at is null;

  if not found then
    return jsonb_build_object('ok',false,'error','application_not_found');
  end if;

  select ps.code
  into v_to_code
  from public.pipeline_stages ps
  where ps.id=p_stage_id
    and ps.agency_id=v_agency
    and ps.pipeline_id=v_pipeline;

  if not found then
    return jsonb_build_object('ok',false,'error','invalid_stage');
  end if;

  v_from_state := private.xzrecruiter_canonical_candidacy_state(v_from_code);
  v_to_state := private.xzrecruiter_canonical_candidacy_state(v_to_code);

  if v_from_state is null or v_to_state is null then
    return jsonb_build_object(
      'ok',false,'error','noncanonical_stage',
      'from_stage',v_from_code,'to_stage',v_to_code
    );
  end if;

  if not private.xzrecruiter_candidacy_transition_allowed(v_from_state,v_to_state,v_business_role) then
    return jsonb_build_object(
      'ok',false,'error','invalid_workflow_transition',
      'from_state',v_from_state,'to_state',v_to_state,'business_role',v_business_role
    );
  end if;

  if v_to_state='CLIENT_SUBMITTED' then
    select exists(
      select 1
      from public.candidate_submissions cs
      where cs.agency_id=v_agency
        and cs.application_id=p_application_id
        and cs.workflow_status='CLIENT_SUBMITTED'
    ) into v_has_client_submission;

    if not v_has_client_submission then
      return jsonb_build_object('ok',false,'error','am_quality_gate_required');
    end if;
  end if;

  return public.xzrecruiter_move_application_stage(
    p_token,p_application_id,p_stage_id,p_reason
  );
end;
$fn$;

-- The old free-form movement endpoint is no longer a browser/API contract.
revoke execute on function public.xzrecruiter_move_application_stage(text,uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.xzrecruiter_move_application_workflow(text,uuid,uuid,text)
  to anon,authenticated;

-- 6) Recruiter submission now means internal handoff to Account Manager.
create or replace function public.xzrecruiter_save_candidate_submission(
  p_token text,
  p_application_id uuid,
  p_submission jsonb,
  p_submit boolean default false
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;
  v_user uuid;
  v_membership_role text;
  v_business_role text;
  v_candidate uuid;
  v_job uuid;
  v_client uuid;
  v_id uuid;
  v_workflow_status text;
  v_documents jsonb;
  v_primary uuid;
begin
  select agency_id,user_id,role
  into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);

  if v_agency is null then
    return jsonb_build_object('ok',false,'error','unauthorized');
  end if;

  v_business_role := private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','recruiter_only');
  end if;

  select candidate_id,job_id,client_id
  into v_candidate,v_job,v_client
  from public.applications
  where id=p_application_id
    and agency_id=v_agency
    and archived_at is null;

  if v_candidate is null then
    return jsonb_build_object('ok',false,'error','application_not_found');
  end if;

  v_documents:=coalesce(p_submission->'documentIds','[]'::jsonb);
  if jsonb_typeof(v_documents)<>'array' then
    return jsonb_build_object('ok',false,'error','invalid_document_ids');
  end if;

  if jsonb_array_length(v_documents)=0 then
    select id into v_primary
    from public.candidate_documents
    where agency_id=v_agency
      and candidate_id=v_candidate
      and document_type='RESUME'
      and archived_at is null
      and is_primary=true
    order by version_number desc
    limit 1;
    if v_primary is not null then v_documents:=jsonb_build_array(v_primary); end if;
  end if;

  if exists(
    select 1
    from jsonb_array_elements_text(v_documents) d
    where not exists(
      select 1
      from public.candidate_documents cd
      where cd.id=d.value::uuid
        and cd.agency_id=v_agency
        and cd.candidate_id=v_candidate
        and cd.archived_at is null
    )
  ) then
    return jsonb_build_object('ok',false,'error','invalid_submission_document');
  end if;

  select id,workflow_status
  into v_id,v_workflow_status
  from public.candidate_submissions
  where agency_id=v_agency
    and application_id=p_application_id
  order by created_at desc
  limit 1;

  if v_workflow_status='INTERNAL_SUBMITTED' then
    return jsonb_build_object('ok',false,'error','am_review_pending');
  end if;
  if v_workflow_status in ('AM_APPROVED','AM_REJECTED','CLIENT_SUBMITTED') then
    return jsonb_build_object(
      'ok',false,'error','invalid_workflow_transition','from_state',v_workflow_status
    );
  end if;

  if v_id is null then
    v_id:=gen_random_uuid();
    insert into public.candidate_submissions(
      id,agency_id,application_id,candidate_id,job_id,client_id,
      summary,salary_expectation,salary_currency,availability,notice_period_days,
      document_ids,status,workflow_status,am_review_status,created_by_user_id,
      internal_submitted_at
    ) values(
      v_id,v_agency,p_application_id,v_candidate,v_job,v_client,
      nullif(p_submission->>'summary',''),
      nullif(p_submission->>'salaryExpectation','')::numeric,
      nullif(upper(p_submission->>'salaryCurrency'),''),
      nullif(p_submission->>'availability',''),
      nullif(p_submission->>'noticePeriodDays','')::integer,
      v_documents,
      'DRAFT',
      case when p_submit then 'INTERNAL_SUBMITTED' else 'DRAFT' end,
      case when p_submit then 'PENDING' else 'NOT_REQUESTED' end,
      v_user,
      case when p_submit then now() else null end
    );
  else
    update public.candidate_submissions
    set summary=nullif(p_submission->>'summary',''),
        salary_expectation=nullif(p_submission->>'salaryExpectation','')::numeric,
        salary_currency=nullif(upper(p_submission->>'salaryCurrency'),''),
        availability=nullif(p_submission->>'availability',''),
        notice_period_days=nullif(p_submission->>'noticePeriodDays','')::integer,
        document_ids=v_documents,
        status='DRAFT',
        workflow_status=case when p_submit then 'INTERNAL_SUBMITTED' else workflow_status end,
        am_review_status=case when p_submit then 'PENDING' else am_review_status end,
        internal_submitted_at=case when p_submit then now() else internal_submitted_at end,
        am_reviewed_by_user_id=case when p_submit then null else am_reviewed_by_user_id end,
        am_reviewed_at=case when p_submit then null else am_reviewed_at end,
        am_review_note=case when p_submit then null else am_review_note end,
        updated_at=now()
    where id=v_id and agency_id=v_agency;
  end if;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',p_application_id,
    case when p_submit then 'submission.internal_submitted' else 'submission.draft_saved' end,
    case when p_submit then 'Candidate submitted internally for AM review' else 'Internal submission draft saved' end,
    jsonb_build_object(
      'submission_id',v_id,
      'document_count',jsonb_array_length(v_documents),
      'business_role',v_business_role
    )
  );

  return jsonb_build_object(
    'ok',true,
    'id',v_id,
    'status','DRAFT',
    'workflow_status',case when p_submit then 'INTERNAL_SUBMITTED' else coalesce(v_workflow_status,'DRAFT') end,
    'am_review_status',case when p_submit then 'PENDING' else 'NOT_REQUESTED' end,
    'document_ids',v_documents
  );
exception
  when invalid_text_representation then
    return jsonb_build_object('ok',false,'error','invalid_submission_document');
end;
$fn$;

grant execute on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean)
  to anon,authenticated;

-- 7) AM Quality Gate: review is distinct from actual client release.
create or replace function public.xzrecruiter_review_internal_submission(
  p_token text,
  p_submission_id uuid,
  p_action text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;
  v_user uuid;
  v_membership_role text;
  v_business_role text;
  v_application uuid;
  v_current text;
  v_action text:=upper(btrim(coalesce(p_action,'')));
  v_next text;
  v_review text;
begin
  select agency_id,user_id,role
  into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);

  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  v_business_role := private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then
    return jsonb_build_object('ok',false,'error','am_only');
  end if;

  select application_id,workflow_status
  into v_application,v_current
  from public.candidate_submissions
  where id=p_submission_id and agency_id=v_agency;

  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if v_current<>'INTERNAL_SUBMITTED' then
    return jsonb_build_object('ok',false,'error','invalid_workflow_transition','from_state',v_current);
  end if;

  if v_action='APPROVE' then
    v_next:='AM_APPROVED'; v_review:='APPROVED';
  elsif v_action='RETURN' then
    if btrim(coalesce(p_note,''))='' then
      return jsonb_build_object('ok',false,'error','review_reason_required');
    end if;
    v_next:='RETURNED_TO_RECRUITER'; v_review:='RETURNED_TO_RECRUITER';
  elsif v_action='REJECT' then
    if btrim(coalesce(p_note,''))='' then
      return jsonb_build_object('ok',false,'error','review_reason_required');
    end if;
    v_next:='AM_REJECTED'; v_review:='REJECTED';
  else
    return jsonb_build_object('ok',false,'error','invalid_review_action');
  end if;

  update public.candidate_submissions
  set workflow_status=v_next,
      am_review_status=v_review,
      am_reviewed_by_user_id=v_user,
      am_reviewed_at=now(),
      am_review_note=nullif(btrim(coalesce(p_note,'')),''),
      updated_at=now()
  where id=p_submission_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_application,
    case v_action
      when 'APPROVE' then 'submission.am_approved'
      when 'RETURN' then 'submission.am_returned'
      else 'submission.am_rejected'
    end,
    case v_action
      when 'APPROVE' then 'AM Quality Gate approved'
      when 'RETURN' then 'AM returned candidate to recruiter'
      else 'AM rejected internal submission'
    end,
    jsonb_build_object(
      'submission_id',p_submission_id,
      'note',nullif(btrim(coalesce(p_note,'')),''),
      'business_role',v_business_role
    )
  );

  return jsonb_build_object('ok',true,'workflow_status',v_next,'am_review_status',v_review);
end;
$fn$;

grant execute on function public.xzrecruiter_review_internal_submission(text,uuid,text,text)
  to anon,authenticated;

create or replace function public.xzrecruiter_mark_client_submitted(
  p_token text,
  p_submission_id uuid
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;
  v_user uuid;
  v_membership_role text;
  v_business_role text;
  v_application uuid;
  v_current text;
begin
  select agency_id,user_id,role
  into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);

  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  v_business_role := private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then
    return jsonb_build_object('ok',false,'error','am_only');
  end if;

  select application_id,workflow_status
  into v_application,v_current
  from public.candidate_submissions
  where id=p_submission_id and agency_id=v_agency;

  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if v_current<>'AM_APPROVED' then
    return jsonb_build_object(
      'ok',false,'error','submission_not_am_approved','workflow_status',v_current
    );
  end if;

  update public.candidate_submissions
  set workflow_status='CLIENT_SUBMITTED',
      status='SUBMITTED',
      submitted_at=coalesce(submitted_at,now()),
      client_submitted_at=coalesce(client_submitted_at,now()),
      updated_at=now()
  where id=p_submission_id and agency_id=v_agency;

  update public.applications
  set submitted_at=coalesce(submitted_at,now()),
      last_activity_at=now(),
      updated_at=now()
  where id=v_application and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_application,
    'submission.client_submitted',
    'AM released approved candidate to client',
    jsonb_build_object('submission_id',p_submission_id,'business_role',v_business_role)
  );

  return jsonb_build_object(
    'ok',true,'workflow_status','CLIENT_SUBMITTED','status','SUBMITTED'
  );
end;
$fn$;

grant execute on function public.xzrecruiter_mark_client_submitted(text,uuid)
  to anon,authenticated;

-- 8) Keep recruiter Application 360 on the same record chain and expose only contract state.
create or replace function public.xzrecruiter_application_closeout_context(
  p_token text,
  p_application_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;
  v_user uuid;
  v_membership_role text;
  v_business_role text;
  v_candidate uuid;
  v_job uuid;
  v_application jsonb;
  v_screening jsonb;
  v_submission jsonb;
  v_activity jsonb;
begin
  select agency_id,user_id,role
  into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);

  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role := private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);

  select a.candidate_id,a.job_id,
    jsonb_build_object(
      'id',a.id,'stage',a.stage,'stage_id',a.stage_id,'status',a.status,
      'candidate_id',a.candidate_id,'job_id',a.job_id,'client_id',a.client_id,
      'candidate_name',c.full_name,'candidate_title',c.current_title,
      'candidate_email',c.email,'candidate_phone',c.phone,
      'availability',c.availability_status,'notice_period_days',c.notice_period_days,
      'salary_expected',c.salary_expected,'salary_currency',c.salary_currency,
      'job_title',j.title,'job_currency',j.salary_currency,
      'job_salary_min',j.salary_min,'job_salary_max',j.salary_max
    )
  into v_candidate,v_job,v_application
  from public.applications a
  join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency
  join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
  where a.id=p_application_id and a.agency_id=v_agency and a.archived_at is null;

  if v_candidate is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb)
  into v_screening
  from (
    select id,question_key,question_text,answer,score,knockout,reviewed_at,created_at
    from public.application_screening_answers
    where agency_id=v_agency and application_id=p_application_id
    order by created_at
  ) x;

  select to_jsonb(x)
  into v_submission
  from (
    select id,summary,salary_expectation,salary_currency,availability,notice_period_days,
      document_ids,status,workflow_status,internal_submitted_at,
      am_review_status,am_reviewed_by_user_id,am_reviewed_at,am_review_note,
      submitted_at,client_submitted_at,client_viewed_at,created_at,updated_at
    from public.candidate_submissions
    where agency_id=v_agency and application_id=p_application_id
    order by created_at desc
    limit 1
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb)
  into v_activity
  from (
    select id,entity_type,entity_id,action,summary,metadata,actor_user_id,occurred_at
    from public.recruitment_activity_events
    where agency_id=v_agency and (
      (entity_type='application' and entity_id=p_application_id) or
      (entity_type='candidate' and entity_id=v_candidate) or
      (entity_type='job' and entity_id=v_job)
    )
    order by occurred_at desc
    limit 60
  ) x;

  return jsonb_build_object(
    'ok',true,
    'application',v_application,
    'screening',v_screening,
    'submission',v_submission,
    'activity',v_activity,
    'business_role',v_business_role
  );
end;
$fn$;

grant execute on function public.xzrecruiter_application_closeout_context(text,uuid)
  to anon,authenticated;

-- Explicitly preserve direct-browser deny for tenant data.
alter table public.candidate_submissions enable row level security;


-- 9) Downstream ownership guardrails: preserve existing operations but prevent recruiter/AM role collapse.
create or replace function public.xzrecruiter_schedule_interview(p_token text,p_interview jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_id uuid;v_app uuid;v_start timestamptz;v_end timestamptz;v_tz text;v_stage_code text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER') then
    return jsonb_build_object('ok',false,'error','interview_role_forbidden');
  end if;

  v_app:=nullif(p_interview->>'applicationId','')::uuid;
  select ps.code into v_stage_code
  from public.applications a
  left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
  where a.id=v_app and a.agency_id=v_agency and a.archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  if upper(coalesce(v_stage_code,'')) not in ('SUBMITTED','INTERVIEW') then
    return jsonb_build_object('ok',false,'error','invalid_workflow_transition','required_state','CLIENT_SUBMITTED');
  end if;
  if not exists(
    select 1 from public.candidate_submissions cs
    where cs.agency_id=v_agency and cs.application_id=v_app and cs.workflow_status='CLIENT_SUBMITTED'
  ) then
    return jsonb_build_object('ok',false,'error','am_quality_gate_required');
  end if;

  v_start:=(p_interview->>'scheduledAt')::timestamptz;
  v_end:=coalesce(nullif(p_interview->>'endAt','')::timestamptz,v_start+interval '1 hour');
  if v_end<=v_start then return jsonb_build_object('ok',false,'error','invalid_time_range'); end if;
  v_tz:=coalesce(nullif(p_interview->>'timezone',''),'UTC');
  if not public.xzrecruiter_valid_timezone(v_tz) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;

  v_id:=gen_random_uuid();
  insert into public.interviews(
    id,agency_id,application_id,interview_type,scheduled_at,timezone,location_or_link,status,
    created_by_user_id,end_at,candidate_timezone,recruiter_timezone,meeting_url,instructions,
    interviewers,scorecard_template_id
  ) values(
    v_id,v_agency,v_app,coalesce(nullif(p_interview->>'interviewType',''),'CUSTOM'),
    v_start,v_tz,nullif(p_interview->>'locationOrLink',''),'SCHEDULED',
    v_user,v_end,nullif(p_interview->>'candidateTimezone',''),
    nullif(p_interview->>'recruiterTimezone',''),nullif(p_interview->>'meetingUrl',''),
    nullif(p_interview->>'instructions',''),coalesce(p_interview->'interviewers','[]'::jsonb),
    nullif(p_interview->>'scorecardTemplateId','')::uuid
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'interview',v_id,'interview.scheduled','Interview scheduled',
    jsonb_build_object('application_id',v_app,'timezone',v_tz,'business_role',v_business_role)
  );
  return jsonb_build_object('ok',true,'id',v_id);
end;
$fn$;

create or replace function public.xzrecruiter_save_offer(p_token text,p_offer jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_id uuid;v_app uuid;v_parent uuid;v_version integer:=1;v_stage_code text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then
    return jsonb_build_object('ok',false,'error','offer_role_forbidden');
  end if;

  v_app:=nullif(p_offer->>'applicationId','')::uuid;
  select ps.code into v_stage_code
  from public.applications a
  left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
  where a.id=v_app and a.agency_id=v_agency and a.archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  if upper(coalesce(v_stage_code,'')) not in ('INTERVIEW','OFFER') then
    return jsonb_build_object('ok',false,'error','invalid_workflow_transition','required_state','INTERVIEW');
  end if;

  v_parent:=nullif(p_offer->>'parentOfferId','')::uuid;
  if v_parent is not null then
    if not exists(select 1 from public.offers where id=v_parent and agency_id=v_agency and application_id=v_app) then
      return jsonb_build_object('ok',false,'error','parent_offer_not_found');
    end if;
    select max(version_number)+1 into v_version
    from public.offers
    where agency_id=v_agency and application_id=v_app and (id=v_parent or parent_offer_id=v_parent);
    v_version:=coalesce(v_version,2);
  end if;

  v_id:=gen_random_uuid();
  insert into public.offers(
    id,agency_id,application_id,amount,currency,status,start_date,note,created_by_user_id,
    title,location,salary_period,bonus,commission,ote,equity,allowances,expires_at,
    employment_type,version_number,parent_offer_id
  ) values(
    v_id,v_agency,v_app,nullif(p_offer->>'amount','')::numeric,
    nullif(upper(p_offer->>'currency'),''),'DRAFT',nullif(p_offer->>'startDate','')::date,
    nullif(p_offer->>'note',''),v_user,nullif(p_offer->>'title',''),
    nullif(p_offer->>'location',''),nullif(p_offer->>'salaryPeriod',''),
    nullif(p_offer->>'bonus','')::numeric,nullif(p_offer->>'commission','')::numeric,
    nullif(p_offer->>'ote','')::numeric,nullif(p_offer->>'equity',''),
    coalesce(p_offer->'allowances','[]'::jsonb),nullif(p_offer->>'expiresAt','')::timestamptz,
    nullif(p_offer->>'employmentType',''),v_version,v_parent
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'offer',v_id,'offer.created','Offer version created',
    jsonb_build_object('application_id',v_app,'version',v_version,'business_role',v_business_role)
  );
  return jsonb_build_object('ok',true,'id',v_id,'version',v_version);
end;
$fn$;

create or replace function public.xzrecruiter_offer_approval_action(
  p_token text,p_offer_id uuid,p_action text,p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_action text:=upper(coalesce(p_action,''));v_status text;v_approval uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);

  select status into v_status from public.offers where id=p_offer_id and agency_id=v_agency;
  if v_status is null then return jsonb_build_object('ok',false,'error','offer_not_found'); end if;

  if v_action='REQUEST' then
    if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then
      return jsonb_build_object('ok',false,'error','offer_role_forbidden');
    end if;
    if v_status not in ('DRAFT','PENDING_APPROVAL') then
      return jsonb_build_object('ok',false,'error','invalid_offer_state');
    end if;
    select id into v_approval
    from public.offer_approvals
    where agency_id=v_agency and offer_id=p_offer_id and step_order=1;
    if v_approval is null then
      v_approval:=gen_random_uuid();
      insert into public.offer_approvals(id,agency_id,offer_id,step_order,required_role,status)
      values(v_approval,v_agency,p_offer_id,1,'ADMIN','PENDING');
    else
      update public.offer_approvals
      set status='PENDING',decision_note=null,decided_at=null
      where id=v_approval and agency_id=v_agency;
    end if;
    update public.offers set status='PENDING_APPROVAL' where id=p_offer_id and agency_id=v_agency;
  elsif v_action in ('APPROVE','REJECT') then
    if v_business_role not in ('OWNER','ADMIN') then
      return jsonb_build_object('ok',false,'error','approval_forbidden');
    end if;
    select id into v_approval
    from public.offer_approvals
    where agency_id=v_agency and offer_id=p_offer_id and status='PENDING'
    order by step_order limit 1;
    if v_approval is null then return jsonb_build_object('ok',false,'error','approval_not_pending'); end if;
    update public.offer_approvals
    set status=case when v_action='APPROVE' then 'APPROVED' else 'REJECTED' end,
        approver_user_id=v_user,decision_note=nullif(btrim(coalesce(p_note,'')),''),
        decided_at=now()
    where id=v_approval and agency_id=v_agency;
    update public.offers
    set status=case when v_action='APPROVE' then 'APPROVED' else 'DRAFT' end,
        metadata=coalesce(metadata,'{}'::jsonb)||
          jsonb_build_object('last_approval_action',v_action,'last_approval_note',p_note)
    where id=p_offer_id and agency_id=v_agency;
  else
    return jsonb_build_object('ok',false,'error','invalid_approval_action');
  end if;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'offer',p_offer_id,'offer.approval_'||lower(v_action),
    'Offer approval action',jsonb_build_object('action',v_action,'note',p_note,'business_role',v_business_role)
  );
  return jsonb_build_object('ok',true,'action',v_action);
end;
$fn$;

create or replace function public.xzrecruiter_offer_set_status(
  p_token text,p_offer_id uuid,p_status text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_current text;v_new text:=upper(coalesce(p_status,''));
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then
    return jsonb_build_object('ok',false,'error','offer_role_forbidden');
  end if;

  if v_new not in ('SENT','VIEWED','ACCEPTED','DECLINED','EXPIRED','WITHDRAWN') then
    return jsonb_build_object('ok',false,'error','invalid_status');
  end if;
  select status into v_current from public.offers where id=p_offer_id and agency_id=v_agency;
  if v_current is null then return jsonb_build_object('ok',false,'error','offer_not_found'); end if;

  if not (
    (v_current='APPROVED' and v_new='SENT') or
    (v_current='SENT' and v_new in ('VIEWED','ACCEPTED','DECLINED','EXPIRED','WITHDRAWN')) or
    (v_current='VIEWED' and v_new in ('ACCEPTED','DECLINED','EXPIRED','WITHDRAWN'))
  ) then
    return jsonb_build_object(
      'ok',false,'error','invalid_workflow_transition',
      'from_state',v_current,'to_state',v_new
    );
  end if;

  update public.offers
  set status=v_new,
      sent_at=case when v_new='SENT' then coalesce(sent_at,now()) else sent_at end,
      viewed_at=case when v_new='VIEWED' then coalesce(viewed_at,now()) else viewed_at end,
      accepted_at=case when v_new='ACCEPTED' then coalesce(accepted_at,now()) else accepted_at end,
      declined_at=case when v_new='DECLINED' then coalesce(declined_at,now()) else declined_at end,
      withdrawn_at=case when v_new='WITHDRAWN' then coalesce(withdrawn_at,now()) else withdrawn_at end
  where id=p_offer_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'offer',p_offer_id,'offer.status_changed',v_current||' → '||v_new,
    jsonb_build_object('business_role',v_business_role)
  );
  return jsonb_build_object('ok',true,'status',v_new);
end;
$fn$;

create or replace function public.xzrecruiter_create_placement(p_token text,p_placement jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_id uuid;v_app uuid;v_candidate uuid;v_job uuid;v_client uuid;v_offer uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER') then
    return jsonb_build_object('ok',false,'error','joining_role_forbidden');
  end if;

  v_app:=nullif(p_placement->>'applicationId','')::uuid;
  select candidate_id,job_id,client_id into v_candidate,v_job,v_client
  from public.applications
  where id=v_app and agency_id=v_agency and archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;

  begin v_offer:=nullif(p_placement->>'offerId','')::uuid; exception when invalid_text_representation then v_offer:=null; end;
  if v_offer is null then
    select id into v_offer
    from public.offers
    where agency_id=v_agency and application_id=v_app and status='ACCEPTED'
    order by accepted_at desc nulls last,created_at desc limit 1;
  end if;
  if v_offer is null or not exists(
    select 1 from public.offers
    where id=v_offer and agency_id=v_agency and application_id=v_app and status='ACCEPTED'
  ) then
    return jsonb_build_object('ok',false,'error','accepted_offer_required');
  end if;

  if exists(
    select 1 from public.placements
    where agency_id=v_agency and application_id=v_app and status not in ('CANCELLED')
  ) then
    return jsonb_build_object('ok',false,'error','placement_exists');
  end if;

  v_id:=gen_random_uuid();
  insert into public.placements(
    id,agency_id,application_id,offer_id,placement_fee,fee_currency,start_date,
    created_by_user_id,candidate_id,job_id,client_id,recruiter_user_id,salary,
    salary_currency,status,fee_type,fee_percent,guarantee_end_date,commission_amount
  ) values(
    v_id,v_agency,v_app,v_offer,nullif(p_placement->>'placementFee','')::numeric,
    nullif(upper(p_placement->>'feeCurrency'),''),nullif(p_placement->>'startDate','')::date,
    v_user,v_candidate,v_job,v_client,v_user,nullif(p_placement->>'salary','')::numeric,
    nullif(upper(p_placement->>'salaryCurrency'),''),'PLANNED',
    nullif(p_placement->>'feeType',''),nullif(p_placement->>'feePercent','')::numeric,
    nullif(p_placement->>'guaranteeEndDate','')::date,
    nullif(p_placement->>'commissionAmount','')::numeric
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'placement',v_id,'joining.started','Pre-joining record created',
    jsonb_build_object('application_id',v_app,'offer_id',v_offer,'business_role',v_business_role)
  );
  return jsonb_build_object('ok',true,'id',v_id);
end;
$fn$;

-- Security-definer RPCs are explicit API endpoints; remove implicit PUBLIC execute first.
revoke all on function public.xzrecruiter_move_application_workflow(text,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.xzrecruiter_review_internal_submission(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_mark_client_submitted(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_application_closeout_context(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_schedule_interview(text,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_offer(text,jsonb) from public,anon,authenticated;
revoke all on function public.xzrecruiter_offer_approval_action(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_offer_set_status(text,uuid,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_create_placement(text,jsonb) from public,anon,authenticated;

grant execute on function public.xzrecruiter_move_application_workflow(text,uuid,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) to anon,authenticated;
grant execute on function public.xzrecruiter_review_internal_submission(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_mark_client_submitted(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_application_closeout_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_schedule_interview(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_offer(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_offer_approval_action(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_offer_set_status(text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_create_placement(text,jsonb) to anon,authenticated;
