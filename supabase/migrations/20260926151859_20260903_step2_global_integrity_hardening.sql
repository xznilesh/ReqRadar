-- XZ Recruiter Step 2 integrity hardening.
-- Additive constraints only; no production rows are deleted or rewritten.

-- Explicit tenant ownership for localized taxonomy labels. Global labels keep agency_id NULL.
alter table public.taxonomy_labels
  add column if not exists agency_id uuid references public.agencies(id) on delete cascade;

update public.taxonomy_labels l
set agency_id = n.agency_id
from public.taxonomy_nodes n
where n.id = l.taxonomy_id
  and l.agency_id is distinct from n.agency_id;

create index if not exists idx_xzrecruiter_taxonomy_labels_agency
  on public.taxonomy_labels(agency_id, taxonomy_id, locale);

-- Ensure every entity-level timezone is a real IANA identifier. Existing NULLs remain valid.
alter table public.users
  add constraint users_timezone_iana_check
  check (timezone is null or public.xzrecruiter_valid_timezone(timezone));

alter table public.companies
  add constraint companies_timezone_iana_check
  check (timezone is null or public.xzrecruiter_valid_timezone(timezone));

alter table public.recruitment_clients
  add constraint recruitment_clients_timezone_iana_check
  check (timezone is null or public.xzrecruiter_valid_timezone(timezone));

alter table public.recruitment_jobs
  add constraint recruitment_jobs_timezone_iana_check
  check (timezone is null or public.xzrecruiter_valid_timezone(timezone));

alter table public.candidates
  add constraint candidates_timezone_iana_check
  check (timezone is null or public.xzrecruiter_valid_timezone(timezone));

alter table public.interviews
  add constraint interviews_timezone_iana_check
  check (public.xzrecruiter_valid_timezone(timezone));

-- New structured country fields resolve through the reusable country registry.
alter table public.recruitment_clients
  add constraint recruitment_clients_country_profile_fkey
  foreign key (country_code) references public.global_country_profiles(country_code);

alter table public.recruitment_jobs
  add constraint recruitment_jobs_country_profile_fkey
  foreign key (country_code) references public.global_country_profiles(country_code);

alter table public.candidates
  add constraint candidates_country_profile_fkey
  foreign key (country_code) references public.global_country_profiles(country_code);

-- Language and currency values stay structurally valid.
alter table public.users
  add constraint users_language_profile_fkey
  foreign key (language_code) references public.global_languages(language_code);

alter table public.recruitment_clients
  add constraint recruitment_clients_currency_iso_check
  check (currency_code is null or currency_code ~ '^[A-Z]{3}$');

alter table public.recruitment_jobs
  add constraint recruitment_jobs_salary_period_check
  check (salary_period is null or salary_period in ('HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL'));

alter table public.recruitment_jobs
  add constraint recruitment_jobs_salary_gross_net_check
  check (salary_gross_net is null or salary_gross_net in ('GROSS','NET','UNSPECIFIED'));

-- Global retrieval indexes stay tenant-first and pagination friendly.
create index if not exists idx_xzrecruiter_jobs_global_filter
  on public.recruitment_jobs(agency_id, country_code, status, updated_at desc);

create index if not exists idx_xzrecruiter_candidates_global_filter
  on public.candidates(agency_id, country_code, updated_at desc);

create index if not exists idx_xzrecruiter_clients_global_filter
  on public.recruitment_clients(agency_id, country_code, status, updated_at desc);

create index if not exists idx_xzrecruiter_interviews_schedule_timezone
  on public.interviews(agency_id, scheduled_at, timezone);
