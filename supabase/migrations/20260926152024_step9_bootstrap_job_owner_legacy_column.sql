alter table public.recruitment_jobs
  add column if not exists owner_user_id uuid references public.users(id) on delete set null;

