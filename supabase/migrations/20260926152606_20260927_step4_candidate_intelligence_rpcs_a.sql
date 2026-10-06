-- XZ Recruiter Step 4 candidate intelligence RPCs: input/context/job start.
-- Browser-visible context excludes full extracted resume text; server analysis input is separately authorized.

create or replace function public.xzrecruiter_store_candidate_parse_text(
  p_token text,p_job_id uuid,p_parse_run_id uuid,p_extracted_text text
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_candidate uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  select candidate_id into v_candidate
  from public.candidate_parse_runs
  where id=p_parse_run_id and agency_id=v_agency;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','parse_run_not_found'); end if;
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,p_job_id,v_candidate) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;
  if length(coalesce(p_extracted_text,''))>160000 then return jsonb_build_object('ok',false,'error','resume_text_too_large'); end if;
  update public.candidate_parse_runs
  set extracted_text=left(coalesce(p_extracted_text,''),160000),updated_at=now()
  where id=p_parse_run_id and agency_id=v_agency;
  return jsonb_build_object('ok',true,'candidate_id',v_candidate,'parse_run_id',p_parse_run_id);
end;
$fn$;

create or replace function private.xzrecruiter_candidate_scoring_config(p_agency_id uuid)
returns jsonb
language plpgsql stable security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_id uuid;v_version text;v_weights jsonb;
begin
  select id,version_key,weights into v_id,v_version,v_weights
  from public.candidate_scoring_configs
  where agency_id=p_agency_id and active=true
  order by created_at desc limit 1;
  if v_id is null then
    return jsonb_build_object(
      'id',null,'version','xz-candidate-score-2026-09-25-v2',
      'weights',jsonb_build_object(
        'mandatorySkills',35,'experienceFit',15,'titleDomain',10,'locationWorkModel',10,
        'workAuthorization',15,'availability',5,'preferredSkills',5,'profileConsistency',5
      )
    );
  end if;
  return jsonb_build_object('id',v_id,'version',v_version,'weights',v_weights);
end;
$fn$;
revoke all on function private.xzrecruiter_candidate_scoring_config(uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_candidate_intelligence_input(
  p_token text,p_job_id uuid,p_candidate_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_app uuid;v_candidate jsonb;v_parse jsonb;v_brief jsonb;v_criteria jsonb;v_scoring jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,p_job_id,p_candidate_id) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;

  select a.id into v_app
  from public.applications a
  where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=p_candidate_id and a.archived_at is null
  limit 1;

  select jsonb_build_object(
    'id',c.id,'full_name',c.full_name,'email',c.email,'phone',c.phone,'city',c.city,'region',c.region,
    'country_code',c.country_code,'current_title',c.current_title,'current_company',c.current_company,
    'experience_years',c.experience_years,'relevant_experience_years',c.relevant_experience_years,
    'skills',coalesce(c.skills,'[]'::jsonb),'certifications',coalesce(c.certifications,'[]'::jsonb),
    'education',coalesce(c.education,'[]'::jsonb),'availability_status',c.availability_status,
    'notice_period_days',c.notice_period_days,'workplace_preference',c.workplace_preference,
    'desired_locations',coalesce(c.desired_locations,'[]'::jsonb),
    'work_authorization_summary',coalesce(c.work_authorization_summary,'[]'::jsonb),
    'updated_at',c.updated_at,
    'source_reference',(select a2.source_reference from public.applications a2 where a2.id=v_app),
    'source_type',(select a2.source_type from public.applications a2 where a2.id=v_app)
  ) into v_candidate
  from public.candidates c
  where c.id=p_candidate_id and c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null;

  select to_jsonb(x) into v_parse from (
    select pr.id,pr.document_id,d.version_number document_version,d.checksum,d.filename,d.created_at document_created_at,
      pr.parser_version,pr.status,pr.extracted_data,pr.field_confidence,pr.field_evidence,pr.extracted_text,
      pr.updated_at,pr.model_version,pr.prompt_version,pr.schema_version
    from public.candidate_parse_runs pr
    left join public.candidate_documents d on d.id=pr.document_id and d.agency_id=v_agency
    where pr.agency_id=v_agency and pr.candidate_id=p_candidate_id
    order by coalesce(d.is_primary,false) desc,d.version_number desc,pr.created_at desc limit 1
  ) x;

  select jsonb_build_object(
    'id',hb.id,'version_number',hb.version_number,'source_fingerprint',hb.source_fingerprint,
    'structured_data',hb.structured_data,'hiring_brief',hb.hiring_brief,'search_blueprint',hb.search_blueprint,
    'approved_at',hb.approved_at
  ) into v_brief
  from public.recruitment_jobs j
  join public.requirement_hiring_briefs hb on hb.id=j.approved_hiring_brief_id and hb.agency_id=v_agency
  where j.id=p_job_id and j.agency_id=v_agency and j.recruiter_ready=true
    and j.approved_hiring_brief_id is not null and hb.brief_status='APPROVED';

  if v_brief is null then return jsonb_build_object('ok',false,'error','approved_brief_required'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'criterion_kind',c.criterion_kind,'label',c.label,'field_key',c.field_key,'value_text',c.value_text,
    'confidence',c.confidence,'evidence',c.evidence,'extraction_status',c.extraction_status,'enforcement',c.enforcement,
    'am_confirmed',c.am_confirmed
  ) order by c.sort_order,c.created_at),'[]'::jsonb)
  into v_criteria
  from public.requirement_criteria c
  where c.agency_id=v_agency and c.brief_id=(v_brief->>'id')::uuid;

  v_scoring:=private.xzrecruiter_candidate_scoring_config(v_agency);

  return jsonb_build_object(
    'ok',true,'agency_id',v_agency,'user_id',v_user,'business_role',v_business_role,
    'application_id',v_app,'candidate',v_candidate,'parse_run',coalesce(v_parse,'{}'::jsonb),
    'brief',v_brief,'criteria',v_criteria,'scoring',v_scoring
  );
