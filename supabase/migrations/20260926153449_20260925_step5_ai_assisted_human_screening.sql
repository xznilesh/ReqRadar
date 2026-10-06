-- XZ Recruiter locked roadmap Step 5: AI-Assisted Human Screening.
-- Additive to Steps 1-4. Does not implement Step 6 client submission or AM quality gate.

create table if not exists public.application_screening_sessions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  previous_session_id uuid references public.application_screening_sessions(id) on delete set null,
  status text not null default 'SCREENING_PENDING' check (status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED','QUALIFIED','NOT_QUALIFIED','CANDIDATE_NOT_INTERESTED','NO_RESPONSE','ON_HOLD','WITHDRAWN')),
  outcome text check (outcome is null or outcome in ('QUALIFIED','NOT_QUALIFIED','CANDIDATE_NOT_INTERESTED','NO_RESPONSE','ON_HOLD','WITHDRAWN','FOLLOW_UP_REQUIRED')),
  candidate_interest text not null default 'UNKNOWN' check (candidate_interest in ('INTERESTED','NOT_INTERESTED','UNSURE','UNKNOWN')),
  screening_brief jsonb not null default '{}'::jsonb,
  brief_version integer not null default 1,
  brief_model text not null default 'GROUNDED_SCREENING_V1',
  candidate_snapshot jsonb not null default '{}'::jsonb,
  requirement_snapshot jsonb not null default '{}'::jsonb,
  intelligence_snapshot jsonb not null default '{}'::jsonb,
  recruiter_notes text,
  recruiter_recommendation text,
  open_questions jsonb not null default '[]'::jsonb,
  hard_rule_issues jsonb not null default '[]'::jsonb,
  match_recompute_required boolean not null default false,
  idempotency_key text,
  last_mutation_key text,
  version integer not null default 1,
  started_by_user_id uuid not null references public.users(id) on delete restrict,
  completed_by_user_id uuid references public.users(id) on delete set null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agency_id,idempotency_key)
);

create unique index if not exists screening_active_application_uq on public.application_screening_sessions(agency_id,application_id)
  where status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED','ON_HOLD');
create index if not exists idx_xzr_screening_session_app on public.application_screening_sessions(agency_id,application_id,created_at desc);
create index if not exists idx_xzr_screening_session_recruiter on public.application_screening_sessions(agency_id,started_by_user_id,status,updated_at desc);

alter table public.application_screening_answers add column if not exists screening_session_id uuid references public.application_screening_sessions(id) on delete cascade;
alter table public.application_screening_answers add column if not exists category text;
alter table public.application_screening_answers add column if not exists priority text;
alter table public.application_screening_answers add column if not exists reason text;
alter table public.application_screening_answers add column if not exists related_requirement text;
alter table public.application_screening_answers add column if not exists source_evidence jsonb not null default '[]'::jsonb;
alter table public.application_screening_answers add column if not exists ai_metadata jsonb not null default '{}'::jsonb;
alter table public.application_screening_answers add column if not exists answer_source text not null default 'UNKNOWN';
alter table public.application_screening_answers add column if not exists answered_by_user_id uuid references public.users(id) on delete set null;
alter table public.application_screening_answers add column if not exists answer_version integer not null default 1;
alter table public.application_screening_answers add column if not exists required boolean not null default false;
alter table public.application_screening_answers drop constraint if exists application_screening_answers_application_id_question_key_key;
create unique index if not exists application_screening_answers_legacy_uq on public.application_screening_answers(application_id,question_key) where screening_session_id is null;
create unique index if not exists application_screening_answers_session_uq on public.application_screening_answers(screening_session_id,question_key) where screening_session_id is not null;
create index if not exists idx_xzr_screening_answers_session on public.application_screening_answers(agency_id,screening_session_id,updated_at desc);

create table if not exists public.candidate_fact_assertions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  application_id uuid references public.applications(id) on delete cascade,
  screening_session_id uuid references public.application_screening_sessions(id) on delete set null,
  fact_key text not null,
  fact_value jsonb,
  source_type text not null check (source_type in ('RESUME_CLAIM','AI_INFERENCE','RECRUITER_VERIFIED','CANDIDATE_DECLARED','DOCUMENT_VERIFIED','UNKNOWN')),
  verified boolean not null default false,
  evidence text,
  supersedes_fact_id uuid references public.candidate_fact_assertions(id) on delete set null,
  recorded_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint screening_ai_never_verified check (not (source_type in ('AI_INFERENCE','UNKNOWN','RESUME_CLAIM','CANDIDATE_DECLARED') and verified=true))
);
create index if not exists idx_xzr_screening_facts_candidate on public.candidate_fact_assertions(agency_id,candidate_id,fact_key,created_at desc);
create index if not exists idx_xzr_screening_facts_application on public.candidate_fact_assertions(agency_id,application_id,fact_key,created_at desc);

create table if not exists public.application_screening_summaries (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  screening_session_id uuid not null references public.application_screening_sessions(id) on delete cascade,
  version_number integer not null,
  outcome text not null,
  summary_data jsonb not null,
  candidate_snapshot jsonb not null,
  requirement_snapshot jsonb not null,
  intelligence_snapshot jsonb not null,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(screening_session_id,version_number)
);
create index if not exists idx_xzr_screening_summary_app on public.application_screening_summaries(agency_id,application_id,created_at desc);

