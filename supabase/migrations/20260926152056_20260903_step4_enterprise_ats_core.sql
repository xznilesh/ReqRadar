-- XZ Recruiter Step 4: global enterprise ATS core.
-- Additive only. Step 1 security, Step 2 globalization and Step 3 configuration remain authoritative.

-- Candidate 360 extensions.
alter table public.candidates add column if not exists preferred_name text;
alter table public.candidates add column if not exists headline text;
alter table public.candidates add column if not exists secondary_email text;
alter table public.candidates add column if not exists secondary_phone text;
alter table public.candidates add column if not exists region text;
alter table public.candidates add column if not exists city text;
alter table public.candidates add column if not exists preferred_contact text;
alter table public.candidates add column if not exists relevant_experience_years numeric;
alter table public.candidates add column if not exists job_function text;
alter table public.candidates add column if not exists seniority text;
alter table public.candidates add column if not exists education jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists certifications jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists languages jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists availability_status text not null default 'UNKNOWN';
alter table public.candidates add column if not exists employment_preference text;
alter table public.candidates add column if not exists workplace_preference text;
alter table public.candidates add column if not exists relocation_preference text;
alter table public.candidates add column if not exists desired_locations jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists work_authorization_summary jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists owner_user_id uuid references public.users(id) on delete set null;
alter table public.candidates add column if not exists team_id uuid references public.workspace_teams(id) on delete set null;
alter table public.candidates add column if not exists tags jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists consent_status text not null default 'UNKNOWN';
alter table public.candidates add column if not exists consent_source text;
alter table public.candidates add column if not exists consent_at timestamptz;
alter table public.candidates add column if not exists retention_status text not null default 'ACTIVE';
alter table public.candidates add column if not exists profile_photo_path text;
alter table public.candidates add column if not exists archived_at timestamptz;
alter table public.candidates add column if not exists archived_by_user_id uuid references public.users(id) on delete set null;
alter table public.candidates add column if not exists merged_into_candidate_id uuid references public.candidates(id) on delete set null;
alter table public.candidates add column if not exists updated_by_user_id uuid references public.users(id) on delete set null;

-- Operational Job 360 extensions. canonical_jobs remains intelligence/source normalization; recruitment_jobs is the agency ATS requisition.
alter table public.recruitment_jobs add column if not exists internal_ref text;
alter table public.recruitment_jobs add column if not exists company_id uuid references public.companies(id) on delete set null;
alter table public.recruitment_jobs add column if not exists hiring_manager_name text;
alter table public.recruitment_jobs add column if not exists hiring_manager_email text;
alter table public.recruitment_jobs add column if not exists department text;
alter table public.recruitment_jobs add column if not exists job_function text;
alter table public.recruitment_jobs add column if not exists industry text;
alter table public.recruitment_jobs add column if not exists seniority text;
alter table public.recruitment_jobs add column if not exists skills_required jsonb not null default '[]'::jsonb;
alter table public.recruitment_jobs add column if not exists skills_preferred jsonb not null default '[]'::jsonb;
alter table public.recruitment_jobs add column if not exists experience_min numeric;
alter table public.recruitment_jobs add column if not exists experience_max numeric;
alter table public.recruitment_jobs add column if not exists openings integer not null default 1;
alter table public.recruitment_jobs add column if not exists region text;
alter table public.recruitment_jobs add column if not exists city text;
alter table public.recruitment_jobs add column if not exists contract_duration text;
alter table public.recruitment_jobs add column if not exists ote numeric;
alter table public.recruitment_jobs add column if not exists bonus numeric;
alter table public.recruitment_jobs add column if not exists commission numeric;
alter table public.recruitment_jobs add column if not exists work_authorization_requirements jsonb not null default '[]'::jsonb;
alter table public.recruitment_jobs add column if not exists sponsorship_available boolean;
alter table public.recruitment_jobs add column if not exists benefits text;
alter table public.recruitment_jobs add column if not exists screening_questions jsonb not null default '[]'::jsonb;
alter table public.recruitment_jobs add column if not exists priority text not null default 'NORMAL';
alter table public.recruitment_jobs add column if not exists sla_hours integer;
alter table public.recruitment_jobs add column if not exists opened_at timestamptz;
alter table public.recruitment_jobs add column if not exists target_fill_date date;
alter table public.recruitment_jobs add column if not exists closed_at timestamptz;
alter table public.recruitment_jobs add column if not exists close_reason text;
alter table public.recruitment_jobs add column if not exists pipeline_id uuid references public.recruitment_pipelines(id) on delete set null;
alter table public.recruitment_jobs add column if not exists tags jsonb not null default '[]'::jsonb;
alter table public.recruitment_jobs add column if not exists public_visibility text not null default 'PRIVATE';
alter table public.recruitment_jobs add column if not exists public_slug text;
alter table public.recruitment_jobs add column if not exists application_form_config jsonb not null default '{}'::jsonb;
alter table public.recruitment_jobs add column if not exists archived_at timestamptz;
alter table public.recruitment_jobs add column if not exists archived_by_user_id uuid references public.users(id) on delete set null;