end;
$fn$;

create or replace function public.xzrecruiter_candidate_intelligence_context(
  p_token text,p_job_id uuid,p_candidate_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_app uuid;
  v_candidate jsonb;v_match jsonb;v_history jsonb;v_dupes jsonb;v_profile jsonb;v_source jsonb;v_job jsonb;v_jobrun jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,p_job_id,p_candidate_id) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;

  select a.id,jsonb_build_object('source_type',a.source_type,'source_reference',a.source_reference,'sourced_at',a.sourced_at,'sourced_by_user_id',a.sourced_by_user_id)
  into v_app,v_source
  from public.applications a
  where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=p_candidate_id and a.archived_at is null limit 1;

  select jsonb_build_object(
    'id',c.id,'full_name',c.full_name,'email',c.email,'phone',c.phone,'city',c.city,'region',c.region,'country_code',c.country_code,
    'current_title',c.current_title,'current_company',c.current_company,'experience_years',c.experience_years,
    'relevant_experience_years',c.relevant_experience_years,'availability_status',c.availability_status,
    'notice_period_days',c.notice_period_days,'workplace_preference',c.workplace_preference,'updated_at',c.updated_at
  ) into v_candidate
  from public.candidates c where c.id=p_candidate_id and c.agency_id=v_agency;

  select jsonb_build_object('id',j.id,'title',j.title,'client_id',j.client_id,'approved_hiring_brief_id',j.approved_hiring_brief_id)
  into v_job from public.recruitment_jobs j where j.id=p_job_id and j.agency_id=v_agency;

  select pv.profile_json into v_profile
  from public.candidate_profile_versions pv
  where pv.agency_id=v_agency and pv.candidate_id=p_candidate_id and pv.is_current=true
  order by pv.created_at desc limit 1;

  select to_jsonb(x) into v_match from (
    select m.id,m.score,m.match_band,m.confidence,m.coverage,m.hard_rule_status,m.component_scores,m.hard_rule_results,
      m.requirement_results,m.strengths,m.gaps,m.uncertainties,m.evidence_meta,m.recommendation,m.brief_id,m.brief_version,
      m.profile_version_id,m.scoring_version,m.model_name,m.prompt_version,m.schema_version,m.generated_at,m.run_status,
      a.intelligence_review_state,a.intelligence_reviewed_at
    from public.candidate_match_runs m
    join public.applications a on a.id=m.application_id and a.agency_id=v_agency
    where m.agency_id=v_agency and m.application_id=v_app
    order by (m.id=a.current_candidate_match_id) desc,m.generated_at desc limit 1
  ) x;

  select to_jsonb(x) into v_jobrun from (
    select id,run_status,model_requested,model_resolved,prompt_version,schema_version,scoring_version,
      attempt_count,retry_count,latency_ms,error_code,started_at,completed_at
    from public.candidate_intelligence_jobs
    where agency_id=v_agency and application_id=v_app
    order by started_at desc limit 1
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.generated_at desc),'[]'::jsonb) into v_history from (
    select id,score,match_band,confidence,hard_rule_status,brief_version,scoring_version,generated_at,run_status,stale_reason
    from public.candidate_match_runs
    where agency_id=v_agency and application_id=v_app
    order by generated_at desc limit 10
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.score desc,x.created_at desc),'[]'::jsonb) into v_dupes from (
    select d.id,d.compared_candidate_id,d.duplicate_status,d.score,d.signals,d.created_at,
      c.full_name,c.current_title,c.current_company,c.city,c.country_code
    from public.candidate_duplicate_signals d
    join public.candidates c on c.id=d.compared_candidate_id and c.agency_id=v_agency
    where d.agency_id=v_agency and d.candidate_id=p_candidate_id
      and d.profile_version_id=(select id from public.candidate_profile_versions where agency_id=v_agency and candidate_id=p_candidate_id and is_current=true limit 1)
    order by d.score desc,d.created_at desc limit 10
  ) x;

  return jsonb_build_object(
    'ok',true,'business_role',v_business_role,'application_id',v_app,'job',v_job,'candidate',v_candidate,
    'source',coalesce(v_source,'{}'::jsonb),'profile',coalesce(v_profile,'{}'::jsonb),
    'match',coalesce(v_match,'{}'::jsonb),'analysis_job',coalesce(v_jobrun,'{}'::jsonb),
    'history',v_history,'duplicates',v_dupes
  );
