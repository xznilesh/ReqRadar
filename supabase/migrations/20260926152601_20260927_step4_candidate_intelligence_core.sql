-- XZ Recruiter locked roadmap Step 4: AI Candidate Intelligence Engine core.
-- Additive to completed Steps 1-3. No Step-5 screening implementation.

alter table public.candidate_parse_runs
  add column if not exists extracted_text text,
  add column if not exists model_version text,
  add column if not exists prompt_version text,
  add column if not exists schema_version text,
  add column if not exists input_hash text,
  add column if not exists latency_ms integer,
  add column if not exists retry_count integer not null default 0,
  add column if not exists provider_usage jsonb not null default '{}'::jsonb;

create table if not exists public.candidate_profile_versions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  document_id uuid references public.candidate_documents(id) on delete set null,
  parse_run_id uuid references public.candidate_parse_runs(id) on delete set null,
  version_number integer not null,
  profile_status text not null default 'READY' check (profile_status in ('READY','PARTIAL','FAILED','SUPERSEDED')),
  profile_json jsonb not null default '{}'::jsonb,
  profile_hash text not null,
  source_fingerprint text not null,
  parser_version text,
  model_name text,
  prompt_version text not null,
  schema_version text not null,
  profile_schema_version text not null default 'xz-candidate-profile-v2',
  match_schema_version text not null default 'xz-candidate-match-v2',
  input_hash text not null,
  is_current boolean not null default true,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(agency_id,candidate_id,version_number)
);
create unique index if not exists uq_xzr_candidate_profile_hash
  on public.candidate_profile_versions(agency_id,candidate_id,profile_hash);
create unique index if not exists uq_xzr_candidate_profile_current
  on public.candidate_profile_versions(agency_id,candidate_id)
  where is_current=true;
create index if not exists idx_xzr_candidate_profile_created
  on public.candidate_profile_versions(agency_id,candidate_id,created_at desc);

alter table public.candidates
  add column if not exists current_intelligence_profile_id uuid references public.candidate_profile_versions(id) on delete set null;

create table if not exists public.candidate_profile_skills (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  profile_version_id uuid not null references public.candidate_profile_versions(id) on delete cascade,
  original_value text not null,
  normalized_value text not null,
  confidence numeric not null default 0 check (confidence>=0 and confidence<=1),
  estimated_years numeric,
  evidence jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique(profile_version_id,normalized_value)
);
create index if not exists idx_xzr_candidate_profile_skills_lookup
  on public.candidate_profile_skills(agency_id,normalized_value,candidate_id);
create index if not exists idx_xzr_candidate_profile_skills_candidate
  on public.candidate_profile_skills(agency_id,candidate_id,profile_version_id);

create table if not exists public.candidate_scoring_configs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  version_key text not null,
  weights jsonb not null,
  active boolean not null default true,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  retired_at timestamptz,
  unique(agency_id,version_key)
);
create unique index if not exists uq_xzr_candidate_scoring_active
  on public.candidate_scoring_configs(agency_id)
  where active=true;

create table if not exists public.candidate_intelligence_jobs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  brief_id uuid not null references public.requirement_hiring_briefs(id) on delete restrict,
  parse_run_id uuid references public.candidate_parse_runs(id) on delete set null,
  candidate_updated_at_snapshot timestamptz not null,
  parse_run_updated_at_snapshot timestamptz,
  brief_source_fingerprint text not null,
  idempotency_key text not null,
  input_hash text not null,
  run_status text not null default 'PROCESSING' check (run_status in ('PROCESSING','SUCCEEDED','FAILED')),
  model_requested text,
  model_resolved text,
  prompt_version text not null,
  schema_version text not null,
  scoring_version text not null,
  attempt_count integer not null default 1,
  retry_count integer not null default 0,
  latency_ms integer,
  provider_response_id text,
  provider_usage jsonb not null default '{}'::jsonb,
  error_code text,
  error_detail text,
  started_by_user_id uuid not null references public.users(id) on delete restrict,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(agency_id,idempotency_key)
);
create index if not exists idx_xzr_candidate_intelligence_jobs
  on public.candidate_intelligence_jobs(agency_id,job_id,candidate_id,started_at desc);