-- One candidate can have independent states for many jobs.
alter table public.applications add column if not exists client_id uuid references public.recruitment_clients(id) on delete set null;
alter table public.applications add column if not exists pipeline_id uuid references public.recruitment_pipelines(id) on delete set null;
alter table public.applications add column if not exists stage_id uuid references public.pipeline_stages(id) on delete set null;
alter table public.applications add column if not exists stage_entered_at timestamptz not null default now();
alter table public.applications add column if not exists rejection_reason text;
alter table public.applications add column if not exists withdrawal_reason text;
alter table public.applications add column if not exists submitted_at timestamptz;
alter table public.applications add column if not exists last_activity_at timestamptz not null default now();
alter table public.applications add column if not exists archived_at timestamptz;
alter table public.applications add column if not exists metadata jsonb not null default '{}'::jsonb;

-- Interview enhancements for global scheduling and structured feedback.
alter table public.interviews add column if not exists end_at timestamptz;
alter table public.interviews add column if not exists candidate_timezone text;
alter table public.interviews add column if not exists recruiter_timezone text;
alter table public.interviews add column if not exists meeting_url text;
alter table public.interviews add column if not exists instructions text;
alter table public.interviews add column if not exists interviewers jsonb not null default '[]'::jsonb;
alter table public.interviews add column if not exists cancelled_at timestamptz;
alter table public.interviews add column if not exists cancellation_reason text;
alter table public.interviews add column if not exists scorecard_template_id uuid;

-- Offer versioning and lifecycle.
alter table public.offers add column if not exists title text;
alter table public.offers add column if not exists location text;
alter table public.offers add column if not exists salary_period text;
alter table public.offers add column if not exists bonus numeric;
alter table public.offers add column if not exists commission numeric;
alter table public.offers add column if not exists ote numeric;
alter table public.offers add column if not exists equity text;
alter table public.offers add column if not exists allowances jsonb not null default '[]'::jsonb;
alter table public.offers add column if not exists expires_at timestamptz;
alter table public.offers add column if not exists employment_type text;
alter table public.offers add column if not exists version_number integer not null default 1;
alter table public.offers add column if not exists parent_offer_id uuid references public.offers(id) on delete set null;
alter table public.offers add column if not exists sent_at timestamptz;
alter table public.offers add column if not exists viewed_at timestamptz;
alter table public.offers add column if not exists accepted_at timestamptz;
alter table public.offers add column if not exists declined_at timestamptz;
alter table public.offers add column if not exists withdrawn_at timestamptz;
alter table public.offers add column if not exists metadata jsonb not null default '{}'::jsonb;

-- Durable placement entity expansion.
alter table public.placements add column if not exists candidate_id uuid references public.candidates(id) on delete set null;
alter table public.placements add column if not exists job_id uuid references public.recruitment_jobs(id) on delete set null;
alter table public.placements add column if not exists client_id uuid references public.recruitment_clients(id) on delete set null;
alter table public.placements add column if not exists recruiter_user_id uuid references public.users(id) on delete set null;
alter table public.placements add column if not exists salary numeric;
alter table public.placements add column if not exists salary_currency text;
alter table public.placements add column if not exists status text not null default 'PLANNED';
alter table public.placements add column if not exists fee_type text;
alter table public.placements add column if not exists fee_percent numeric;
alter table public.placements add column if not exists guarantee_end_date date;
alter table public.placements add column if not exists commission_amount numeric;
alter table public.placements add column if not exists completed_at timestamptz;
alter table public.placements add column if not exists cancelled_at timestamptz;
alter table public.placements add column if not exists metadata jsonb not null default '{}'::jsonb;

