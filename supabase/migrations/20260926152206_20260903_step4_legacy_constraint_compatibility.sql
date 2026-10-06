-- XZ Recruiter Step 4: make legacy ATS checks compatible with configurable enterprise workflows.
-- Additive data model; only narrow legacy CHECK constraints are replaced.

-- Application stages are workspace-configurable from Step 3, so a fixed global stage list is invalid.
alter table public.applications drop constraint if exists applications_stage_check;
alter table public.applications drop constraint if exists applications_stage_nonempty_check;
alter table public.applications add constraint applications_stage_nonempty_check check (length(btrim(stage)) > 0);

-- Expanded requisition lifecycle.
alter table public.recruitment_jobs drop constraint if exists recruitment_jobs_status_check;
alter table public.recruitment_jobs add constraint recruitment_jobs_status_check
  check (status in ('DRAFT','PENDING_APPROVAL','OPEN','ON_HOLD','FILLED','CLOSED','CANCELLED','ARCHIVED'));

-- Expanded offer lifecycle/versioning.
alter table public.offers drop constraint if exists offers_status_check;
alter table public.offers add constraint offers_status_check
  check (status in ('DRAFT','PENDING_APPROVAL','APPROVED','SENT','VIEWED','ACCEPTED','DECLINED','EXPIRED','WITHDRAWN'));

-- Expanded interview types and lifecycle while preserving legacy CLIENT interviews.
alter table public.interviews drop constraint if exists interviews_interview_type_check;
alter table public.interviews add constraint interviews_interview_type_check
  check (interview_type in ('CLIENT','PHONE','VIDEO','ONSITE','TECHNICAL','HIRING_MANAGER','PANEL','FINAL','CUSTOM'));
alter table public.interviews drop constraint if exists interviews_status_check;
alter table public.interviews add constraint interviews_status_check
  check (status in ('SCHEDULED','COMPLETED','CANCELLED','NO_SHOW','RESCHEDULED'));

-- Cross-timezone fields must use IANA identifiers when supplied.
alter table public.interviews drop constraint if exists interviews_candidate_timezone_iana_check;
alter table public.interviews add constraint interviews_candidate_timezone_iana_check
  check (candidate_timezone is null or public.xzrecruiter_valid_timezone(candidate_timezone));
alter table public.interviews drop constraint if exists interviews_recruiter_timezone_iana_check;
alter table public.interviews add constraint interviews_recruiter_timezone_iana_check
  check (recruiter_timezone is null or public.xzrecruiter_valid_timezone(recruiter_timezone));

-- Global compensation correctness.
alter table public.offers drop constraint if exists offers_currency_iso_check;
alter table public.offers add constraint offers_currency_iso_check check (currency is null or currency ~ '^[A-Z]{3}$');
alter table public.placements drop constraint if exists placements_salary_currency_iso_check;
alter table public.placements add constraint placements_salary_currency_iso_check check (salary_currency is null or salary_currency ~ '^[A-Z]{3}$');
alter table public.placements drop constraint if exists placements_fee_currency_iso_check;
alter table public.placements add constraint placements_fee_currency_iso_check check (fee_currency is null or fee_currency ~ '^[A-Z]{3}$');