create table if not exists public.candidate_match_runs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  intelligence_job_id uuid not null references public.candidate_intelligence_jobs(id) on delete restrict,
  brief_id uuid not null references public.requirement_hiring_briefs(id) on delete restrict,
  brief_version integer not null,
  profile_version_id uuid not null references public.candidate_profile_versions(id) on delete restrict,
  scoring_config_id uuid references public.candidate_scoring_configs(id) on delete set null,
  scoring_version text not null,
  model_name text,
  prompt_version text not null,
  schema_version text not null,
  input_hash text not null,
  run_status text not null default 'SUCCEEDED' check (run_status in ('SUCCEEDED','FAILED','STALE')),
  score numeric check (score is null or (score>=0 and score<=100)),
  match_band text check (match_band is null or match_band in ('Strong Match','Possible Match','Low Match','Mandatory Requirement Missing')),
  confidence numeric check (confidence is null or (confidence>=0 and confidence<=1)),
  coverage numeric check (coverage is null or (coverage>=0 and coverage<=1)),
  hard_rule_status text check (hard_rule_status is null or hard_rule_status in ('PASS','WARN','FAIL','UNKNOWN')),
  component_scores jsonb not null default '{}'::jsonb,
  hard_rule_results jsonb not null default '[]'::jsonb,
  requirement_results jsonb not null default '[]'::jsonb,
  strengths jsonb not null default '[]'::jsonb,
  gaps jsonb not null default '[]'::jsonb,
  uncertainties jsonb not null default '[]'::jsonb,
  evidence_meta jsonb not null default '{}'::jsonb,
  recommendation text,
  generated_at timestamptz not null default now(),
  stale_at timestamptz,
  stale_reason text,
  unique(agency_id,intelligence_job_id)
);
create index if not exists idx_xzr_candidate_match_current
  on public.candidate_match_runs(agency_id,job_id,candidate_id,generated_at desc)
  where run_status='SUCCEEDED';
create index if not exists idx_xzr_candidate_match_profile
  on public.candidate_match_runs(agency_id,profile_version_id,brief_id);

alter table public.applications
  add column if not exists current_candidate_match_id uuid references public.candidate_match_runs(id) on delete set null,
  add column if not exists intelligence_review_state text not null default 'NOT_REVIEWED'
    check (intelligence_review_state in ('NOT_REVIEWED','REVIEWED','PROCEED_TO_HUMAN_SCREENING','HOLD_FOR_CLARIFICATION')),
  add column if not exists intelligence_reviewed_at timestamptz;

create table if not exists public.candidate_duplicate_signals (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  compared_candidate_id uuid not null references public.candidates(id) on delete cascade,
  profile_version_id uuid not null references public.candidate_profile_versions(id) on delete cascade,
  duplicate_status text not null check (duplicate_status in ('exact_duplicate','likely_duplicate','possible_duplicate','no_duplicate_signal')),
  score integer not null check (score>=0 and score<=100),
  signals jsonb not null default '[]'::jsonb,
  algorithm_version text not null,
  created_at timestamptz not null default now(),
  check(candidate_id<>compared_candidate_id),
  unique(profile_version_id,compared_candidate_id)
);
create index if not exists idx_xzr_candidate_duplicate_source
  on public.candidate_duplicate_signals(agency_id,candidate_id,created_at desc);
create index if not exists idx_xzr_candidate_duplicate_compare
  on public.candidate_duplicate_signals(agency_id,compared_candidate_id,created_at desc);
create index if not exists idx_xzr_candidate_documents_checksum
  on public.candidate_documents(agency_id,checksum,candidate_id)
  where archived_at is null and checksum is not null;
create index if not exists idx_xzr_applications_source_reference
  on public.applications(agency_id,lower(source_reference),candidate_id)
  where archived_at is null and source_reference is not null;