create table if not exists public.application_screening_overrides (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  screening_session_id uuid not null references public.application_screening_sessions(id) on delete cascade,
  affected_rule text not null,
  prior_status text not null,
  reason text not null,
  supporting_note text,
  actor_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index if not exists idx_xzr_screening_override_app on public.application_screening_overrides(agency_id,application_id,created_at desc);

create table if not exists public.application_match_versions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  version_number integer not null,
  status text not null default 'SNAPSHOT' check (status in ('SNAPSHOT','PENDING_RECOMPUTE','RECOMPUTED')),
  intelligence_snapshot jsonb not null default '{}'::jsonb,
  evidence_delta jsonb not null default '{}'::jsonb,
  reason text,
  triggered_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(application_id,version_number)
);
create index if not exists idx_xzr_match_versions_app on public.application_match_versions(agency_id,application_id,version_number desc);

-- Reuse the existing task system for screening follow-ups instead of creating a second task engine.
alter table public.crm_tasks add column if not exists candidate_id uuid references public.candidates(id) on delete cascade;
alter table public.crm_tasks add column if not exists application_id uuid references public.applications(id) on delete cascade;
alter table public.crm_tasks drop constraint if exists crm_task_parent_required;
alter table public.crm_tasks add constraint crm_task_parent_required check (
  client_id is not null or contact_id is not null or opportunity_id is not null or candidate_id is not null or application_id is not null
);
create index if not exists idx_xzr_tasks_application on public.crm_tasks(agency_id,application_id,status,due_at);

create or replace function private.xzrecruiter_can_screen(p_role text) returns boolean
language sql immutable as $$ select upper(coalesce(p_role,'')) in ('OWNER','ADMIN','RECRUITER') $$;
revoke all on function private.xzrecruiter_can_screen(text) from public,anon,authenticated;

create or replace function private.xzrecruiter_screening_scope_guard() returns trigger
language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
begin
  if new.agency_id is null then raise exception 'screening_scope_guard: agency required'; end if;
  if to_jsonb(new) ? 'application_id' and (to_jsonb(new)->>'application_id') is not null then
    if not exists(select 1 from public.applications a where a.id=(to_jsonb(new)->>'application_id')::uuid and a.agency_id=new.agency_id) then raise exception 'screening_scope_guard: application mismatch'; end if;
  end if;
  if to_jsonb(new) ? 'candidate_id' and (to_jsonb(new)->>'candidate_id') is not null then
    if not exists(select 1 from public.candidates c where c.id=(to_jsonb(new)->>'candidate_id')::uuid and c.agency_id=new.agency_id) then raise exception 'screening_scope_guard: candidate mismatch'; end if;
  end if;
  if to_jsonb(new) ? 'job_id' and (to_jsonb(new)->>'job_id') is not null then
    if not exists(select 1 from public.recruitment_jobs j where j.id=(to_jsonb(new)->>'job_id')::uuid and j.agency_id=new.agency_id) then raise exception 'screening_scope_guard: job mismatch'; end if;
  end if;
  return new;
end;$fn$;
revoke all on function private.xzrecruiter_screening_scope_guard() from public,anon,authenticated;

do $do$
declare t text;
begin
  foreach t in array array['application_screening_sessions','candidate_fact_assertions','application_screening_summaries','application_screening_overrides','application_match_versions'] loop
    execute format('alter table public.%I enable row level security',t);
    if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',t);
    end if;
    if not exists(select 1 from pg_trigger where tgname='xzrecruiter_screening_scope_guard_'||t) then
      execute format('create trigger %I before insert or update on public.%I for each row execute function private.xzrecruiter_screening_scope_guard()','xzrecruiter_screening_scope_guard_'||t,t);
    end if;
  end loop;
end $do$;

