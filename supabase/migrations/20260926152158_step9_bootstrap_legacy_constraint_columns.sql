alter table public.interviews add column if not exists candidate_timezone text;
alter table public.interviews add column if not exists recruiter_timezone text;
alter table public.offers add column if not exists currency text;
alter table public.placements add column if not exists fee_currency text;

