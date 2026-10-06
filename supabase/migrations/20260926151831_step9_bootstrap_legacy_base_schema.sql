create extension if not exists pgcrypto with schema extensions;

create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  display_name text,
  locale text,
  timezone text,
  language_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.agencies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  country text,
  timezone text,
  onboarding_status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.agency_memberships (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null default 'MEMBER',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id,user_id)
);

create table if not exists public.user_credentials (
  user_id uuid primary key references public.users(id) on delete cascade,
  password_hash text not null,
  password_salt text,
  password_updated_at timestamptz not null default now()
);

create table if not exists public.user_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  agency_id uuid references public.agencies(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.auth_login_events (
  id uuid primary key default gen_random_uuid(),
  email_normalized text not null,
  success boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.password_reset_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_events (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid references public.agencies(id) on delete cascade,
  actor_user_id uuid references public.users(id) on delete set null,
  action text not null,
  entity_type text,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  domain text,
  active boolean not null default true,
  locale text,
  timezone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.canonical_jobs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  title text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.agency_company_hiring_heat (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  heat_score numeric not null default 0,
  why_now_summary text,
  updated_at timestamptz not null default now(),
  primary key (agency_id,company_id)
);

create table if not exists public.agency_company_fit_scores (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  fit_score numeric,
  updated_at timestamptz not null default now(),
  primary key (agency_id,company_id)
);

create table if not exists public.recruitment_clients (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  company_id uuid references public.companies(id) on delete set null,
  name text not null default '',
  status text not null default 'ACTIVE',
  country_code text,
  locale text,
  timezone text,
  currency_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.recruitment_jobs (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  client_id uuid references public.recruitment_clients(id) on delete set null,
  title text not null default '',
  status text not null default 'OPEN',
  active boolean not null default true,
  country_code text,
  locale text,
  timezone text,
  currency_code text,
  salary_period text,
  salary_gross_net text,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.candidates (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  first_name text,
  last_name text,
  full_name text,
  email text,
  phone text,
  status text not null default 'ACTIVE',
  country_code text,
  locale text,
  timezone text,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  stage text not null default 'APPLIED',
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.interviews (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid references public.applications(id) on delete cascade,
  scheduled_at timestamptz,
  timezone text not null default 'UTC',
  status text not null default 'SCHEDULED',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.recruitment_contacts (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  client_id uuid references public.recruitment_clients(id) on delete cascade,
  first_name text,
  last_name text,
  email text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

revoke all on all tables in schema public from anon, authenticated;