create table if not exists public.candidate_intelligence_reviews (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  match_run_id uuid not null references public.candidate_match_runs(id) on delete restrict,
  action text not null check (action in ('ACKNOWLEDGE','PROCEED_TO_HUMAN_SCREENING','HOLD_FOR_CLARIFICATION')),
  ai_recommendation text,
  recruiter_override boolean not null default false,
  reason text,
  reviewer_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index if not exists idx_xzr_candidate_intelligence_reviews
  on public.candidate_intelligence_reviews(agency_id,application_id,created_at desc);

-- RPC-only data surfaces. RLS is defense-in-depth; browser roles receive no direct table policy.
alter table public.candidate_profile_versions enable row level security;
alter table public.candidate_profile_skills enable row level security;
alter table public.candidate_scoring_configs enable row level security;
alter table public.candidate_intelligence_jobs enable row level security;
alter table public.candidate_match_runs enable row level security;
alter table public.candidate_duplicate_signals enable row level security;
alter table public.candidate_intelligence_reviews enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'candidate_profile_versions','candidate_profile_skills','candidate_scoring_configs',
    'candidate_intelligence_jobs','candidate_match_runs','candidate_duplicate_signals','candidate_intelligence_reviews'
  ] loop
    execute format('drop policy if exists xzrecruiter_data_api_deny on public.%I',t);
    execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon,authenticated using(false) with check(false)',t);
  end loop;
end $$;

create or replace function private.xzrecruiter_normalize_candidate_skill(p_value text)
returns text
language sql immutable security invoker
set search_path='public','private','pg_temp'
as $$
  select case lower(regexp_replace(btrim(coalesce(p_value,'')),'[_[:space:]]+',' ','g'))
    when 'node' then 'node.js' when 'nodejs' then 'node.js' when 'node js' then 'node.js'
    when 'js' then 'javascript' when 'ts' then 'typescript'
    when 'reactjs' then 'react' when 'react.js' then 'react'
    when 'nextjs' then 'next.js' when 'next js' then 'next.js'
    when 'postgres' then 'postgresql'
    when 'springboot' then 'spring boot' when 'spring-boot' then 'spring boot'
    when 'dotnet' then '.net' when 'k8s' then 'kubernetes'
    when 'gcp' then 'google cloud platform' when 'google cloud' then 'google cloud platform'
    when 'aws' then 'amazon web services' when 'powerbi' then 'power bi'
    when 'lwc' then 'lightning web components'
    else lower(regexp_replace(btrim(coalesce(p_value,'')),'[_[:space:]]+',' ','g'))
  end;
$$;
revoke all on function private.xzrecruiter_normalize_candidate_skill(text) from public,anon,authenticated;

create or replace function private.xzrecruiter_candidate_intelligence_access(
  p_agency_id uuid,p_user_id uuid,p_business_role text,p_job_id uuid,p_candidate_id uuid
) returns boolean
language sql stable security invoker
set search_path='public','private','pg_temp'
as $$
  select case
    when upper(coalesce(p_business_role,'')) in ('OWNER','ADMIN','RECRUITMENT_MANAGER','ACCOUNT_MANAGER') then
      exists(
        select 1 from public.applications a
        join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency_id
        where a.agency_id=p_agency_id and a.job_id=p_job_id and a.candidate_id=p_candidate_id
          and a.archived_at is null and j.archived_at is null
          and j.recruiter_ready=true and j.approved_hiring_brief_id is not null
      )
    when upper(coalesce(p_business_role,''))='RECRUITER' then
      exists(
        select 1 from public.applications a
        join public.requirement_recruiter_assignments ra
          on ra.agency_id=a.agency_id and ra.job_id=a.job_id
          and ra.recruiter_user_id=p_user_id and ra.assignment_status='ACTIVE'
        join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency_id
        where a.agency_id=p_agency_id and a.job_id=p_job_id and a.candidate_id=p_candidate_id
          and a.archived_at is null and a.owner_user_id=p_user_id
          and j.archived_at is null and j.recruiter_ready=true
          and j.requirement_state='OPEN' and j.approved_hiring_brief_id is not null
      )
    else false
  end;
$$;
revoke all on function private.xzrecruiter_candidate_intelligence_access(uuid,uuid,text,uuid,uuid) from public,anon,authenticated;
