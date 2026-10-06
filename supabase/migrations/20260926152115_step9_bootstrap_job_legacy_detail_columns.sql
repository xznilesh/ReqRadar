alter table public.recruitment_jobs add column if not exists location text;
alter table public.recruitment_jobs add column if not exists workplace_type text;
alter table public.recruitment_jobs add column if not exists employment_type text;
alter table public.recruitment_jobs add column if not exists salary_min numeric;
alter table public.recruitment_jobs add column if not exists salary_max numeric;
alter table public.recruitment_jobs add column if not exists salary_currency text;
alter table public.recruitment_jobs add column if not exists description text;

