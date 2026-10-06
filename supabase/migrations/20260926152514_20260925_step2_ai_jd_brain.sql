-- XZ Recruiter locked roadmap Step 2: AI JD Brain.
-- Additive requirement-intelligence layer on top of the existing recruitment_jobs domain.
-- No Step-3 recruiter workspace functionality is introduced here.

-- Existing manually configured jobs remain valid/recruiter-ready until they enter the AI JD workflow.
alter table public.recruitment_jobs
  add column if not exists requirement_state text not null default 'OPEN',
  add column if not exists recruiter_ready boolean not null default true,
  add column if not exists requirement_contract_version text not null default 'LEGACY_MANUAL';

alter table public.recruitment_jobs
  drop constraint if exists recruitment_jobs_requirement_state_check;
alter table public.recruitment_jobs
  add constraint recruitment_jobs_requirement_state_check
  check (requirement_state in (
    'JD_RECEIVED','AI_BRIEF_PENDING','AM_REVIEW','APPROVED','OPEN',
    'CHANGE_PENDING_AM_CONFIRMATION','ON_HOLD','CLOSED','CANCELLED'
  ));

create table if not exists public.requirement_jd_sources (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  version_number integer not null,
  source_type text not null check (source_type in ('PASTED','UPLOAD','EXISTING')),
  source_status text not null default 'RECEIVED' check (source_status in ('RECEIVED','UPLOADING','READY','FAILED')),
  original_text text,
  extracted_text text,
  filename text,
  mime_type text,
  size_bytes bigint,
  storage_path text,
  checksum_sha256 text not null,
  parsing_error text,
  supersedes_source_id uuid references public.requirement_jd_sources(id) on delete set null,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  unique(job_id,version_number),
  unique(agency_id,job_id,checksum_sha256)
);
create index if not exists idx_requirement_jd_sources_job
  on public.requirement_jd_sources(agency_id,job_id,version_number desc);

create table if not exists public.requirement_ai_runs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  jd_source_id uuid not null references public.requirement_jd_sources(id) on delete cascade,
  idempotency_key text not null,
  run_status text not null default 'PROCESSING' check (run_status in ('PROCESSING','SUCCEEDED','FAILED')),
  model_requested text not null,
  model_resolved text,
  provider_response_id text,
  prompt_version text not null,
  schema_version text not null,
  input_hash text not null,
  attempt_count integer not null default 1,
  review_state text,
  output_json jsonb,
  error_code text,
  error_detail text,
  started_by_user_id uuid not null references public.users(id) on delete restrict,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(agency_id,idempotency_key)
);
create index if not exists idx_requirement_ai_runs_job
  on public.requirement_ai_runs(agency_id,job_id,started_at desc);

create table if not exists public.requirement_hiring_briefs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  jd_source_id uuid not null references public.requirement_jd_sources(id) on delete restrict,
  ai_run_id uuid references public.requirement_ai_runs(id) on delete set null,
  version_number integer not null,
  brief_status text not null check (brief_status in (
    'NEEDS_REVIEW','NEEDS_CLARIFICATION','READY_FOR_APPROVAL',
    'APPROVED','FAILED','REVISION_REQUESTED','SUPERSEDED'
  )),
  structured_data jsonb not null default '{}'::jsonb,
  hiring_brief jsonb not null default '{}'::jsonb,
  search_blueprint jsonb not null default '{}'::jsonb,
  input_safety jsonb not null default '{}'::jsonb,
  model_name text,
  prompt_version text,
  schema_version text,
  source_fingerprint text not null,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  approved_by_user_id uuid references public.users(id) on delete set null,
  approved_at timestamptz,
  approval_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(job_id,version_number)
);
create index if not exists idx_requirement_briefs_job
  on public.requirement_hiring_briefs(agency_id,job_id,version_number desc);

alter table public.recruitment_jobs
  add column if not exists approved_hiring_brief_id uuid references public.requirement_hiring_briefs(id) on delete set null;

create table if not exists public.requirement_criteria (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  brief_id uuid not null references public.requirement_hiring_briefs(id) on delete cascade,
  criterion_kind text not null check (criterion_kind in ('HARD_REQUIREMENT','MUST_HAVE','NICE_TO_HAVE','RANKING_PREFERENCE')),
  label text not null,
  field_key text not null,
  value_text text not null,
  confidence numeric not null check (confidence >= 0 and confidence <= 1),
  evidence jsonb not null default '[]'::jsonb,
  extraction_status text not null check (extraction_status in ('confirmed_from_jd','inferred_candidate','missing','ambiguous','conflicting')),
  enforcement text not null check (enforcement in ('ACTIVE','PROPOSED_REVIEW','INACTIVE')),
  requires_am_confirmation boolean not null default false,
  am_confirmed boolean not null default false,
  am_confirmed_by_user_id uuid references public.users(id) on delete set null,
  am_confirmed_at timestamptz,
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);
create index if not exists idx_requirement_criteria_brief
  on public.requirement_criteria(agency_id,brief_id,criterion_kind,sort_order);

