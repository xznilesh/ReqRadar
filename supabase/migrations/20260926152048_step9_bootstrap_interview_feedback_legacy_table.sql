create table if not exists public.interview_feedback (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  interview_id uuid references public.interviews(id) on delete cascade,
  user_id uuid references public.users(id) on delete set null,
  rating numeric,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
revoke all on public.interview_feedback from anon, authenticated;