end;
$fn$;

create or replace function public.xzrecruiter_begin_candidate_intelligence(
  p_token text,p_job_id uuid,p_candidate_id uuid,p_idempotency_key text,p_input_hash text,
  p_model_requested text,p_prompt_version text,p_schema_version text,p_scoring_version text
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_app uuid;v_brief uuid;v_fingerprint text;
  v_parse uuid;v_parse_updated timestamptz;v_candidate_updated timestamptz;v_existing record;v_id uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,p_job_id,p_candidate_id) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;
  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null or nullif(btrim(coalesce(p_input_hash,'')),'') is null then
    return jsonb_build_object('ok',false,'error','idempotency_required');
  end if;

  select a.id,j.approved_hiring_brief_id,hb.source_fingerprint,c.updated_at
  into v_app,v_brief,v_fingerprint,v_candidate_updated
  from public.applications a
  join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
  join public.requirement_hiring_briefs hb on hb.id=j.approved_hiring_brief_id and hb.agency_id=v_agency and hb.brief_status='APPROVED'
  join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency
  where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=p_candidate_id and a.archived_at is null
    and j.recruiter_ready=true and j.approved_hiring_brief_id is not null
  limit 1;
  if v_app is null then return jsonb_build_object('ok',false,'error','approved_brief_required'); end if;

  select pr.id,pr.updated_at into v_parse,v_parse_updated
  from public.candidate_parse_runs pr
  left join public.candidate_documents d on d.id=pr.document_id and d.agency_id=v_agency
  where pr.agency_id=v_agency and pr.candidate_id=p_candidate_id
  order by coalesce(d.is_primary,false) desc,d.version_number desc,pr.created_at desc limit 1;

  perform pg_advisory_xact_lock(hashtext(v_agency::text||'|'||p_idempotency_key));
  select * into v_existing from public.candidate_intelligence_jobs
  where agency_id=v_agency and idempotency_key=p_idempotency_key limit 1;
  if v_existing.id is not null then
    if v_existing.run_status='SUCCEEDED' then
      return jsonb_build_object('ok',true,'run_id',v_existing.id,'reused',true,'run_status','SUCCEEDED');
    end if;
    if v_existing.run_status='PROCESSING' and v_existing.started_at>now()-interval '2 minutes' then
      return jsonb_build_object('ok',true,'run_id',v_existing.id,'reused',true,'run_status','PROCESSING');
    end if;
    update public.candidate_intelligence_jobs
    set run_status='PROCESSING',attempt_count=attempt_count+1,retry_count=retry_count+1,error_code=null,error_detail=null,
        candidate_updated_at_snapshot=v_candidate_updated,parse_run_id=v_parse,parse_run_updated_at_snapshot=v_parse_updated,
        brief_id=v_brief,brief_source_fingerprint=v_fingerprint,started_at=now(),completed_at=null
    where id=v_existing.id;
    return jsonb_build_object('ok',true,'run_id',v_existing.id,'reused',false,'retry',true,'run_status','PROCESSING');
  end if;

  v_id:=gen_random_uuid();
  insert into public.candidate_intelligence_jobs(
    id,agency_id,job_id,candidate_id,application_id,brief_id,parse_run_id,candidate_updated_at_snapshot,
    parse_run_updated_at_snapshot,brief_source_fingerprint,idempotency_key,input_hash,run_status,model_requested,
    prompt_version,schema_version,scoring_version,started_by_user_id
  ) values(
    v_id,v_agency,p_job_id,p_candidate_id,v_app,v_brief,v_parse,v_candidate_updated,v_parse_updated,v_fingerprint,
    left(p_idempotency_key,160),left(p_input_hash,128),'PROCESSING',left(coalesce(p_model_requested,''),120),
    left(p_prompt_version,120),left(p_schema_version,120),left(p_scoring_version,120),v_user
  );
  return jsonb_build_object('ok',true,'run_id',v_id,'reused',false,'run_status','PROCESSING');
end;
$fn$;

revoke all on function public.xzrecruiter_store_candidate_parse_text(text,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_candidate_intelligence_input(text,uuid,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_candidate_intelligence_context(text,uuid,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_begin_candidate_intelligence(text,uuid,uuid,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_store_candidate_parse_text(text,uuid,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_intelligence_input(text,uuid,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_intelligence_context(text,uuid,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_begin_candidate_intelligence(text,uuid,uuid,text,text,text,text,text,text) to anon,authenticated;