create table if not exists public.candidate_documents (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  document_type text not null default 'RESUME',
  version_number integer not null default 1,
  filename text not null,
  storage_path text not null,
  mime_type text,
  size_bytes bigint,
  checksum text,
  is_primary boolean not null default false,
  uploaded_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  unique(agency_id,candidate_id,document_type,version_number)
);

create table if not exists public.candidate_parse_runs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  document_id uuid references public.candidate_documents(id) on delete set null,
  provider text not null default 'LOCAL',
  parser_version text not null,
  status text not null default 'PENDING',
  extracted_data jsonb not null default '{}'::jsonb,
  field_confidence jsonb not null default '{}'::jsonb,
  field_evidence jsonb not null default '{}'::jsonb,
  review_state text not null default 'NEEDS_REVIEW',
  reviewed_by_user_id uuid references public.users(id) on delete set null,
  reviewed_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.candidate_merge_events (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  surviving_candidate_id uuid not null references public.candidates(id) on delete cascade,
  merged_candidate_id uuid not null references public.candidates(id) on delete restrict,
  field_resolution jsonb not null default '{}'::jsonb,
  merged_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(agency_id,merged_candidate_id)
);

create table if not exists public.workspace_tags (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  normalized_name text not null,
  display_name text not null,
  active boolean not null default true,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agency_id,normalized_name)
);

create table if not exists public.talent_pools (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  description text,
  visibility text not null default 'TEAM',
  rule_config jsonb not null default '{}'::jsonb,
  owner_user_id uuid references public.users(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agency_id,name)
);

