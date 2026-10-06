create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid references public.applications(id) on delete cascade,
  status text not null default 'DRAFT',
  salary numeric,
  salary_currency text,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.placements (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid references public.applications(id) on delete set null,
  start_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
revoke all on public.offers, public.placements from anon, authenticated;

