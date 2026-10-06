\set QUIET 1
\pset tuples_only on
\pset format unaligned
set statement_timeout='30s';
set lock_timeout='5s';
set idle_in_transaction_session_timeout='60s';
set jit=off;

create temp table xzbench_candidates(
  id bigint primary key,
  agency_id bigint not null,
  full_name text not null,
  email text,
  current_title text,
  country_code text,
  availability_status text,
  archived_at timestamptz,
  updated_at timestamptz not null
) on commit drop;
create index xzbench_candidates_search on xzbench_candidates(agency_id,archived_at,updated_at desc);
create index xzbench_candidates_email on xzbench_candidates(agency_id,lower(email)) where email is not null;

create temp table xzbench_jobs(
  id bigint primary key,
  agency_id bigint not null,
  title text not null,
  status text not null,
  priority text not null,
  country_code text,
  updated_at timestamptz not null
) on commit drop;
create index xzbench_jobs_search on xzbench_jobs(agency_id,status,priority,updated_at desc);

create temp table xzbench_applications(
  id bigint primary key,
  agency_id bigint not null,
  candidate_id bigint not null,
  job_id bigint not null,
  stage text not null,
  updated_at timestamptz not null
) on commit drop;
create index xzbench_app_candidate on xzbench_applications(agency_id,candidate_id,updated_at desc);
create index xzbench_app_job_stage on xzbench_applications(agency_id,job_id,stage,updated_at desc);

insert into xzbench_candidates
select g,1,'Candidate '||g,'candidate'||g||'@example.invalid',case when g%5=0 then 'Engineer' else 'Recruiter' end,case when g%2=0 then 'US' else 'IN' end,case when g%3=0 then 'AVAILABLE_NOW' else 'UNKNOWN' end,null,now()-(g%365||' days')::interval
from generate_series(1,:scale) g;
insert into xzbench_jobs
select g,1,'Job '||g,case when g%7=0 then 'ON_HOLD' else 'OPEN' end,case when g%11=0 then 'URGENT' else 'NORMAL' end,case when g%2=0 then 'US' else 'IN' end,now()-(g%180||' days')::interval
from generate_series(1,:scale) g;
insert into xzbench_applications
select g,1,((g-1)%:scale)+1,((g*17-1)%:scale)+1,case when g%5=0 then 'SCREENING' when g%5=1 then 'SOURCED' when g%5=2 then 'QUALIFIED' when g%5=3 then 'INTERVIEW' else 'OFFER' end,now()-(g%90||' days')::interval
from generate_series(1,(:scale*2)) g;
analyze xzbench_candidates; analyze xzbench_jobs; analyze xzbench_applications;

create temp table xzbench_timings(query_name text, elapsed_ms double precision) on commit drop;
create temp table xzbench_config(scale int not null,repetitions int not null) on commit drop;
insert into xzbench_config values(:scale,:repetitions);
do $$
declare i int; t timestamptz; dummy bigint; v_scale int; v_repetitions int;
begin
  select scale,repetitions into v_scale,v_repetitions from xzbench_config;
  for i in 1..v_repetitions loop
    t:=clock_timestamp();
    select count(*) into dummy from (select id from xzbench_candidates where agency_id=1 and archived_at is null order by updated_at desc limit 50) s;
    insert into xzbench_timings values('candidate_page',extract(epoch from clock_timestamp()-t)*1000);
    t:=clock_timestamp();
    select count(*) into dummy from xzbench_candidates where agency_id=1 and lower(email)=lower('candidate'||greatest(1,v_scale/2)::int||'@example.invalid');
    insert into xzbench_timings values('candidate_email_lookup',extract(epoch from clock_timestamp()-t)*1000);
    t:=clock_timestamp();
    select count(*) into dummy from (select id from xzbench_jobs where agency_id=1 and status='OPEN' order by updated_at desc limit 50) s;
    insert into xzbench_timings values('job_page',extract(epoch from clock_timestamp()-t)*1000);
    t:=clock_timestamp();
    select count(*) into dummy from xzbench_applications where agency_id=1 and job_id=greatest(1,v_scale/2)::int and stage in ('SOURCED','SCREENING','QUALIFIED');
    insert into xzbench_timings values('job_pipeline_count',extract(epoch from clock_timestamp()-t)*1000);
  end loop;
end $$;
select 'XZBENCH|'||:scale||'|'||query_name||'|'||round(percentile_cont(0.50) within group(order by elapsed_ms)::numeric,3)||'|'||round(percentile_cont(0.95) within group(order by elapsed_ms)::numeric,3)||'|'||round(percentile_cont(0.99) within group(order by elapsed_ms)::numeric,3)
from xzbench_timings group by query_name order by query_name;