create table if not exists public.requirement_clarifications (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  brief_id uuid not null references public.requirement_hiring_briefs(id) on delete cascade,
  issue_type text not null check (issue_type in ('MISSING','AMBIGUOUS','CONFLICTING')),
  field_key text not null,
  question text not null,
  evidence jsonb not null default '[]'::jsonb,
  blocking boolean not null default false,
  resolved boolean not null default false,
  resolution text,
  resolved_by_user_id uuid references public.users(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_requirement_clarifications_brief
  on public.requirement_clarifications(agency_id,brief_id,resolved,blocking);

create table if not exists public.requirement_brief_audit (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  brief_id uuid not null references public.requirement_hiring_briefs(id) on delete cascade,
  actor_user_id uuid not null references public.users(id) on delete restrict,
  action text not null,
  before_value jsonb,
  after_value jsonb,
  reason text,
  occurred_at timestamptz not null default now()
);
create index if not exists idx_requirement_brief_audit
  on public.requirement_brief_audit(agency_id,brief_id,occurred_at desc);

-- Direct browser access remains deny-by-default; app access goes through session-scoped RPCs.
do $do$
declare t text;
begin
  foreach t in array array[
    'requirement_jd_sources','requirement_ai_runs','requirement_hiring_briefs',
    'requirement_criteria','requirement_clarifications','requirement_brief_audit'
  ] loop
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
  end loop;
end $do$;

create or replace function private.xzrecruiter_requirement_am_role(
  p_agency_id uuid,p_user_id uuid,p_membership_role text
) returns text
language sql
stable
security invoker
set search_path='public','private','pg_temp'
as $$
  select private.xzrecruiter_business_role(p_agency_id,p_user_id,p_membership_role);
$$;
revoke all on function private.xzrecruiter_requirement_am_role(uuid,uuid,text) from public,anon,authenticated;

create or replace function public.xzrecruiter_prepare_jd_source(
  p_token text,
  p_job_id uuid,
  p_source_type text,
  p_original_text text,
  p_filename text,
  p_mime_type text,
  p_size_bytes bigint,
  p_checksum_sha256 text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_source_type text:=upper(btrim(coalesce(p_source_type,'')));
  v_id uuid;v_existing uuid;v_version integer;v_previous uuid;v_storage text;v_had_approved boolean;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then
    return jsonb_build_object('ok',false,'error','am_only');
  end if;
  if v_source_type not in ('PASTED','UPLOAD','EXISTING') then
    return jsonb_build_object('ok',false,'error','invalid_source_type');
  end if;
  if length(coalesce(p_checksum_sha256,''))<>64 then
    return jsonb_build_object('ok',false,'error','invalid_checksum');
  end if;
  if not exists(
    select 1 from public.recruitment_jobs
    where id=p_job_id and agency_id=v_agency and archived_at is null
  ) then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  select id into v_existing
  from public.requirement_jd_sources
  where agency_id=v_agency and job_id=p_job_id and checksum_sha256=p_checksum_sha256
  order by version_number desc limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok',true,'duplicate',true,'source_id',v_existing);
  end if;

  select id into v_previous
  from public.requirement_jd_sources
  where agency_id=v_agency and job_id=p_job_id
  order by version_number desc limit 1;
  select coalesce(max(version_number),0)+1 into v_version
  from public.requirement_jd_sources
  where agency_id=v_agency and job_id=p_job_id;

  select approved_hiring_brief_id is not null into v_had_approved
  from public.recruitment_jobs
  where id=p_job_id and agency_id=v_agency;

  v_id:=gen_random_uuid();
  if v_source_type='UPLOAD' then
    v_storage:='requirements/'||v_agency::text||'/'||p_job_id::text||'/'||v_id::text||'/'||
      regexp_replace(coalesce(nullif(p_filename,''),'jd-document'),'[^A-Za-z0-9._-]+','_','g');
  end if;

  insert into public.requirement_jd_sources(
    id,agency_id,job_id,version_number,source_type,source_status,original_text,extracted_text,
    filename,mime_type,size_bytes,storage_path,checksum_sha256,supersedes_source_id,created_by_user_id,
    finalized_at
  ) values(
    v_id,v_agency,p_job_id,v_version,v_source_type,
    case when v_source_type='UPLOAD' then 'UPLOADING' else 'READY' end,
    case when v_source_type='UPLOAD' then null else p_original_text end,
    case when v_source_type='UPLOAD' then null else p_original_text end,
    nullif(p_filename,''),nullif(p_mime_type,''),p_size_bytes,v_storage,p_checksum_sha256,v_previous,v_user,
    case when v_source_type='UPLOAD' then null else now() end
  );

  update public.recruitment_jobs
  set requirement_state=case when v_had_approved then 'CHANGE_PENDING_AM_CONFIRMATION' else 'JD_RECEIVED' end,
      recruiter_ready=false,
      requirement_contract_version='AI_JD_V1',
      updated_at=now()
  where id=p_job_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',p_job_id,'requirement.jd_received','Client JD source version received',
    jsonb_build_object('source_id',v_id,'version',v_version,'source_type',v_source_type,'material_change',v_had_approved)
  );

  return jsonb_build_object(
    'ok',true,'duplicate',false,'source_id',v_id,'version_number',v_version,
    'storage_path',v_storage,'source_status',case when v_source_type='UPLOAD' then 'UPLOADING' else 'READY' end
  );
end;
$fn$;

create or replace function public.xzrecruiter_finalize_jd_source(
  p_token text,p_source_id uuid,p_extracted_text text,p_error text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_job uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select job_id into v_job
  from public.requirement_jd_sources
  where id=p_source_id and agency_id=v_agency;
  if v_job is null then return jsonb_build_object('ok',false,'error','jd_source_not_found'); end if;

  update public.requirement_jd_sources
  set extracted_text=case when p_error is null then p_extracted_text else extracted_text end,
      source_status=case when p_error is null then 'READY' else 'FAILED' end,
      parsing_error=nullif(p_error,''),
      finalized_at=now()
  where id=p_source_id and agency_id=v_agency;

  if p_error is not null then
    perform private.xzrecruiter_log_activity(
      v_agency,v_user,'job',v_job,'requirement.jd_parse_failed','JD document parsing failed',
      jsonb_build_object('source_id',p_source_id,'error',left(p_error,200))
    );
  end if;
  return jsonb_build_object('ok',true,'source_status',case when p_error is null then 'READY' else 'FAILED' end);
end;
$fn$;

create or replace function public.xzrecruiter_jd_source_text(
  p_token text,p_source_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_row jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select jsonb_build_object(
    'id',s.id,'job_id',s.job_id,'version_number',s.version_number,'source_type',s.source_type,
    'source_status',s.source_status,'original_text',s.original_text,'extracted_text',s.extracted_text,
    'filename',s.filename,'mime_type',s.mime_type,'storage_path',s.storage_path,
    'checksum_sha256',s.checksum_sha256,'created_at',s.created_at,'finalized_at',s.finalized_at
  ) into v_row
  from public.requirement_jd_sources s
  where s.id=p_source_id and s.agency_id=v_agency;

  if v_row is null then return jsonb_build_object('ok',false,'error','jd_source_not_found'); end if;
  return jsonb_build_object('ok',true,'source',v_row);
end;
$fn$;

create or replace function public.xzrecruiter_begin_jd_ai_run(
  p_token text,p_source_id uuid,p_idempotency_key text,p_model text,
  p_prompt_version text,p_schema_version text,p_input_hash text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_job uuid;v_status text;v_run uuid;v_existing_status text;v_attempt integer;v_started_at timestamptz;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select job_id,source_status into v_job,v_status
  from public.requirement_jd_sources
  where id=p_source_id and agency_id=v_agency;
  if v_job is null then return jsonb_build_object('ok',false,'error','jd_source_not_found'); end if;
  if v_status<>'READY' then return jsonb_build_object('ok',false,'error','jd_source_not_ready'); end if;
  if length(coalesce(p_idempotency_key,''))<32 then return jsonb_build_object('ok',false,'error','invalid_idempotency_key'); end if;

  select id,run_status,attempt_count,started_at into v_run,v_existing_status,v_attempt,v_started_at
  from public.requirement_ai_runs
  where agency_id=v_agency and idempotency_key=p_idempotency_key
  limit 1;

  if v_run is not null and v_existing_status='SUCCEEDED' then
    return jsonb_build_object('ok',true,'run_id',v_run,'reused',true,'run_status','SUCCEEDED');
  end if;
  if v_run is not null and v_existing_status='PROCESSING' and v_started_at > now()-interval '5 minutes' then
    return jsonb_build_object('ok',true,'run_id',v_run,'reused',true,'run_status','PROCESSING');
  end if;

  if v_run is null then
    v_run:=gen_random_uuid();
    insert into public.requirement_ai_runs(
      id,agency_id,job_id,jd_source_id,idempotency_key,run_status,model_requested,
      prompt_version,schema_version,input_hash,attempt_count,started_by_user_id
    ) values(
      v_run,v_agency,v_job,p_source_id,p_idempotency_key,'PROCESSING',
      left(coalesce(p_model,'unknown'),120),left(coalesce(p_prompt_version,'unknown'),120),
      left(coalesce(p_schema_version,'unknown'),120),left(coalesce(p_input_hash,''),128),1,v_user
    );
  else
    update public.requirement_ai_runs
    set run_status='PROCESSING',attempt_count=coalesce(v_attempt,0)+1,error_code=null,error_detail=null,
        started_at=now(),completed_at=null
    where id=v_run and agency_id=v_agency;
  end if;

  update public.recruitment_jobs
  set requirement_state='AI_BRIEF_PENDING',recruiter_ready=false,updated_at=now()
  where id=v_job and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',v_job,'requirement.ai_brief_requested','AI JD analysis requested',
    jsonb_build_object('run_id',v_run,'source_id',p_source_id,'prompt_version',p_prompt_version,'schema_version',p_schema_version)
  );
  return jsonb_build_object('ok',true,'run_id',v_run,'reused',false,'run_status','PROCESSING');
end;
$fn$;

create or replace function public.xzrecruiter_complete_jd_ai_run(
  p_token text,p_run_id uuid,p_output jsonb,p_review_state text,
  p_model_resolved text,p_provider_response_id text,p_error_code text default null,p_error_detail text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_job uuid;v_source uuid;v_input_hash text;v_prompt text;v_schema text;v_existing_brief uuid;
  v_version integer;v_brief uuid;v_state text:=upper(coalesce(p_review_state,'NEEDS_REVIEW'));v_item jsonb;v_order integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select job_id,jd_source_id,input_hash,prompt_version,schema_version
  into v_job,v_source,v_input_hash,v_prompt,v_schema
  from public.requirement_ai_runs
  where id=p_run_id and agency_id=v_agency;
  if v_job is null then return jsonb_build_object('ok',false,'error','ai_run_not_found'); end if;

  select id into v_existing_brief
  from public.requirement_hiring_briefs
  where agency_id=v_agency and ai_run_id=p_run_id
  order by created_at desc limit 1;
  if v_existing_brief is not null then
    return jsonb_build_object('ok',true,'brief_id',v_existing_brief,'reused',true);
  end if;

  if p_error_code is not null then
    update public.requirement_ai_runs
    set run_status='FAILED',error_code=left(p_error_code,120),error_detail=left(coalesce(p_error_detail,''),1000),completed_at=now()
    where id=p_run_id and agency_id=v_agency;
    update public.recruitment_jobs
    set requirement_state=case when approved_hiring_brief_id is not null then 'CHANGE_PENDING_AM_CONFIRMATION' else 'JD_RECEIVED' end,
        recruiter_ready=false,updated_at=now()
    where id=v_job and agency_id=v_agency;
    perform private.xzrecruiter_log_activity(
      v_agency,v_user,'job',v_job,'requirement.ai_brief_failed','AI JD analysis failed',
      jsonb_build_object('run_id',p_run_id,'error_code',left(p_error_code,120))
    );
    return jsonb_build_object('ok',true,'run_status','FAILED');
  end if;

  if jsonb_typeof(p_output)<>'object' then return jsonb_build_object('ok',false,'error','invalid_ai_output'); end if;
  if v_state not in ('NEEDS_REVIEW','NEEDS_CLARIFICATION','READY_FOR_APPROVAL') then
    return jsonb_build_object('ok',false,'error','invalid_review_state');
  end if;

  update public.requirement_ai_runs
  set run_status='SUCCEEDED',model_resolved=left(coalesce(p_model_resolved,''),120),
      provider_response_id=left(coalesce(p_provider_response_id,''),200),review_state=v_state,
      output_json=p_output,completed_at=now()
  where id=p_run_id and agency_id=v_agency;

  select coalesce(max(version_number),0)+1 into v_version
  from public.requirement_hiring_briefs
  where agency_id=v_agency and job_id=v_job;

  v_brief:=gen_random_uuid();
  insert into public.requirement_hiring_briefs(
    id,agency_id,job_id,jd_source_id,ai_run_id,version_number,brief_status,
    structured_data,hiring_brief,search_blueprint,input_safety,model_name,prompt_version,
    schema_version,source_fingerprint,created_by_user_id
  ) values(
    v_brief,v_agency,v_job,v_source,p_run_id,v_version,v_state,
    coalesce(p_output->'fields','{}'::jsonb),coalesce(p_output->'hiringBrief','{}'::jsonb),
    coalesce(p_output->'searchBlueprint','{}'::jsonb),coalesce(p_output->'inputSafety','{}'::jsonb),
    left(coalesce(p_model_resolved,''),120),v_prompt,v_schema,v_input_hash,v_user
  );

  if jsonb_typeof(coalesce(p_output->'criteria','[]'::jsonb))='array' then
    for v_item in select value from jsonb_array_elements(coalesce(p_output->'criteria','[]'::jsonb)) loop
      v_order:=v_order+10;
      insert into public.requirement_criteria(
        agency_id,job_id,brief_id,criterion_kind,label,field_key,value_text,confidence,evidence,
        extraction_status,enforcement,requires_am_confirmation,sort_order
      ) values(
        v_agency,v_job,v_brief,
        case when upper(coalesce(v_item->>'kind','')) in ('HARD_REQUIREMENT','MUST_HAVE','NICE_TO_HAVE','RANKING_PREFERENCE')
          then upper(v_item->>'kind') else 'RANKING_PREFERENCE' end,
        left(coalesce(v_item->>'label','Criterion'),500),left(coalesce(v_item->>'field','other'),120),
        left(coalesce(v_item->>'value',''),1000),greatest(0,least(coalesce(nullif(v_item->>'confidence','')::numeric,0),1)),
        case when jsonb_typeof(v_item->'evidence')='array' then v_item->'evidence' else '[]'::jsonb end,
        case when coalesce(v_item->>'status','') in ('confirmed_from_jd','inferred_candidate','missing','ambiguous','conflicting')
          then v_item->>'status' else 'missing' end,
        case when upper(coalesce(v_item->>'enforcement','')) in ('ACTIVE','PROPOSED_REVIEW','INACTIVE')
          then upper(v_item->>'enforcement') else 'INACTIVE' end,
        coalesce((v_item->>'requiresAmConfirmation')::boolean,false),v_order
      );
    end loop;
  end if;

  if jsonb_typeof(coalesce(p_output->'clarifications','[]'::jsonb))='array' then
    for v_item in select value from jsonb_array_elements(coalesce(p_output->'clarifications','[]'::jsonb)) loop
      insert into public.requirement_clarifications(
        agency_id,job_id,brief_id,issue_type,field_key,question,evidence,blocking
      ) values(
        v_agency,v_job,v_brief,
        case when upper(coalesce(v_item->>'type','')) in ('MISSING','AMBIGUOUS','CONFLICTING')
          then upper(v_item->>'type') else 'MISSING' end,
        left(coalesce(v_item->>'field','other'),120),left(coalesce(v_item->>'question','Clarify requirement'),1000),
        case when jsonb_typeof(v_item->'evidence')='array' then v_item->'evidence' else '[]'::jsonb end,
        coalesce((v_item->>'blocking')::boolean,false)
      );
    end loop;
  end if;

  update public.recruitment_jobs
  set requirement_state='AM_REVIEW',recruiter_ready=false,requirement_contract_version='AI_JD_V1',updated_at=now()
  where id=v_job and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',v_job,'requirement.ai_brief_ready','AI Hiring Brief ready for AM review',
    jsonb_build_object('brief_id',v_brief,'version',v_version,'review_state',v_state,'run_id',p_run_id)
  );
  return jsonb_build_object('ok',true,'brief_id',v_brief,'version_number',v_version,'reused',false);
end;
$fn$;

create or replace function public.xzrecruiter_save_hiring_brief(
  p_token text,p_brief_id uuid,p_structured_data jsonb,p_hiring_brief jsonb,p_search_blueprint jsonb,
  p_criteria jsonb,p_clarifications jsonb,p_review_state text,p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_job uuid;v_before jsonb;
  v_state text:=upper(coalesce(p_review_state,'NEEDS_REVIEW'));v_item jsonb;v_order integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;
  if v_state not in ('NEEDS_REVIEW','NEEDS_CLARIFICATION','READY_FOR_APPROVAL','REVISION_REQUESTED') then
    return jsonb_build_object('ok',false,'error','invalid_review_state');
  end if;
  if jsonb_typeof(p_structured_data)<>'object' or jsonb_typeof(p_hiring_brief)<>'object' or jsonb_typeof(p_search_blueprint)<>'object' then
    return jsonb_build_object('ok',false,'error','invalid_brief_payload');
  end if;

  select job_id,jsonb_build_object(
    'structured_data',structured_data,'hiring_brief',hiring_brief,'search_blueprint',search_blueprint,'brief_status',brief_status
  ) into v_job,v_before
  from public.requirement_hiring_briefs
  where id=p_brief_id and agency_id=v_agency and brief_status not in ('APPROVED','SUPERSEDED');
  if v_job is null then return jsonb_build_object('ok',false,'error','brief_not_editable'); end if;

  v_before := v_before || jsonb_build_object(
    'criteria',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',c.id,'kind',c.criterion_kind,'label',c.label,'field',c.field_key,'value',c.value_text,
        'confidence',c.confidence,'evidence',c.evidence,'status',c.extraction_status,
        'enforcement',c.enforcement,'requiresAmConfirmation',c.requires_am_confirmation,'amConfirmed',c.am_confirmed
      ) order by c.sort_order,c.created_at)
      from public.requirement_criteria c
      where c.agency_id=v_agency and c.brief_id=p_brief_id
    ),'[]'::jsonb),
    'clarifications',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',q.id,'type',q.issue_type,'field',q.field_key,'question',q.question,'evidence',q.evidence,
        'blocking',q.blocking,'resolved',q.resolved,'resolution',q.resolution
      ) order by q.created_at)
      from public.requirement_clarifications q
      where q.agency_id=v_agency and q.brief_id=p_brief_id
    ),'[]'::jsonb)
  );

  update public.requirement_hiring_briefs
  set structured_data=p_structured_data,hiring_brief=p_hiring_brief,search_blueprint=p_search_blueprint,
      brief_status=v_state,updated_at=now()
  where id=p_brief_id and agency_id=v_agency;

  delete from public.requirement_criteria where agency_id=v_agency and brief_id=p_brief_id;
  if jsonb_typeof(coalesce(p_criteria,'[]'::jsonb))='array' then
    for v_item in select value from jsonb_array_elements(coalesce(p_criteria,'[]'::jsonb)) loop
      v_order:=v_order+10;
      insert into public.requirement_criteria(
        id,agency_id,job_id,brief_id,criterion_kind,label,field_key,value_text,confidence,evidence,
        extraction_status,enforcement,requires_am_confirmation,am_confirmed,am_confirmed_by_user_id,
        am_confirmed_at,sort_order
      ) values(
        coalesce(nullif(v_item->>'id','')::uuid,gen_random_uuid()),v_agency,v_job,p_brief_id,
        case when upper(coalesce(v_item->>'kind','')) in ('HARD_REQUIREMENT','MUST_HAVE','NICE_TO_HAVE','RANKING_PREFERENCE')
          then upper(v_item->>'kind') else 'RANKING_PREFERENCE' end,
        left(coalesce(v_item->>'label','Criterion'),500),left(coalesce(v_item->>'field','other'),120),
        left(coalesce(v_item->>'value',''),1000),greatest(0,least(coalesce(nullif(v_item->>'confidence','')::numeric,0),1)),
        case when jsonb_typeof(v_item->'evidence')='array' then v_item->'evidence' else '[]'::jsonb end,
        case when coalesce(v_item->>'status','') in ('confirmed_from_jd','inferred_candidate','missing','ambiguous','conflicting')
          then v_item->>'status' else 'missing' end,
        case when upper(coalesce(v_item->>'enforcement','')) in ('ACTIVE','PROPOSED_REVIEW','INACTIVE')
          then upper(v_item->>'enforcement') else 'INACTIVE' end,
        coalesce((v_item->>'requiresAmConfirmation')::boolean,false),
        coalesce((v_item->>'amConfirmed')::boolean,false),
        case when coalesce((v_item->>'amConfirmed')::boolean,false) then v_user else null end,
        case when coalesce((v_item->>'amConfirmed')::boolean,false) then now() else null end,
        v_order
      );
    end loop;
  end if;

  delete from public.requirement_clarifications where agency_id=v_agency and brief_id=p_brief_id;
  if jsonb_typeof(coalesce(p_clarifications,'[]'::jsonb))='array' then
    for v_item in select value from jsonb_array_elements(coalesce(p_clarifications,'[]'::jsonb)) loop
      insert into public.requirement_clarifications(
        id,agency_id,job_id,brief_id,issue_type,field_key,question,evidence,blocking,resolved,resolution,
        resolved_by_user_id,resolved_at
      ) values(
        coalesce(nullif(v_item->>'id','')::uuid,gen_random_uuid()),v_agency,v_job,p_brief_id,
        case when upper(coalesce(v_item->>'type','')) in ('MISSING','AMBIGUOUS','CONFLICTING')
          then upper(v_item->>'type') else 'MISSING' end,
        left(coalesce(v_item->>'field','other'),120),left(coalesce(v_item->>'question','Clarify requirement'),1000),
        case when jsonb_typeof(v_item->'evidence')='array' then v_item->'evidence' else '[]'::jsonb end,
        coalesce((v_item->>'blocking')::boolean,false),coalesce((v_item->>'resolved')::boolean,false),
        nullif(left(coalesce(v_item->>'resolution',''),2000),''),
        case when coalesce((v_item->>'resolved')::boolean,false) then v_user else null end,
        case when coalesce((v_item->>'resolved')::boolean,false) then now() else null end
      );
    end loop;
  end if;

  insert into public.requirement_brief_audit(
    agency_id,job_id,brief_id,actor_user_id,action,before_value,after_value,reason
  ) values(
    v_agency,v_job,p_brief_id,v_user,'requirement.brief_edited',v_before,
    jsonb_build_object(
      'structured_data',p_structured_data,'hiring_brief',p_hiring_brief,'search_blueprint',p_search_blueprint,
      'brief_status',v_state,'criteria',coalesce(p_criteria,'[]'::jsonb),
      'clarifications',coalesce(p_clarifications,'[]'::jsonb)
    ),
    nullif(left(coalesce(p_reason,''),1000),'')
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',v_job,'requirement.brief_edited','AM edited AI Hiring Brief',
    jsonb_build_object('brief_id',p_brief_id,'review_state',v_state,'reason',left(coalesce(p_reason,''),300))
  );
  return jsonb_build_object('ok',true,'brief_id',p_brief_id,'brief_status',v_state);
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','invalid_child_id');
end;
$fn$;

