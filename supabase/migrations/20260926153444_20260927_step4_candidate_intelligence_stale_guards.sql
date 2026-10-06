-- XZ Recruiter Step 4 stale-intelligence invalidation.
-- Material source changes preserve history but clear current pointers and force recomputation.

create or replace function private.xzrecruiter_mark_candidate_matches_stale(
  p_agency_id uuid,p_candidate_id uuid,p_reason text
) returns integer
language plpgsql security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_count integer:=0;
begin
  update public.candidate_match_runs
  set run_status='STALE',stale_at=coalesce(stale_at,now()),stale_reason=left(coalesce(p_reason,'CANDIDATE_CHANGED'),120)
  where agency_id=p_agency_id and candidate_id=p_candidate_id and run_status='SUCCEEDED';
  get diagnostics v_count=row_count;

  update public.applications
  set current_candidate_match_id=null,intelligence_review_state='NOT_REVIEWED',intelligence_reviewed_at=null,updated_at=now()
  where agency_id=p_agency_id and candidate_id=p_candidate_id and current_candidate_match_id is not null;

  return v_count;
end;
$fn$;
revoke all on function private.xzrecruiter_mark_candidate_matches_stale(uuid,uuid,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_mark_job_matches_stale(
  p_agency_id uuid,p_job_id uuid,p_reason text
) returns integer
language plpgsql security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_count integer:=0;
begin
  update public.candidate_match_runs
  set run_status='STALE',stale_at=coalesce(stale_at,now()),stale_reason=left(coalesce(p_reason,'REQUIREMENT_CHANGED'),120)
  where agency_id=p_agency_id and job_id=p_job_id and run_status='SUCCEEDED';
  get diagnostics v_count=row_count;

  update public.applications
  set current_candidate_match_id=null,intelligence_review_state='NOT_REVIEWED',intelligence_reviewed_at=null,updated_at=now()
  where agency_id=p_agency_id and job_id=p_job_id and current_candidate_match_id is not null;

  return v_count;
end;
$fn$;
revoke all on function private.xzrecruiter_mark_job_matches_stale(uuid,uuid,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_candidate_material_change_trigger()
returns trigger
language plpgsql security invoker
set search_path='public','private','pg_temp'
as $fn$
begin
  if row(
    old.full_name,old.email,old.phone,old.city,old.region,old.country_code,
    old.current_title,old.current_company,old.experience_years,old.relevant_experience_years,
    old.skills,old.education,old.certifications,old.availability_status,old.notice_period_days,
    old.workplace_preference,old.relocation_preference,old.desired_locations,old.work_authorization_summary,
    old.archived_at,old.merged_into_candidate_id
  ) is distinct from row(
    new.full_name,new.email,new.phone,new.city,new.region,new.country_code,
    new.current_title,new.current_company,new.experience_years,new.relevant_experience_years,
    new.skills,new.education,new.certifications,new.availability_status,new.notice_period_days,
    new.workplace_preference,new.relocation_preference,new.desired_locations,new.work_authorization_summary,
    new.archived_at,new.merged_into_candidate_id
  ) then
    perform private.xzrecruiter_mark_candidate_matches_stale(new.agency_id,new.id,'CANDIDATE_PROFILE_CHANGED');
  end if;
  return new;
end;
$fn$;

drop trigger if exists xzr_candidate_intelligence_stale_on_profile on public.candidates;
create trigger xzr_candidate_intelligence_stale_on_profile
after update on public.candidates
for each row execute function private.xzrecruiter_candidate_material_change_trigger();

create or replace function private.xzrecruiter_candidate_document_change_trigger()
returns trigger
language plpgsql security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_candidate uuid;v_is_primary boolean;v_document_type text;
begin
  v_agency:=coalesce(new.agency_id,old.agency_id);
  v_candidate:=coalesce(new.candidate_id,old.candidate_id);
  v_is_primary:=coalesce(new.is_primary,false) or coalesce(old.is_primary,false);
  v_document_type:=upper(coalesce(new.document_type,old.document_type,''));
  if v_document_type='RESUME' and (v_is_primary or tg_op='INSERT') then
    perform private.xzrecruiter_mark_candidate_matches_stale(v_agency,v_candidate,'RESUME_VERSION_CHANGED');
  end if;
  return coalesce(new,old);
end;
$fn$;

drop trigger if exists xzr_candidate_intelligence_stale_on_document on public.candidate_documents;
create trigger xzr_candidate_intelligence_stale_on_document
after insert or update of is_primary,checksum,archived_at on public.candidate_documents
for each row execute function private.xzrecruiter_candidate_document_change_trigger();

create or replace function private.xzrecruiter_requirement_intelligence_change_trigger()
returns trigger
language plpgsql security invoker
set search_path='public','private','pg_temp'
as $fn$
begin
  if old.approved_hiring_brief_id is distinct from new.approved_hiring_brief_id
     or old.recruiter_ready is distinct from new.recruiter_ready
     or old.requirement_state is distinct from new.requirement_state then
    perform private.xzrecruiter_mark_job_matches_stale(new.agency_id,new.id,'APPROVED_REQUIREMENT_CHANGED');
  end if;
  return new;
end;
$fn$;

drop trigger if exists xzr_candidate_intelligence_stale_on_requirement on public.recruitment_jobs;
create trigger xzr_candidate_intelligence_stale_on_requirement
after update of approved_hiring_brief_id,recruiter_ready,requirement_state on public.recruitment_jobs
for each row execute function private.xzrecruiter_requirement_intelligence_change_trigger();

create or replace function private.xzrecruiter_scoring_config_change_trigger()
returns trigger
language plpgsql security invoker
set search_path='public','private','pg_temp'
as $fn$
begin
  if (tg_op='INSERT' and new.active=true)
     or (tg_op='UPDATE' and (
       old.active is distinct from new.active
       or (new.active=true and (old.weights is distinct from new.weights or old.version_key is distinct from new.version_key))
     )) then
    update public.candidate_match_runs
    set run_status='STALE',stale_at=coalesce(stale_at,now()),stale_reason='SCORING_CONFIG_CHANGED'
    where agency_id=new.agency_id and run_status='SUCCEEDED';

    update public.applications a
    set current_candidate_match_id=null,intelligence_review_state='NOT_REVIEWED',intelligence_reviewed_at=null,updated_at=now()
    where a.agency_id=new.agency_id and a.current_candidate_match_id is not null;
  end if;
  return new;
end;
$fn$;

drop trigger if exists xzr_candidate_intelligence_stale_on_scoring on public.candidate_scoring_configs;
create trigger xzr_candidate_intelligence_stale_on_scoring
after insert or update of active,weights,version_key on public.candidate_scoring_configs
for each row execute function private.xzrecruiter_scoring_config_change_trigger();

revoke all on function private.xzrecruiter_candidate_material_change_trigger() from public,anon,authenticated;
revoke all on function private.xzrecruiter_candidate_document_change_trigger() from public,anon,authenticated;
revoke all on function private.xzrecruiter_requirement_intelligence_change_trigger() from public,anon,authenticated;
revoke all on function private.xzrecruiter_scoring_config_change_trigger() from public,anon,authenticated;
