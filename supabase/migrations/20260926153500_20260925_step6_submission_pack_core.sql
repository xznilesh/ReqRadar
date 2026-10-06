-- XZ Recruiter locked roadmap Step 6: AI Submission Pack + Account Manager Quality Gate.
-- Additive hardening only. Reuses public.candidate_submissions as the canonical Submission aggregate.
-- Does not implement Step 7 multi-tenant foundation work or an external Client Portal.

alter table public.candidate_submissions
  add column if not exists latest_version_number integer not null default 0,
  add column if not exists version_lock bigint not null default 0,
  add column if not exists latest_source_fingerprint text,
  add column if not exists recruiter_context text,
  add column if not exists assigned_am_user_id uuid references public.users(id) on delete set null,
  add column if not exists hold_reason text,
  add column if not exists last_return_reason_code text,
  add column if not exists last_return_note text,
  add column if not exists client_contact_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists internal_commercial_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists client_commercial_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists client_submission_snapshot jsonb,
  add column if not exists client_submission_version_number integer,
  add column if not exists client_resume_document_id uuid references public.candidate_documents(id) on delete restrict,
  add column if not exists client_resume_version_number integer,
  add column if not exists submitted_by_user_id uuid references public.users(id) on delete set null;

create table if not exists public.candidate_submission_versions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  submission_id uuid not null references public.candidate_submissions(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete restrict,
  job_id uuid not null references public.recruitment_jobs(id) on delete restrict,
  client_id uuid references public.recruitment_clients(id) on delete restrict,
  version_number integer not null check (version_number > 0),
  source_fingerprint text not null,
  candidate_snapshot jsonb not null default '{}'::jsonb,
  requirement_snapshot jsonb not null default '{}'::jsonb,
  requirement_version integer,
  hiring_brief_id uuid,
  candidate_match_id uuid references public.candidate_match_runs(id) on delete restrict,
  candidate_profile_version_id uuid references public.candidate_profile_versions(id) on delete restrict,
  screening_snapshot jsonb not null default '{}'::jsonb,
  screening_version text,
  submission_pack jsonb not null default '{}'::jsonb,
  client_facing_pack jsonb not null default '{}'::jsonb,
  provenance_map jsonb not null default '{}'::jsonb,
  resume_document_id uuid not null references public.candidate_documents(id) on delete restrict,
  resume_version_number integer,
  resume_checksum text,
  internal_commercial_snapshot jsonb not null default '{}'::jsonb,
  client_commercial_snapshot jsonb not null default '{}'::jsonb,
  eligibility_snapshot jsonb not null default '{}'::jsonb,
  change_summary jsonb not null default '{}'::jsonb,
  generator_version text not null,
  generated_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(submission_id,version_number),
  unique(submission_id,source_fingerprint)
);

alter table public.candidate_submissions
  add column if not exists current_version_id uuid references public.candidate_submission_versions(id) on delete restrict;

create table if not exists public.candidate_submission_reviews (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  submission_id uuid not null references public.candidate_submissions(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  submission_version_id uuid not null references public.candidate_submission_versions(id) on delete restrict,
  submission_version_number integer not null,
  decision text not null check (decision in ('START_REVIEW','APPROVE','RETURN_TO_RECRUITER','ON_HOLD','DECLINE_INTERNAL','RESUBMITTED','CLIENT_SUBMITTED')),
  reason_code text,
  note text,
  checklist_snapshot jsonb not null default '{}'::jsonb,
  requirement_version integer,
  candidate_version text,
  resume_version_number integer,
  actor_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.candidate_submission_idempotency (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  submission_id uuid references public.candidate_submissions(id) on delete cascade,
  operation text not null,
  idempotency_key text not null,
  request_fingerprint text,
  response_json jsonb not null default '{}'::jsonb,
  actor_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(agency_id,operation,idempotency_key)
);

create index if not exists idx_xzr_submission_am_queue
  on public.candidate_submissions(agency_id,workflow_status,internal_submitted_at desc,updated_at desc);
create index if not exists idx_xzr_submission_candidate_requirement
  on public.candidate_submissions(agency_id,candidate_id,job_id,client_id,created_at desc);
create index if not exists idx_xzr_submission_versions_history
  on public.candidate_submission_versions(agency_id,submission_id,version_number desc);
create index if not exists idx_xzr_submission_reviews_history
  on public.candidate_submission_reviews(agency_id,submission_id,created_at desc);
create index if not exists idx_xzr_submission_idempotency_lookup
  on public.candidate_submission_idempotency(agency_id,submission_id,operation,created_at desc);

alter table public.candidate_submission_versions enable row level security;
alter table public.candidate_submission_reviews enable row level security;
alter table public.candidate_submission_idempotency enable row level security;

-- Direct browser reads/writes remain deny-by-default. Access is through guarded security-definer RPCs.
revoke all on public.candidate_submission_versions from public,anon,authenticated;
revoke all on public.candidate_submission_reviews from public,anon,authenticated;
revoke all on public.candidate_submission_idempotency from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_immutable_row()
returns trigger
language plpgsql
security invoker
set search_path='public','private','pg_temp'
as $fn$
begin
  raise exception 'immutable_step6_history';
end;
$fn$;

revoke all on function private.xzrecruiter_step6_immutable_row() from public,anon,authenticated;

drop trigger if exists xzr_submission_versions_immutable on public.candidate_submission_versions;
create trigger xzr_submission_versions_immutable
before update on public.candidate_submission_versions
for each row execute function private.xzrecruiter_step6_immutable_row();

drop trigger if exists xzr_submission_reviews_immutable on public.candidate_submission_reviews;
create trigger xzr_submission_reviews_immutable
before update on public.candidate_submission_reviews
for each row execute function private.xzrecruiter_step6_immutable_row();

-- One exact client-submission snapshot per canonical Submission aggregate. Later edits cannot rewrite it.
create or replace function private.xzrecruiter_step6_client_snapshot_immutable()
returns trigger
language plpgsql
security invoker
set search_path='public','private','pg_temp'
as $fn$
begin
  if old.workflow_status='CLIENT_SUBMITTED' and (
    old.client_submission_snapshot is distinct from new.client_submission_snapshot or
    old.client_submission_version_number is distinct from new.client_submission_version_number or
    old.client_resume_document_id is distinct from new.client_resume_document_id or
    old.client_resume_version_number is distinct from new.client_resume_version_number or
    old.client_commercial_snapshot is distinct from new.client_commercial_snapshot or
    old.client_submitted_at is distinct from new.client_submitted_at or
    old.submitted_by_user_id is distinct from new.submitted_by_user_id
  ) then
    raise exception 'client_submission_snapshot_immutable';
  end if;
  return new;
end;
$fn$;

revoke all on function private.xzrecruiter_step6_client_snapshot_immutable() from public,anon,authenticated;

drop trigger if exists xzr_client_submission_snapshot_immutable on public.candidate_submissions;
create trigger xzr_client_submission_snapshot_immutable
before update on public.candidate_submissions
for each row execute function private.xzrecruiter_step6_client_snapshot_immutable();