create or replace function public.xzrecruiter_request_hiring_brief_revision(
  p_token text,p_brief_id uuid,p_reason text
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_job uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;
  if btrim(coalesce(p_reason,''))='' then return jsonb_build_object('ok',false,'error','reason_required'); end if;

  select job_id into v_job
  from public.requirement_hiring_briefs
  where id=p_brief_id and agency_id=v_agency and brief_status not in ('APPROVED','SUPERSEDED');
  if v_job is null then return jsonb_build_object('ok',false,'error','brief_not_editable'); end if;

  update public.requirement_hiring_briefs
  set brief_status='REVISION_REQUESTED',updated_at=now()
  where id=p_brief_id and agency_id=v_agency;
  update public.recruitment_jobs
  set requirement_state='AI_BRIEF_PENDING',recruiter_ready=false,updated_at=now()
  where id=v_job and agency_id=v_agency;

  insert into public.requirement_brief_audit(
    agency_id,job_id,brief_id,actor_user_id,action,reason
  ) values(v_agency,v_job,p_brief_id,v_user,'requirement.am_returned',left(p_reason,1000));

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',v_job,'requirement.am_returned','AM requested Hiring Brief revision',
    jsonb_build_object('brief_id',p_brief_id,'reason',left(p_reason,300))
  );
  return jsonb_build_object('ok',true,'brief_status','REVISION_REQUESTED');