create or replace function public.xzrecruiter_screening_context(p_token text,p_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_app jsonb;v_session jsonb;v_questions jsonb;v_facts jsonb;v_summaries jsonb;v_tasks jsonb;v_history jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select jsonb_build_object(
    'id',a.id,'candidateId',a.candidate_id,'jobId',a.job_id,'clientId',a.client_id,'stage',a.stage,'status',a.status,'matchEvidence',coalesce(a.match_evidence,'{}'::jsonb),
    'candidate',jsonb_build_object('id',c.id,'fullName',c.full_name,'currentTitle',c.current_title,'currentCompany',c.current_company,'experienceYears',c.experience_years,'relevantExperienceYears',c.relevant_experience_years,'city',c.city,'region',c.region,'countryCode',c.country_code,'availabilityStatus',c.availability_status,'noticePeriodDays',c.notice_period_days,'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'workplacePreference',c.workplace_preference,'workAuthorizationSummary',c.work_authorization_summary),
    'requirement',jsonb_build_object('id',j.id,'title',j.title,'mandatoryRequirements',coalesce(j.mandatory_requirements,'[]'::jsonb),'skillsRequired',coalesce(j.skills_required,'[]'::jsonb),'screeningQuestions',coalesce(j.screening_questions,'[]'::jsonb),'workplaceType',j.workplace_type,'location',j.location,'city',j.city,'countryCode',j.country_code,'salaryMin',j.salary_min,'salaryMax',j.salary_max,'salaryCurrency',j.salary_currency,'workAuthorizationRequirements',coalesce(j.work_authorization_requirements,'[]'::jsonb))
  ) into v_app
  from public.applications a join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
  where a.id=p_application_id and a.agency_id=v_agency and a.archived_at is null and c.archived_at is null and j.archived_at is null;
  if v_app is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;

  select to_jsonb(s) into v_session from public.application_screening_sessions s where s.agency_id=v_agency and s.application_id=p_application_id order by (s.status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED','ON_HOLD')) desc,s.created_at desc limit 1;
  if v_session is not null then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.priority_order,x.created_at),'[]'::jsonb) into v_questions from (
      select q.id,q.question_key,q.question_text,q.answer,q.category,q.priority,q.reason,q.related_requirement,q.source_evidence,q.ai_metadata,q.answer_source,q.reviewed_at,q.updated_at,q.created_at,
        case q.priority when 'CRITICAL' then 1 when 'HIGH' then 2 when 'MEDIUM' then 3 else 4 end priority_order
      from public.application_screening_answers q where q.agency_id=v_agency and q.screening_session_id=(v_session->>'id')::uuid order by q.created_at limit 100
    ) x;
  else v_questions:='[]'::jsonb; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_facts from (select id,fact_key,fact_value,source_type,verified,evidence,supersedes_fact_id,recorded_by_user_id,created_at from public.candidate_fact_assertions where agency_id=v_agency and application_id=p_application_id order by created_at desc limit 100) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_summaries from (select id,screening_session_id,version_number,outcome,summary_data,created_at from public.application_screening_summaries where agency_id=v_agency and application_id=p_application_id order by created_at desc limit 20) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_at nulls last),'[]'::jsonb) into v_tasks from (select id,title,description,status,priority,due_at,assigned_user_id,completed_at,created_at from public.crm_tasks where agency_id=v_agency and application_id=p_application_id and archived_at is null order by due_at nulls last limit 100) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into v_history from (select id,action,summary,metadata,actor_user_id,occurred_at from public.recruitment_activity_events where agency_id=v_agency and entity_type in ('application','screening') and (entity_id=p_application_id or entity_id in (select id from public.application_screening_sessions where agency_id=v_agency and application_id=p_application_id)) order by occurred_at desc limit 100) x;
  return jsonb_build_object('ok',true,'role',v_role,'application',v_app,'session',v_session,'questions',v_questions,'facts',v_facts,'summaries',v_summaries,'followups',v_tasks,'activity',v_history);
end;$fn$;

