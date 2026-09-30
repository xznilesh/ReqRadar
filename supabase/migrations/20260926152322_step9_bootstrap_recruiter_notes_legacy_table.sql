alter table public.users add column if not exists full_name text;
update public.users set full_name=coalesce(full_name,display_name) where full_name is null;
create table if not exists public.recruiter_notes (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  author_user_id uuid references public.users(id) on delete set null,
  note text not null,
  created_at timestamptz not null default now()
);
revoke all on public.recruiter_notes from anon, authenticated;