end;
$fn$;

create or replace function public.xzrecruiter_approve_hiring_brief(
  p_token text,p_brief_id uuid,p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_job uuid;v_data jsonb;v_brief jsonb;
  v_title text;v_work_model text;v_country text;v_openings integer;v_min numeric;v_max numeric;v_comp_min numeric;v_comp_max numeric;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select job_id,structured_data,hiring_brief into v_job,v_data,v_brief
  from public.requirement_hiring_briefs
  where id=p_brief_id and agency_id=v_agency and brief_status='READY_FOR_APPROVAL';
  if v_job is null then return jsonb_build_object('ok',false,'error','brief_not_ready_for_approval'); end if;

  if exists(
    select 1 from public.requirement_clarifications
    where agency_id=v_agency and brief_id=p_brief_id and blocking=true and resolved=false
  ) then return jsonb_build_object('ok',false,'error','blocking_clarifications'); end if;

  if exists(
    select 1 from public.requirement_criteria
    where agency_id=v_agency and brief_id=p_brief_id and criterion_kind='HARD_REQUIREMENT'
      and am_confirmed=false
  ) then return jsonb_build_object('ok',false,'error','hard_rules_need_confirmation'); end if;

  v_title=nullif(btrim(coalesce(v_data#>>'{jobTitle,value}','')),'');
  if v_title is null then return jsonb_build_object('ok',false,'error','job_title_required'); end if;

  update public.requirement_hiring_briefs
  set brief_status='SUPERSEDED',updated_at=now()
  where agency_id=v_agency and job_id=v_job and brief_status='APPROVED' and id<>p_brief_id;

  update public.requirement_hiring_briefs
  set brief_status='APPROVED',approved_by_user_id=v_user,approved_at=now(),
      approval_note=nullif(left(coalesce(p_note,''),1000),''),updated_at=now()
  where id=p_brief_id and agency_id=v_agency;

  v_work_model=upper(coalesce(v_data#>>'{workModel,value}',''));
  v_country=nullif(upper(btrim(coalesce(v_data#>>'{country,value}',''))),'');
  if v_country is not null and not exists(
    select 1 from public.global_country_profiles where country_code=v_country and active=true
  ) then
    v_country:=null;
  end if;
  begin v_openings=nullif(v_data#>>'{openings,value}','')::integer; exception when others then v_openings:=null; end;
  begin v_min=nullif(v_data#>>'{experience,value,minYears}','')::numeric; exception when others then v_min:=null; end;
  begin v_max=nullif(v_data#>>'{experience,value,maxYears}','')::numeric; exception when others then v_max:=null; end;
  begin v_comp_min=nullif(v_data#>>'{compensation,value,min}','')::numeric; exception when others then v_comp_min:=null; end;
  begin v_comp_max=nullif(v_data#>>'{compensation,value,max}','')::numeric; exception when others then v_comp_max:=null; end;

  update public.recruitment_jobs
  set
    title=v_title,
    job_function=coalesce(nullif(v_data#>>'{roleFamily,value}',''),job_function),
    seniority=coalesce(nullif(v_data#>>'{seniority,value}',''),seniority),
    openings=greatest(coalesce(v_openings,openings,1),1),
    employment_type=coalesce(nullif(upper(v_data#>>'{employmentType,value}'),''),employment_type),
    workplace_type=case when v_work_model in ('ONSITE','HYBRID','REMOTE','FLEXIBLE') then v_work_model else workplace_type end,
    remote_allowed=case when v_work_model='REMOTE' then true when v_work_model='ONSITE' then false else remote_allowed end,
    city=coalesce(nullif(v_data#>>'{city,value}',''),city),
    region=coalesce(nullif(v_data#>>'{state,value}',''),region),
    country_code=coalesce(v_country,country_code),
    experience_min=coalesce(v_min,experience_min),
    experience_max=coalesce(v_max,experience_max),
    skills_required=case when jsonb_typeof(v_data#>'{mandatorySkills,value}')='array' then v_data#>'{mandatorySkills,value}' else skills_required end,
    skills_preferred=case when jsonb_typeof(v_data#>'{preferredSkills,value}')='array' then v_data#>'{preferredSkills,value}' else skills_preferred end,
    mandatory_requirements=case when jsonb_typeof(v_brief->'mustHaveCriteria')='array' then v_brief->'mustHaveCriteria' else mandatory_requirements end,
    preferred_requirements=case when jsonb_typeof(v_brief->'niceToHaveCriteria')='array' then v_brief->'niceToHaveCriteria' else preferred_requirements end,
    description=coalesce(nullif(v_brief->>'roleSummary',''),description),
    work_authorization_requirements=case when jsonb_typeof(v_data#>'{workAuthorization,value}')='array' then v_data#>'{workAuthorization,value}' else work_authorization_requirements end,
    salary_min=coalesce(v_comp_min,salary_min),salary_max=coalesce(v_comp_max,salary_max),
    salary_currency=coalesce(nullif(upper(v_data#>>'{compensation,value,currency}'),''),salary_currency),
    salary_period=coalesce(nullif(upper(v_data#>>'{compensation,value,period}'),''),salary_period),
    approved_hiring_brief_id=p_brief_id,
    requirement_state='OPEN',
    recruiter_ready=true,
    requirement_contract_version='AI_JD_V1',
    status=case when status in ('DRAFT','PENDING_APPROVAL') then 'OPEN' else status end,
    updated_at=now()
  where id=v_job and agency_id=v_agency;

  insert into public.requirement_brief_audit(
    agency_id,job_id,brief_id,actor_user_id,action,after_value,reason
  ) values(
    v_agency,v_job,p_brief_id,v_user,'requirement.am_approved',
    jsonb_build_object('brief_status','APPROVED','requirement_state','OPEN','recruiter_ready',true),
    nullif(left(coalesce(p_note,''),1000),'')
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',v_job,'requirement.am_approved','AM approved Hiring Brief',
    jsonb_build_object('brief_id',p_brief_id)
  );
  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'job',v_job,'requirement.activated','Approved requirement became recruiter-ready',
    jsonb_build_object('brief_id',p_brief_id)
  );
  return jsonb_build_object('ok',true,'brief_status','APPROVED','requirement_state','OPEN','recruiter_ready',true);
end;
$fn$;

create or replace function public.xzrecruiter_requirement_context(
  p_token text,p_job_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_job jsonb;v_source jsonb;v_run jsonb;v_brief jsonb;
  v_brief_id uuid;v_criteria jsonb;v_clarifications jsonb;v_audit jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select jsonb_build_object(
    'id',j.id,'title',j.title,'status',j.status,'client_id',j.client_id,
    'requirement_state',j.requirement_state,'recruiter_ready',j.recruiter_ready,
    'requirement_contract_version',j.requirement_contract_version,'approved_hiring_brief_id',j.approved_hiring_brief_id
  ) into v_job
  from public.recruitment_jobs j
  where j.id=p_job_id and j.agency_id=v_agency and j.archived_at is null;
  if v_job is null then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  select to_jsonb(x) into v_source from (
    select id,version_number,source_type,source_status,original_text,extracted_text,filename,mime_type,size_bytes,
      storage_path,checksum_sha256,parsing_error,created_at,finalized_at
    from public.requirement_jd_sources
    where agency_id=v_agency and job_id=p_job_id
    order by version_number desc limit 1
  ) x;

  select to_jsonb(x) into v_run from (
    select id,jd_source_id,run_status,model_requested,model_resolved,provider_response_id,prompt_version,schema_version,
      attempt_count,review_state,error_code,error_detail,started_at,completed_at
    from public.requirement_ai_runs
    where agency_id=v_agency and job_id=p_job_id
    order by started_at desc limit 1
  ) x;

  select id,to_jsonb(x) into v_brief_id,v_brief from (
    select id,version_number,brief_status,structured_data,hiring_brief,search_blueprint,input_safety,
      model_name,prompt_version,schema_version,source_fingerprint,approved_by_user_id,approved_at,approval_note,created_at,updated_at
    from public.requirement_hiring_briefs
    where agency_id=v_agency and job_id=p_job_id
    order by version_number desc limit 1
  ) x;

  if v_brief_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'kind',c.criterion_kind,'label',c.label,'field',c.field_key,'value',c.value_text,
      'confidence',c.confidence,'evidence',c.evidence,'status',c.extraction_status,'enforcement',c.enforcement,
      'requiresAmConfirmation',c.requires_am_confirmation,'amConfirmed',c.am_confirmed,
      'amConfirmedAt',c.am_confirmed_at
    ) order by c.sort_order,c.created_at),'[]'::jsonb)
    into v_criteria
    from public.requirement_criteria c
    where c.agency_id=v_agency and c.brief_id=v_brief_id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',q.id,'type',q.issue_type,'field',q.field_key,'question',q.question,'evidence',q.evidence,
      'blocking',q.blocking,'resolved',q.resolved,'resolution',q.resolution,'resolvedAt',q.resolved_at
    ) order by q.created_at),'[]'::jsonb)
    into v_clarifications
    from public.requirement_clarifications q
    where q.agency_id=v_agency and q.brief_id=v_brief_id;

    select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb)
    into v_audit
    from (
      select id,actor_user_id,action,before_value,after_value,reason,occurred_at
      from public.requirement_brief_audit
      where agency_id=v_agency and brief_id=v_brief_id
      order by occurred_at desc limit 50
    ) x;
  end if;

  return jsonb_build_object(
    'ok',true,'job',v_job,'source',coalesce(v_source,'{}'::jsonb),'run',coalesce(v_run,'{}'::jsonb),
    'brief',coalesce(v_brief,'{}'::jsonb),'criteria',coalesce(v_criteria,'[]'::jsonb),
    'clarifications',coalesce(v_clarifications,'[]'::jsonb),'audit',coalesce(v_audit,'[]'::jsonb),
    'business_role',v_business_role,'can_review',v_business_role in ('OWNER','ADMIN','ACCOUNT_MANAGER')
  );
end;
$fn$;

create or replace function public.xzrecruiter_jd_document_access(
  p_token text,p_source_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_path text;v_name text;v_mime text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_requirement_am_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;

  select storage_path,filename,mime_type into v_path,v_name,v_mime
  from public.requirement_jd_sources
  where id=p_source_id and agency_id=v_agency and source_type='UPLOAD' and source_status='READY';
  if v_path is null then return jsonb_build_object('ok',false,'error','jd_document_not_found'); end if;
  return jsonb_build_object('ok',true,'storage_path',v_path,'filename',v_name,'mime_type',v_mime);
end;
$fn$;

-- SECURITY DEFINER functions are explicit API endpoints: revoke implicit PUBLIC execute, then grant intended browser roles.
revoke all on function public.xzrecruiter_prepare_jd_source(text,uuid,text,text,text,text,bigint,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_finalize_jd_source(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_jd_source_text(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_begin_jd_ai_run(text,uuid,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_complete_jd_ai_run(text,uuid,jsonb,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_save_hiring_brief(text,uuid,jsonb,jsonb,jsonb,jsonb,jsonb,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_request_hiring_brief_revision(text,uuid,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_approve_hiring_brief(text,uuid,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_requirement_context(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_jd_document_access(text,uuid) from public,anon,authenticated;

grant execute on function public.xzrecruiter_prepare_jd_source(text,uuid,text,text,text,text,bigint,text) to anon,authenticated;
grant execute on function public.xzrecruiter_finalize_jd_source(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_jd_source_text(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_begin_jd_ai_run(text,uuid,text,text,text,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_complete_jd_ai_run(text,uuid,jsonb,text,text,text,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_hiring_brief(text,uuid,jsonb,jsonb,jsonb,jsonb,jsonb,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_request_hiring_brief_revision(text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_approve_hiring_brief(text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_requirement_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_jd_document_access(text,uuid) to anon,authenticated;