create table if not exists public.talent_pool_members (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  pool_id uuid not null references public.talent_pools(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  added_by_user_id uuid references public.users(id) on delete set null,
  source text not null default 'MANUAL',
  created_at timestamptz not null default now(),
  primary key(pool_id,candidate_id)
);

create table if not exists public.recruitment_activity_events (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  actor_user_id uuid references public.users(id) on delete set null,
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  summary text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create table if not exists public.application_stage_history (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  from_stage_id uuid references public.pipeline_stages(id) on delete set null,
  to_stage_id uuid references public.pipeline_stages(id) on delete set null,
  from_stage text,
  to_stage text not null,
  reason text,
  changed_by_user_id uuid references public.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create table if not exists public.application_screening_answers (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  question_key text not null,
  question_text text not null,
  answer jsonb,
  score numeric,
  knockout boolean not null default false,
  reviewed_by_user_id uuid references public.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(application_id,question_key)
);

create table if not exists public.candidate_submissions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  client_id uuid references public.recruitment_clients(id) on delete set null,
  summary text,
  salary_expectation numeric,
  salary_currency text,
  availability text,
  notice_period_days integer,
  document_ids jsonb not null default '[]'::jsonb,
  status text not null default 'DRAFT',
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  submitted_at timestamptz,
  client_viewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.scorecard_templates (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  module text not null default 'INTERVIEW',
  rating_min integer not null default 1,
  rating_max integer not null default 5,
  hide_peer_feedback_until_submit boolean not null default true,
  active boolean not null default true,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agency_id,name)
);

create table if not exists public.scorecard_criteria (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  template_id uuid not null references public.scorecard_templates(id) on delete cascade,
  code text not null,
  label text not null,
  description text,
  weight numeric not null default 1,
  sort_order integer not null default 100,
  active boolean not null default true,
  unique(template_id,code)
);

create table if not exists public.interview_scorecards (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  interview_id uuid not null references public.interviews(id) on delete cascade,
  template_id uuid references public.scorecard_templates(id) on delete set null,
  author_user_id uuid not null references public.users(id) on delete cascade,
  recommendation text,
  comments text,
  status text not null default 'DRAFT',
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(interview_id,author_user_id)
);

create table if not exists public.interview_scorecard_ratings (
  scorecard_id uuid not null references public.interview_scorecards(id) on delete cascade,
  criterion_id uuid not null references public.scorecard_criteria(id) on delete cascade,
  rating numeric,
  comment text,
  primary key(scorecard_id,criterion_id)
);

alter table public.interviews
  drop constraint if exists interviews_scorecard_template_fk;
alter table public.interviews
  add constraint interviews_scorecard_template_fk foreign key(scorecard_template_id) references public.scorecard_templates(id) on delete set null;

create table if not exists public.offer_approvals (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  offer_id uuid not null references public.offers(id) on delete cascade,
  step_order integer not null default 1,
  approver_user_id uuid references public.users(id) on delete set null,
  required_role text,
  status text not null default 'PENDING',
  decision_note text,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique(offer_id,step_order)
);

create table if not exists public.recruitment_attachments (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  filename text not null,
  storage_path text not null,
  mime_type text,
  size_bytes bigint,
  uploaded_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

create table if not exists public.candidate_portal_sessions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

-- Integrity checks and indexes.
alter table public.candidates drop constraint if exists candidates_availability_status_check;
alter table public.candidates add constraint candidates_availability_status_check check (availability_status in ('UNKNOWN','AVAILABLE_NOW','AVAILABLE_SOON','NOT_AVAILABLE','PASSIVE'));
alter table public.candidates drop constraint if exists candidates_consent_status_check;
alter table public.candidates add constraint candidates_consent_status_check check (consent_status in ('UNKNOWN','PENDING','GRANTED','WITHDRAWN','NOT_REQUIRED'));
alter table public.recruitment_jobs drop constraint if exists recruitment_jobs_priority_check;
alter table public.recruitment_jobs add constraint recruitment_jobs_priority_check check (priority in ('LOW','NORMAL','HIGH','URGENT'));
alter table public.recruitment_jobs drop constraint if exists recruitment_jobs_public_visibility_check;
alter table public.recruitment_jobs add constraint recruitment_jobs_public_visibility_check check (public_visibility in ('PRIVATE','INTERNAL','PUBLIC'));
alter table public.placements drop constraint if exists placements_status_check;
alter table public.placements add constraint placements_status_check check (status in ('PLANNED','CONFIRMED','STARTED','COMPLETED','CANCELLED','REPLACEMENT_REQUIRED'));

create unique index if not exists uq_xzrecruiter_public_job_slug on public.recruitment_jobs(public_slug) where public_slug is not null;
create index if not exists idx_xzrecruiter_candidates_search on public.candidates(agency_id,archived_at,updated_at desc);
create index if not exists idx_xzrecruiter_candidates_owner on public.candidates(agency_id,owner_user_id,availability_status,updated_at desc);
create index if not exists idx_xzrecruiter_candidates_email on public.candidates(agency_id,lower(email)) where email is not null;
create index if not exists idx_xzrecruiter_candidates_phone on public.candidates(agency_id,phone) where phone is not null;
create index if not exists idx_xzrecruiter_jobs_search on public.recruitment_jobs(agency_id,archived_at,status,updated_at desc);
create index if not exists idx_xzrecruiter_jobs_owner on public.recruitment_jobs(agency_id,owner_user_id,status,priority,updated_at desc);
create index if not exists idx_xzrecruiter_applications_stage on public.applications(agency_id,job_id,stage_id,stage_entered_at desc);
create index if not exists idx_xzrecruiter_applications_candidate on public.applications(agency_id,candidate_id,updated_at desc);
create index if not exists idx_xzrecruiter_interviews_schedule on public.interviews(agency_id,scheduled_at,status);
create index if not exists idx_xzrecruiter_offers_application on public.offers(agency_id,application_id,version_number desc);
create index if not exists idx_xzrecruiter_placements_status on public.placements(agency_id,status,start_date);
create index if not exists idx_xzrecruiter_activity_entity on public.recruitment_activity_events(agency_id,entity_type,entity_id,occurred_at desc);
create index if not exists idx_xzrecruiter_documents_candidate on public.candidate_documents(agency_id,candidate_id,document_type,version_number desc);
create index if not exists idx_xzrecruiter_parse_runs_candidate on public.candidate_parse_runs(agency_id,candidate_id,created_at desc);
create index if not exists idx_xzrecruiter_talent_pool_members_candidate on public.talent_pool_members(agency_id,candidate_id);

-- RLS defense in depth. Session-aware RPCs mediate browser access.
do $do$
declare t text;
begin
  foreach t in array array[
    'candidate_documents','candidate_parse_runs','candidate_merge_events','workspace_tags','talent_pools','talent_pool_members',
    'recruitment_activity_events','application_stage_history','application_screening_answers','candidate_submissions',
    'scorecard_templates','scorecard_criteria','interview_scorecards','interview_scorecard_ratings','offer_approvals',
    'recruitment_attachments','candidate_portal_sessions'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',t);
    end if;
  end loop;
end $do$;

-- Existing ATS tables also remain direct-browser deny-by-default.
do $do$
declare t text;
begin
  foreach t in array array['candidates','recruitment_jobs','applications','interviews','interview_feedback','offers','placements'] loop
    execute format('alter table public.%I enable row level security',t);
    if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',t);
    end if;
  end loop;
end $do$;