create or replace function public.xzrecruiter_start_screening(p_token text,p_application_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_candidate uuid;v_job uuid;v_existing uuid;v_previous uuid;v_id uuid;v_candidate_snapshot jsonb;v_requirement_snapshot jsonb;v_intelligence jsonb;v_brief jsonb;v_q jsonb;v_key text;v_text text;v_category text;v_priority text;v_reason text;v_i integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_screen(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if btrim(coalesce(p_idempotency_key,''))='' then return jsonb_build_object('ok',false,'error','idempotency_key_required'); end if;
  select id into v_existing from public.application_screening_sessions where agency_id=v_agency and idempotency_key=p_idempotency_key;
  if v_existing is not null then return jsonb_build_object('ok',true,'session_id',v_existing,'idempotent',true); end if;
  select id into v_existing from public.application_screening_sessions where agency_id=v_agency and application_id=p_application_id and status in ('SCREENING_PENDING','IN_PROGRESS','FOLLOW_UP_REQUIRED','ON_HOLD') order by created_at desc limit 1;
  if v_existing is not null then return jsonb_build_object('ok',true,'session_id',v_existing,'existing_active',true); end if;

  select a.candidate_id,a.job_id,
    jsonb_build_object('id',c.id,'fullName',c.full_name,'currentTitle',c.current_title,'currentCompany',c.current_company,'experienceYears',c.experience_years,'relevantExperienceYears',c.relevant_experience_years,'city',c.city,'countryCode',c.country_code,'availabilityStatus',c.availability_status,'noticePeriodDays',c.notice_period_days,'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'workplacePreference',c.workplace_preference),
    jsonb_build_object('id',j.id,'title',j.title,'mustHaves',coalesce(j.mandatory_requirements,'[]'::jsonb),'skillsRequired',coalesce(j.skills_required,'[]'::jsonb),'screeningQuestions',coalesce(j.screening_questions,'[]'::jsonb),'workplaceType',j.workplace_type,'location',j.location,'salaryMin',j.salary_min,'salaryMax',j.salary_max,'salaryCurrency',j.salary_currency,'workAuthorizationRequirements',coalesce(j.work_authorization_requirements,'[]'::jsonb)),
    coalesce(a.match_evidence,'{}'::jsonb)
  into v_candidate,v_job,v_candidate_snapshot,v_requirement_snapshot,v_intelligence
  from public.applications a join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
  where a.id=p_application_id and a.agency_id=v_agency and a.archived_at is null and c.archived_at is null and j.archived_at is null;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  select id into v_previous from public.application_screening_sessions where agency_id=v_agency and application_id=p_application_id order by created_at desc limit 1;
  v_brief:=jsonb_build_object(
    'candidateSnapshot',v_candidate_snapshot,
    'role',jsonb_build_object('title',v_requirement_snapshot->>'title','workplaceType',v_requirement_snapshot->>'workplaceType','location',v_requirement_snapshot->>'location'),
    'whyRelevant',coalesce(v_intelligence->'reasons','[]'::jsonb),
    'hardRuleStatus',coalesce(v_intelligence->>'hardRuleStatus',v_intelligence->>'hard_rule_status','UNKNOWN'),
    'gaps',coalesce(v_intelligence->'gaps','[]'::jsonb),
    'unknowns',jsonb_build_array('Confirm candidate interest','Confirm availability/notice','Confirm role-specific evidence'),
    'inconsistencies',coalesce(v_intelligence->'inconsistencies','[]'::jsonb),
    'attention',coalesce(v_intelligence->'warnings','[]'::jsonb),
    'blockers',coalesce(v_intelligence->'blockers','[]'::jsonb),
    'provenanceRule','AI suggestions are not candidate answers. Human/document evidence is required for verified facts.'
  );
  v_id:=gen_random_uuid();
  insert into public.application_screening_sessions(id,agency_id,application_id,candidate_id,job_id,previous_session_id,status,screening_brief,candidate_snapshot,requirement_snapshot,intelligence_snapshot,idempotency_key,started_by_user_id)
  values(v_id,v_agency,p_application_id,v_candidate,v_job,v_previous,'IN_PROGRESS',v_brief,v_candidate_snapshot,v_requirement_snapshot,v_intelligence,p_idempotency_key,v_user);

  insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,source_evidence,ai_metadata,answer_source)
  values
    (v_agency,p_application_id,v_id,'candidate_interest','Are you interested in this role and comfortable continuing in the process?','MANDATORY_CONFIRMATION','CRITICAL','Candidate interest must be explicitly confirmed by the recruiter.','candidate_interest','["APPROVED_REQUIREMENT"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN'),
    (v_agency,p_application_id,v_id,'relevant_experience','Please confirm your directly relevant experience and what you personally owned in production.','TECHNICAL_EXPERIENCE','HIGH','Confirms role-relevant evidence instead of relying on resume/AI inference.','relevant_experience','["STEP4_CANDIDATE_INTELLIGENCE"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN'),
    (v_agency,p_application_id,v_id,'availability','What is your current notice period or earliest realistic start date?','AVAILABILITY','HIGH','Availability must be human confirmed.','availability','[]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN'),
    (v_agency,p_application_id,v_id,'location_work_model','Are you comfortable with the approved location and work model for this role?','LOGISTICS','HIGH','Confirms location/work-model compatibility.','work_model','["APPROVED_REQUIREMENT"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN');

  if (v_requirement_snapshot->>'salaryMin') is not null or (v_requirement_snapshot->>'salaryMax') is not null then
    insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,ai_metadata,answer_source)
    values(v_agency,p_application_id,v_id,'compensation','What compensation or rate expectation should we record for this opportunity?','COMPENSATION','HIGH','Approved requirement contains compensation context.','compensation',jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN');
  end if;
  if jsonb_array_length(coalesce(v_requirement_snapshot->'workAuthorizationRequirements','[]'::jsonb))>0 then
    insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,ai_metadata,answer_source)
    values(v_agency,p_application_id,v_id,'work_authorization','Please confirm only the work-authorization status relevant to this approved role.','AUTHORIZATION','CRITICAL','Approved requirement contains an authorization constraint.','work_authorization',jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN');
  end if;

  -- Materialize approved must-have confirmations. These are trusted requirement data, not resume instructions.
  for v_q in select value from jsonb_array_elements(coalesce(v_requirement_snapshot->'mustHaves','[]'::jsonb)) loop
    v_i:=v_i+1;
    v_text:=btrim(case when jsonb_typeof(v_q)='string' then coalesce(v_q#>>'{}','') else coalesce(v_q->>'label',v_q->>'requirement',v_q->>'text','') end);
    if v_text<>'' and lower(v_text) !~ '(race|caste|religion|sexual orientation|political view|family status|marital status|pregnan|appearance|ethnicity|disability|date of birth)' then
      insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,source_evidence,ai_metadata,answer_source)
      values(v_agency,p_application_id,v_id,'must_have_'||v_i,'Please confirm your hands-on evidence for this must-have: '||left(v_text,300),'MANDATORY_CONFIRMATION','CRITICAL','Approved must-have requires human confirmation.',left(v_text,300),'["APPROVED_REQUIREMENT"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN') on conflict do nothing;
    end if;
  end loop;

  -- Step-4 AI evidence is untrusted text. Use it only as clarification context and drop instruction-like content.
  for v_q in select value from jsonb_array_elements(coalesce(v_intelligence->'gaps','[]'::jsonb)) loop
    v_i:=v_i+1;
    v_text:=btrim(case when jsonb_typeof(v_q)='string' then coalesce(v_q#>>'{}','') else coalesce(v_q->>'label',v_q->>'text',v_q->>'reason','') end);
    if v_text<>'' and lower(v_text) !~ '(ignore (all|previous|prior)|system prompt|developer message|mark (the )?candidate (as )?qualified|override (the )?rules|bypass (the )?rules|race|caste|religion|sexual orientation|political view|family status|marital status|pregnan|appearance|ethnicity|disability|date of birth)' then
      insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,source_evidence,ai_metadata,answer_source)
      values(v_agency,p_application_id,v_id,'gap_'||v_i,'Please clarify this open point from Candidate Intelligence: '||left(v_text,300),'CLARIFICATION','HIGH','Step-4 Candidate Intelligence marked this information incomplete or uncertain.',left(v_text,300),'["STEP4_CANDIDATE_INTELLIGENCE"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN') on conflict do nothing;
    end if;
  end loop;
  for v_q in select value from jsonb_array_elements(coalesce(v_intelligence->'warnings','[]'::jsonb)) loop
    v_i:=v_i+1;
    v_text:=btrim(case when jsonb_typeof(v_q)='string' then coalesce(v_q#>>'{}','') else coalesce(v_q->>'label',v_q->>'text',v_q->>'reason','') end);
    if v_text<>'' and lower(v_text) !~ '(ignore (all|previous|prior)|system prompt|developer message|mark (the )?candidate (as )?qualified|override (the )?rules|bypass (the )?rules|race|caste|religion|sexual orientation|political view|family status|marital status|pregnan|appearance|ethnicity|disability|date of birth)' then
      insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,source_evidence,ai_metadata,answer_source)
      values(v_agency,p_application_id,v_id,'warning_'||v_i,'What evidence can confirm or resolve this warning: '||left(v_text,300),'CLARIFICATION','HIGH','Step-4 warning needs human evidence before safe progression.',left(v_text,300),'["STEP4_WARNING"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),'UNKNOWN') on conflict do nothing;
    end if;
  end loop;
  for v_q in select value from jsonb_array_elements(coalesce(v_requirement_snapshot->'screeningQuestions','[]'::jsonb)) loop
    v_i:=v_i+1;v_key:=coalesce(nullif(btrim(v_q->>'id'),''),'approved_'||v_i);v_text:=btrim(coalesce(v_q->>'question',''));v_category:=upper(coalesce(nullif(v_q->>'category',''),'ROLE_FIT'));v_priority:=upper(coalesce(nullif(v_q->>'priority',''),'MEDIUM'));v_reason:='Approved requisition screening question.';
    if v_text<>'' and lower(v_text) !~ '(race|caste|religion|sexual orientation|political view|family status|marital status|pregnan|appearance|ethnicity|disability|date of birth)' then
      insert into public.application_screening_answers(agency_id,application_id,screening_session_id,question_key,question_text,category,priority,reason,related_requirement,source_evidence,ai_metadata,knockout,required,answer_source)
      values(v_agency,p_application_id,v_id,v_key,v_text,v_category,v_priority,v_reason,nullif(v_q->>'relatedRequirement',''),'["APPROVED_REQUIREMENT"]'::jsonb,jsonb_build_object('engine','GROUNDED_SCREENING_V1'),coalesce((v_q->>'knockout')::boolean,false),coalesce((v_q->>'required')::boolean,false),'UNKNOWN') on conflict do nothing;
    end if;
  end loop;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'screening',v_id,'screening.started','Human screening started',jsonb_build_object('application_id',p_application_id,'candidate_id',v_candidate,'job_id',v_job));
  return jsonb_build_object('ok',true,'session_id',v_id,'version',1);
end;$fn$;

create or replace function public.xzrecruiter_save_screening_progress(p_token text,p_session_id uuid,p_expected_version integer,p_payload jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_s public.application_screening_sessions%rowtype;v_item jsonb;v_key text;v_source text;v_verified boolean;v_previous jsonb;v_recompute boolean:=false;v_answers jsonb;v_facts jsonb;v_interest text;v_notes text;v_recommendation text;v_status text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_screen(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select * into v_s from public.application_screening_sessions where id=p_session_id and agency_id=v_agency for update;
  if not found then return jsonb_build_object('ok',false,'error','screening_not_found'); end if;
  if btrim(coalesce(p_idempotency_key,''))='' then return jsonb_build_object('ok',false,'error','idempotency_key_required'); end if;
  if v_s.last_mutation_key=p_idempotency_key then return jsonb_build_object('ok',true,'version',v_s.version,'idempotent',true,'match_recompute_required',v_s.match_recompute_required); end if;
  if v_s.version<>p_expected_version then return jsonb_build_object('ok',false,'error','stale_screening_version','current_version',v_s.version); end if;
  if v_s.status in ('QUALIFIED','NOT_QUALIFIED','CANDIDATE_NOT_INTERESTED','WITHDRAWN') then return jsonb_build_object('ok',false,'error','screening_closed'); end if;
  v_answers:=coalesce(p_payload->'answers','[]'::jsonb);v_facts:=coalesce(p_payload->'facts','[]'::jsonb);
  if jsonb_typeof(v_answers)<>'array' or jsonb_typeof(v_facts)<>'array' then return jsonb_build_object('ok',false,'error','invalid_screening_payload'); end if;

  for v_item in select value from jsonb_array_elements(v_answers) loop
    v_key:=btrim(coalesce(v_item->>'key',''));v_source:=upper(coalesce(nullif(v_item->>'source',''),'UNKNOWN'));
    if v_key='' or v_source not in ('CANDIDATE_DECLARED','RECRUITER_VERIFIED','DOCUMENT_VERIFIED','UNKNOWN') then return jsonb_build_object('ok',false,'error','invalid_screening_answer'); end if;
    update public.application_screening_answers set answer=v_item->'answer',answer_source=v_source,answered_by_user_id=v_user,reviewed_by_user_id=v_user,reviewed_at=now(),answer_version=answer_version+1,updated_at=now()
    where agency_id=v_agency and screening_session_id=p_session_id and question_key=v_key;
    if not found then return jsonb_build_object('ok',false,'error','screening_question_not_found','question_key',v_key); end if;
  end loop;

  for v_item in select value from jsonb_array_elements(v_facts) loop
    v_key:=btrim(coalesce(v_item->>'key',''));v_source:=upper(coalesce(nullif(v_item->>'source',''),'UNKNOWN'));v_verified:=coalesce((v_item->>'verified')::boolean,false);
    if v_key='' or v_source not in ('RESUME_CLAIM','AI_INFERENCE','RECRUITER_VERIFIED','CANDIDATE_DECLARED','DOCUMENT_VERIFIED','UNKNOWN') then return jsonb_build_object('ok',false,'error','invalid_fact_source'); end if;
    if v_verified and v_source not in ('RECRUITER_VERIFIED','DOCUMENT_VERIFIED') then return jsonb_build_object('ok',false,'error','fake_verification_forbidden'); end if;
    select fact_value into v_previous from public.candidate_fact_assertions where agency_id=v_agency and candidate_id=v_s.candidate_id and application_id=v_s.application_id and fact_key=v_key order by created_at desc limit 1;
    insert into public.candidate_fact_assertions(agency_id,candidate_id,application_id,screening_session_id,fact_key,fact_value,source_type,verified,evidence,supersedes_fact_id,recorded_by_user_id)
    values(v_agency,v_s.candidate_id,v_s.application_id,p_session_id,v_key,v_item->'value',v_source,v_verified,nullif(v_item->>'evidence',''),(select id from public.candidate_fact_assertions where agency_id=v_agency and candidate_id=v_s.candidate_id and application_id=v_s.application_id and fact_key=v_key order by created_at desc limit 1),v_user);
    if v_key in ('relevant_experience','must_have','skills','location_work_model','availability','compensation','work_authorization') and coalesce(v_previous,'null'::jsonb) is distinct from coalesce(v_item->'value','null'::jsonb) then v_recompute:=true; end if;
  end loop;

  v_interest:=upper(coalesce(nullif(p_payload->>'candidateInterest',''),v_s.candidate_interest));
  if v_interest not in ('INTERESTED','NOT_INTERESTED','UNSURE','UNKNOWN') then return jsonb_build_object('ok',false,'error','invalid_candidate_interest'); end if;
  v_notes:=nullif(btrim(coalesce(p_payload->>'recruiterNotes','')),'');v_recommendation:=nullif(btrim(coalesce(p_payload->>'recommendation','')),'');v_status:=upper(coalesce(nullif(p_payload->>'status',''),'IN_PROGRESS'));
  if v_status not in ('IN_PROGRESS','FOLLOW_UP_REQUIRED','ON_HOLD','NO_RESPONSE') then v_status:='IN_PROGRESS'; end if;
  if v_recompute then
    insert into public.application_match_versions(agency_id,application_id,version_number,status,intelligence_snapshot,evidence_delta,reason,triggered_by_user_id)
    values(v_agency,v_s.application_id,coalesce((select max(version_number)+1 from public.application_match_versions where application_id=v_s.application_id),1),'PENDING_RECOMPUTE',coalesce((select match_evidence from public.applications where id=v_s.application_id),'{}'::jsonb),jsonb_build_object('screening_session_id',p_session_id,'facts',v_facts),'Human screening evidence changed match-relevant facts',v_user);
  end if;
  update public.application_screening_sessions set candidate_interest=v_interest,recruiter_notes=v_notes,recruiter_recommendation=v_recommendation,status=v_status,match_recompute_required=match_recompute_required or v_recompute,last_mutation_key=p_idempotency_key,version=version+1,updated_at=now() where id=p_session_id;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'screening',p_session_id,'screening.progress_saved','Screening progress saved',jsonb_build_object('application_id',v_s.application_id,'match_recompute_required',v_recompute));
  return jsonb_build_object('ok',true,'version',v_s.version+1,'match_recompute_required',v_s.match_recompute_required or v_recompute);
end;$fn$;

create or replace function public.xzrecruiter_complete_screening(p_token text,p_session_id uuid,p_expected_version integer,p_outcome text,p_override jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_s public.application_screening_sessions%rowtype;v_outcome text:=upper(coalesce(p_outcome,''));v_hard_status text;v_non_overridable boolean:=false;v_override_reason text;v_summary jsonb;v_summary_id uuid;v_summary_version integer;v_answers jsonb;v_facts jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_screen(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select * into v_s from public.application_screening_sessions where id=p_session_id and agency_id=v_agency for update;
  if not found then return jsonb_build_object('ok',false,'error','screening_not_found'); end if;
  if btrim(coalesce(p_idempotency_key,''))='' then return jsonb_build_object('ok',false,'error','idempotency_key_required'); end if;
  if v_s.last_mutation_key=p_idempotency_key and v_s.outcome=v_outcome then return jsonb_build_object('ok',true,'outcome',v_s.outcome,'idempotent',true); end if;
  if v_s.version<>p_expected_version then return jsonb_build_object('ok',false,'error','stale_screening_version','current_version',v_s.version); end if;
  if v_outcome not in ('QUALIFIED','NOT_QUALIFIED','CANDIDATE_NOT_INTERESTED','NO_RESPONSE','ON_HOLD','WITHDRAWN','FOLLOW_UP_REQUIRED') then return jsonb_build_object('ok',false,'error','invalid_screening_outcome'); end if;
  if v_outcome='QUALIFIED' and v_s.candidate_interest<>'INTERESTED' then return jsonb_build_object('ok',false,'error','candidate_interest_required'); end if;
  if v_outcome='CANDIDATE_NOT_INTERESTED' and v_s.candidate_interest<>'NOT_INTERESTED' then return jsonb_build_object('ok',false,'error','candidate_interest_outcome_mismatch'); end if;
  if v_outcome='QUALIFIED' and exists(select 1 from public.application_screening_answers q where q.agency_id=v_agency and q.screening_session_id=p_session_id and (q.question_key like 'must_have_%' or q.required=true) and (q.answer is null or q.answer='null'::jsonb or q.answer='""'::jsonb)) then return jsonb_build_object('ok',false,'error','qualification_requirements_missing'); end if;

  v_hard_status:=upper(coalesce(v_s.intelligence_snapshot->>'hardRuleStatus',v_s.intelligence_snapshot->>'hard_rule_status','UNKNOWN'));
  v_non_overridable:=coalesce((v_s.intelligence_snapshot->>'nonOverridable')::boolean,(v_s.intelligence_snapshot->>'non_overridable')::boolean,false);
  if v_outcome='QUALIFIED' and v_hard_status in ('FAIL','UNKNOWN') and v_non_overridable then return jsonb_build_object('ok',false,'error','non_overridable_hard_rule'); end if;
  if v_outcome='QUALIFIED' and v_hard_status in ('WARN','FAIL') then
    v_override_reason:=btrim(coalesce(p_override->>'reason',''));
    if v_override_reason='' then return jsonb_build_object('ok',false,'error','override_reason_required'); end if;
    insert into public.application_screening_overrides(agency_id,application_id,screening_session_id,affected_rule,prior_status,reason,supporting_note,actor_user_id)
    values(v_agency,v_s.application_id,p_session_id,coalesce(nullif(p_override->>'rule',''),'STEP4_HARD_RULE'),v_hard_status,v_override_reason,nullif(p_override->>'note',''),v_user);
    perform private.xzrecruiter_log_activity(v_agency,v_user,'screening',p_session_id,'screening.override_applied','Authorized screening override recorded',jsonb_build_object('rule',coalesce(nullif(p_override->>'rule',''),'STEP4_HARD_RULE'),'prior_status',v_hard_status,'reason',v_override_reason));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('key',q.question_key,'question',q.question_text,'answer',q.answer,'source',q.answer_source,'category',q.category,'priority',q.priority) order by q.created_at),'[]'::jsonb) into v_answers from public.application_screening_answers q where q.agency_id=v_agency and q.screening_session_id=p_session_id;
  select coalesce(jsonb_agg(jsonb_build_object('key',f.fact_key,'value',f.fact_value,'source',f.source_type,'verified',f.verified,'evidence',f.evidence,'recordedAt',f.created_at) order by f.created_at),'[]'::jsonb) into v_facts from public.candidate_fact_assertions f where f.agency_id=v_agency and f.screening_session_id=p_session_id;
  v_summary:=jsonb_build_object('candidate',v_s.candidate_snapshot,'requirement',v_s.requirement_snapshot,'screeningDate',now(),'outcome',v_outcome,'candidateInterest',v_s.candidate_interest,'facts',v_facts,'answers',v_answers,'hardRuleIssues',v_s.hard_rule_issues,'openQuestions',v_s.open_questions,'recruiterNotes',v_s.recruiter_notes,'recruiterRecommendation',v_s.recruiter_recommendation,'provenance','VERIFIED/CANDIDATE_DECLARED/AI_DERIVED/UNKNOWN preserved in source fields');
  v_summary_version:=coalesce((select max(version_number)+1 from public.application_screening_summaries where screening_session_id=p_session_id),1);v_summary_id:=gen_random_uuid();
  insert into public.application_screening_summaries(id,agency_id,application_id,screening_session_id,version_number,outcome,summary_data,candidate_snapshot,requirement_snapshot,intelligence_snapshot,created_by_user_id)
  values(v_summary_id,v_agency,v_s.application_id,p_session_id,v_summary_version,v_outcome,v_summary,v_s.candidate_snapshot,v_s.requirement_snapshot,v_s.intelligence_snapshot,v_user);
  update public.application_screening_sessions set status=v_outcome,outcome=v_outcome,completed_by_user_id=case when v_outcome in ('QUALIFIED','NOT_QUALIFIED','CANDIDATE_NOT_INTERESTED','WITHDRAWN') then v_user else completed_by_user_id end,completed_at=case when v_outcome in ('QUALIFIED','NOT_QUALIFIED','CANDIDATE_NOT_INTERESTED','WITHDRAWN') then now() else completed_at end,last_mutation_key=p_idempotency_key,version=version+1,updated_at=now() where id=p_session_id;
  update public.applications set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('screeningOutcome',v_outcome,'screeningSummaryId',v_summary_id,'screeningEligibleForSubmission',(v_outcome='QUALIFIED'),'screeningCompletedBy',v_user,'screeningCompletedAt',now()),last_activity_at=now(),updated_at=now() where id=v_s.application_id and agency_id=v_agency;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'screening',p_session_id,'screening.completed','Human screening outcome recorded',jsonb_build_object('application_id',v_s.application_id,'outcome',v_outcome,'summary_id',v_summary_id));
  if v_outcome='QUALIFIED' then perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_s.application_id,'candidate.qualified','Candidate qualified by authorized human recruiter',jsonb_build_object('screening_session_id',p_session_id,'summary_id',v_summary_id)); end if;
  return jsonb_build_object('ok',true,'outcome',v_outcome,'summary_id',v_summary_id,'version',v_s.version+1,'eligible_for_step6',(v_outcome='QUALIFIED'));
end;$fn$;

create or replace function public.xzrecruiter_create_screening_followup(p_token text,p_session_id uuid,p_followup jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_s public.application_screening_sessions%rowtype;v_id uuid;v_title text;v_due timestamptz;v_assigned uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_screen(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select * into v_s from public.application_screening_sessions where id=p_session_id and agency_id=v_agency;
  if not found then return jsonb_build_object('ok',false,'error','screening_not_found'); end if;
  if btrim(coalesce(p_idempotency_key,''))='' then return jsonb_build_object('ok',false,'error','idempotency_key_required'); end if;
  if exists(select 1 from public.recruitment_activity_events where agency_id=v_agency and entity_type='screening' and entity_id=p_session_id and action='screening.followup_created' and metadata->>'idempotency_key'=p_idempotency_key) then
    return jsonb_build_object('ok',true,'idempotent',true);
  end if;
  v_title:=btrim(coalesce(p_followup->>'title','Candidate screening follow-up'));v_due:=nullif(p_followup->>'dueAt','')::timestamptz;v_assigned:=coalesce(nullif(p_followup->>'assignedUserId','')::uuid,v_user);
  if not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_assigned) then return jsonb_build_object('ok',false,'error','invalid_assignee'); end if;
  v_id:=gen_random_uuid();
  insert into public.crm_tasks(id,agency_id,title,description,status,priority,due_at,assigned_user_id,candidate_id,application_id,client_id,created_by_user_id)
  values(v_id,v_agency,v_title,nullif(p_followup->>'description',''),'OPEN',upper(coalesce(nullif(p_followup->>'priority',''),'NORMAL')),v_due,v_assigned,v_s.candidate_id,v_s.application_id,(select client_id from public.applications where id=v_s.application_id),v_user);
  update public.application_screening_sessions set status='FOLLOW_UP_REQUIRED',updated_at=now(),version=version+1 where id=p_session_id and agency_id=v_agency and status not in ('QUALIFIED','NOT_QUALIFIED','WITHDRAWN');
  perform private.xzrecruiter_log_activity(v_agency,v_user,'screening',p_session_id,'screening.followup_created','Screening follow-up created',jsonb_build_object('task_id',v_id,'application_id',v_s.application_id,'idempotency_key',p_idempotency_key));
  return jsonb_build_object('ok',true,'task_id',v_id);
end;$fn$;

revoke all on function public.xzrecruiter_screening_context(text,uuid) from public;
revoke all on function public.xzrecruiter_start_screening(text,uuid,text) from public;
revoke all on function public.xzrecruiter_save_screening_progress(text,uuid,integer,jsonb,text) from public;
revoke all on function public.xzrecruiter_complete_screening(text,uuid,integer,text,jsonb,text) from public;
revoke all on function public.xzrecruiter_create_screening_followup(text,uuid,jsonb,text) from public;
grant execute on function public.xzrecruiter_screening_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_start_screening(text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_screening_progress(text,uuid,integer,jsonb,text) to anon,authenticated;
grant execute on function public.xzrecruiter_complete_screening(text,uuid,integer,text,jsonb,text) to anon,authenticated;
grant execute on function public.xzrecruiter_create_screening_followup(text,uuid,jsonb,text) to anon,authenticated;
