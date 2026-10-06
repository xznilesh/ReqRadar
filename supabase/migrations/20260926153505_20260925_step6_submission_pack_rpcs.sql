-- XZ Recruiter locked roadmap Step 6 RPC/domain enforcement.
-- All critical eligibility, AM authority, version/concurrency, duplicate and client snapshot checks are server-side.

create or replace function private.xzrecruiter_step6_submission_access(
  p_agency uuid,p_user uuid,p_business_role text,p_application uuid,p_write boolean default false
) returns boolean
language sql stable security invoker
set search_path='public','private','pg_temp'
as $$
  select case
    when upper(coalesce(p_business_role,'')) in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER') then
      exists(select 1 from public.applications a where a.agency_id=p_agency and a.id=p_application and a.archived_at is null)
    when upper(coalesce(p_business_role,''))='RECRUITER' then
      exists(
        select 1
        from public.applications a
        join public.requirement_recruiter_assignments ra
          on ra.agency_id=a.agency_id and ra.job_id=a.job_id and ra.recruiter_user_id=p_user and ra.assignment_status='ACTIVE'
        where a.agency_id=p_agency and a.id=p_application and a.archived_at is null and a.owner_user_id=p_user
      )
    else false
  end;
$$;
revoke all on function private.xzrecruiter_step6_submission_access(uuid,uuid,text,uuid,boolean) from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_answer_value(
  p_agency uuid,p_application uuid,p_keys text[]
) returns text
language sql stable security invoker
set search_path='public','private','pg_temp'
as $$
  select coalesce(a.answer->>'value',a.answer->>'answer',a.answer #>> '{}')
  from public.application_screening_answers a
  where a.agency_id=p_agency and a.application_id=p_application
    and lower(a.question_key)=any(select lower(x) from unnest(p_keys) x)
  order by a.reviewed_at desc nulls last,a.updated_at desc
  limit 1;
$$;
revoke all on function private.xzrecruiter_step6_answer_value(uuid,uuid,text[]) from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_screening_snapshot(
  p_agency uuid,p_application uuid
) returns jsonb
language plpgsql stable security invoker
set search_path='public','private','pg_temp'
as $fn$
declare
  v_app jsonb;v_meta jsonb;v_step5 jsonb;v_state text;v_completed text;v_interest text;v_summary text;
  v_facts jsonb;v_recruiter uuid;v_updated timestamptz;
begin
  select to_jsonb(a),coalesce(a.metadata,'{}'::jsonb) into v_app,v_meta
  from public.applications a where a.agency_id=p_agency and a.id=p_application and a.archived_at is null;
  if v_app is null then return '{}'::jsonb; end if;

  v_step5:=coalesce(v_meta->'step5',v_meta->'human_screening',v_meta->'screening','{}'::jsonb);
  v_state:=upper(coalesce(
    nullif(v_app->>'screening_state',''),nullif(v_step5->>'state',''),nullif(v_step5->>'screeningState',''),
    private.xzrecruiter_step6_answer_value(p_agency,p_application,array['screening_state','screening_outcome','qualification_state'])
  ));
  v_completed:=coalesce(
    nullif(v_app->>'screening_completed_at',''),nullif(v_step5->>'completedAt',''),nullif(v_step5->>'completed_at',''),
    nullif(v_step5->>'completed',''),
    private.xzrecruiter_step6_answer_value(p_agency,p_application,array['screening_completed','human_screening_completed'])
  );
  v_interest:=coalesce(
    nullif(v_app->>'candidate_interest_confirmed',''),nullif(v_step5->>'interestConfirmed',''),nullif(v_step5->>'interest_confirmed',''),
    nullif(v_step5->>'interest',''),
    private.xzrecruiter_step6_answer_value(p_agency,p_application,array['candidate_interest','candidate_interest_confirmed','interest_confirmed'])
  );
  v_summary:=coalesce(
    nullif(v_step5->>'summary',''),nullif(v_step5->>'recruiterSummary',''),nullif(v_step5->>'recruiter_summary',''),
    private.xzrecruiter_step6_answer_value(p_agency,p_application,array['recruiter_screening_summary','screening_summary'])
  );

  select coalesce(jsonb_object_agg(x.question_key,jsonb_build_object(
      'value',x.answer,'provenance','RECRUITER_VERIFIED',
      'evidence',jsonb_build_array('Human screening answer reviewed by recruiter'),
      'reviewed_at',x.reviewed_at,'reviewed_by_user_id',x.reviewed_by_user_id
    )),'{}'::jsonb),max(coalesce(x.reviewed_at,x.updated_at))
  into v_facts,v_updated
  from public.application_screening_answers x
  where x.agency_id=p_agency and x.application_id=p_application;
  select x.reviewed_by_user_id into v_recruiter from public.application_screening_answers x
  where x.agency_id=p_agency and x.application_id=p_application and x.reviewed_by_user_id is not null
  order by coalesce(x.reviewed_at,x.updated_at) desc limit 1;

  return jsonb_build_object(
    'state',coalesce(v_state,'UNKNOWN'),
    'completed',case when lower(coalesce(v_completed,'')) in ('true','yes','1','complete','completed','qualified') or v_completed ~ '^20[0-9]{2}-' then true else false end,
    'completedAt',case when v_completed ~ '^20[0-9]{2}-' then v_completed else coalesce(v_step5->>'completedAt',v_step5->>'completed_at') end,
    'interestConfirmed',case when lower(coalesce(v_interest,'')) in ('true','yes','1','confirmed','interested') then true else false end,
    'interestRaw',v_interest,
    'summary',v_summary,
    'recruiterId',coalesce(nullif(v_step5->>'recruiterId','')::uuid,v_recruiter),
    'verifiedFacts',coalesce(v_step5->'verifiedFacts',v_step5->'verified_facts',v_facts,'{}'::jsonb),
    'candidateDeclared',coalesce(v_step5->'candidateDeclared',v_step5->'candidate_declared','{}'::jsonb),
    'conflicts',coalesce(v_step5->'conflicts','[]'::jsonb),
    'version',coalesce(v_step5->>'version',v_updated::text,v_app->>'updated_at'),
    'updatedAt',v_updated
  );
exception when invalid_text_representation then
  return jsonb_build_object('state','UNKNOWN','completed',false,'interestConfirmed',false,'verifiedFacts',coalesce(v_facts,'{}'::jsonb));
end;
$fn$;
revoke all on function private.xzrecruiter_step6_screening_snapshot(uuid,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_configuration(
  p_agency uuid,p_job uuid
) returns jsonb
language plpgsql stable security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_job jsonb;v_meta jsonb;v_cfg jsonb;
begin
  select to_jsonb(j) into v_job from public.recruitment_jobs j where j.agency_id=p_agency and j.id=p_job;
  v_meta:=coalesce(v_job->'metadata','{}'::jsonb);
  v_cfg:=coalesce(v_job->'submission_config',v_meta->'submissionConfig',v_meta->'submission_requirements','{}'::jsonb);
  return jsonb_build_object(
    'requiredFields',coalesce(v_cfg->'requiredFields',v_cfg->'required_fields','[]'::jsonb),
    'requireLatestResume',coalesce((v_cfg->>'requireLatestResume')::boolean,(v_cfg->>'require_latest_resume')::boolean,true),
    'requireCompliance',coalesce((v_cfg->>'requireCompliance')::boolean,(v_cfg->>'require_compliance')::boolean,false),
    'includeCandidateCompensationForClient',coalesce((v_cfg->>'includeCandidateCompensationForClient')::boolean,false),
    'raw',v_cfg
  );
exception when invalid_text_representation then
  return jsonb_build_object('requiredFields','[]'::jsonb,'requireLatestResume',true,'requireCompliance',false,'includeCandidateCompensationForClient',false,'raw','{}'::jsonb);
end;
$fn$;
revoke all on function private.xzrecruiter_step6_configuration(uuid,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_commercial_snapshot(
  p_agency uuid,p_application uuid,p_business_role text
) returns jsonb
language plpgsql stable security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_candidate jsonb;v_job jsonb;v_app jsonb;v_internal jsonb;v_client jsonb;
begin
  select to_jsonb(c),to_jsonb(j),to_jsonb(a)
  into v_candidate,v_job,v_app
  from public.applications a
  join public.candidates c on c.id=a.candidate_id and c.agency_id=p_agency
  join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency
  where a.id=p_application and a.agency_id=p_agency and a.archived_at is null;

  v_internal:=jsonb_strip_nulls(jsonb_build_object(
    'candidatePayRate',coalesce(v_candidate->'salary_expected',v_app->'candidate_pay_rate'),
    'candidatePayCurrency',coalesce(v_candidate->'salary_currency',v_app->'candidate_pay_currency'),
    'clientBillRate',coalesce(v_job->'client_bill_rate',v_app->'client_bill_rate'),
    'clientBillCurrency',coalesce(v_job->'bill_currency',v_job->'salary_currency',v_app->'bill_currency'),
    'margin',coalesce(v_app->'margin',v_job->'margin'),
    'markup',coalesce(v_app->'markup',v_job->'markup'),
    'provenance','ACCOUNT_MANAGER_CONFIRMED'
  ));
  v_client:=jsonb_strip_nulls(jsonb_build_object(
    'candidateCompensation',coalesce(v_candidate->'salary_expected',v_app->'candidate_pay_rate'),
    'currency',coalesce(v_candidate->'salary_currency',v_app->'candidate_pay_currency'),
    'provenance','RECRUITER_VERIFIED'
  ));
  if upper(coalesce(p_business_role,'')) in ('RECRUITER','RECRUITMENT_MANAGER') then
    return jsonb_build_object('internal','{}'::jsonb,'client',v_client);
  end if;
  return jsonb_build_object('internal',v_internal,'client',v_client);
end;
$fn$;
revoke all on function private.xzrecruiter_step6_commercial_snapshot(uuid,uuid,text) from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_source_fingerprint(
  p_agency uuid,p_application uuid
) returns text
language plpgsql stable security invoker
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_material text;
begin
  select concat_ws('|',
    a.id::text,a.updated_at::text,c.id::text,c.updated_at::text,
    coalesce(j.approved_hiring_brief_id::text,''),coalesce(hb.version_number::text,''),coalesce(hb.source_fingerprint,''),
    coalesce(m.id::text,''),coalesce(m.generated_at::text,''),coalesce(m.run_status,''),
    coalesce(d.id::text,''),coalesce(d.version_number::text,''),coalesce(d.checksum,''),
    private.xzrecruiter_step6_screening_snapshot(p_agency,p_application)::text,
    private.xzrecruiter_step6_commercial_snapshot(p_agency,p_application,'ACCOUNT_MANAGER')::text
  ) into v_material
  from public.applications a
  join public.candidates c on c.id=a.candidate_id and c.agency_id=p_agency
  join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=p_agency
  left join public.requirement_hiring_briefs hb on hb.id=j.approved_hiring_brief_id and hb.agency_id=p_agency
  left join public.candidate_match_runs m on m.id=a.current_candidate_match_id and m.agency_id=p_agency
  left join lateral (
    select cd.id,cd.version_number,cd.checksum
    from public.candidate_documents cd
    where cd.agency_id=p_agency and cd.candidate_id=a.candidate_id and cd.document_type='RESUME' and cd.archived_at is null and cd.is_primary=true
    order by cd.version_number desc limit 1
  ) d on true
  where a.id=p_application and a.agency_id=p_agency and a.archived_at is null;
  if v_material is null then return null; end if;
  return encode(digest(convert_to(v_material,'UTF8'),'sha256'),'hex');
end;
$fn$;
revoke all on function private.xzrecruiter_step6_source_fingerprint(uuid,uuid) from public,anon,authenticated;

create or replace function private.xzrecruiter_step6_eligibility(
  p_agency uuid,p_application uuid
) returns jsonb
language plpgsql stable security invoker
set search_path='public','private','pg_temp'
as $fn$
declare
  v_app record;v_app_json jsonb;v_stage text;v_candidacy text;v_screen jsonb;v_cfg jsonb;v_candidate jsonb;
  v_resume record;v_match record;v_reasons text[]:=array[]::text[];v_warnings text[]:=array[]::text[];
  v_field text;v_required jsonb;v_value jsonb;v_compliance jsonb;v_has_confirmed_hard boolean:=false;
begin
  select a.*,ps.code stage_code into v_app
  from public.applications a
  left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=p_agency
  where a.agency_id=p_agency and a.id=p_application and a.archived_at is null;
  if not found then return jsonb_build_object('eligible',false,'reasons',jsonb_build_array('APPLICATION_NOT_FOUND'),'warnings','[]'::jsonb); end if;

  v_app_json:=to_jsonb(v_app);
  v_stage:=upper(coalesce(v_app.stage_code,v_app_json->>'stage',''));
  v_candidacy:=upper(coalesce(nullif(v_app_json->>'candidacy_state',''),private.xzrecruiter_canonical_candidacy_state(v_stage),''));
  if v_candidacy<>'QUALIFIED' then v_reasons:=array_append(v_reasons,'CANDIDATE_NOT_QUALIFIED'); end if;

  v_screen:=private.xzrecruiter_step6_screening_snapshot(p_agency,p_application);
  if upper(coalesce(v_screen->>'state',''))<>'QUALIFIED' then v_reasons:=array_append(v_reasons,'SCREENING_NOT_QUALIFIED'); end if;
  if coalesce((v_screen->>'completed')::boolean,false)=false then v_reasons:=array_append(v_reasons,'SCREENING_INCOMPLETE'); end if;
  if coalesce((v_screen->>'interestConfirmed')::boolean,false)=false then v_reasons:=array_append(v_reasons,'CANDIDATE_INTEREST_NOT_CONFIRMED'); end if;

  select * into v_match from public.candidate_match_runs m
  where m.agency_id=p_agency and m.id=v_app.current_candidate_match_id;
  if v_match.id is null or v_match.run_status<>'SUCCEEDED' then
    v_reasons:=array_append(v_reasons,'CURRENT_CANDIDATE_INTELLIGENCE_REQUIRED');
  else
    if upper(coalesce(v_match.hard_rule_status,'UNKNOWN'))='FAIL' then v_reasons:=array_append(v_reasons,'APPROVED_HARD_REQUIREMENT_FAILED'); end if;
    select exists(
      select 1 from public.requirement_criteria rc
      where rc.agency_id=p_agency and rc.brief_id=v_match.brief_id
        and (upper(coalesce(rc.enforcement,''))='HARD' or coalesce(rc.am_confirmed,false)=true)
    ) into v_has_confirmed_hard;
    if v_has_confirmed_hard and upper(coalesce(v_match.hard_rule_status,'UNKNOWN'))='UNKNOWN' then
      v_reasons:=array_append(v_reasons,'APPROVED_HARD_REQUIREMENT_UNRESOLVED');
    end if;
  end if;

  select cd.id,cd.version_number,cd.checksum,cd.filename into v_resume
  from public.candidate_documents cd
  where cd.agency_id=p_agency and cd.candidate_id=v_app.candidate_id and cd.document_type='RESUME' and cd.archived_at is null and cd.is_primary=true
  order by cd.version_number desc limit 1;
  if v_resume.id is null then v_reasons:=array_append(v_reasons,'PRIMARY_RESUME_REQUIRED'); end if;

  select to_jsonb(c) into v_candidate from public.candidates c where c.agency_id=p_agency and c.id=v_app.candidate_id;
  v_cfg:=private.xzrecruiter_step6_configuration(p_agency,v_app.job_id);
  v_required:=coalesce(v_cfg->'requiredFields','[]'::jsonb);
  if jsonb_typeof(v_required)='array' then
    for v_field in select jsonb_array_elements_text(v_required) loop
      v_value:=coalesce(v_screen->'verifiedFacts'->v_field->'value',v_candidate->v_field,v_app_json->v_field);
      if v_value is null or v_value='null'::jsonb or v_value='""'::jsonb then
        v_reasons:=array_append(v_reasons,'MISSING_REQUIRED_FIELD:'||left(v_field,80));
      end if;
    end loop;
  end if;

  v_compliance:=coalesce(v_app_json->'metadata'->'compliance',v_app_json->'metadata'->'submission_compliance','{}'::jsonb);
  if coalesce((v_compliance->>'blocking')::boolean,false)=true
     or (jsonb_typeof(v_compliance->'blockers')='array' and jsonb_array_length(v_compliance->'blockers')>0)
     or (coalesce((v_cfg->>'requireCompliance')::boolean,false)=true and coalesce((v_compliance->>'satisfied')::boolean,false)=false) then
    v_reasons:=array_append(v_reasons,'BLOCKING_COMPLIANCE_REQUIREMENT');
  end if;

  if jsonb_typeof(v_screen->'conflicts')='array' and jsonb_array_length(v_screen->'conflicts')>0 then
    v_warnings:=array_append(v_warnings,'DATA_CONFLICT_REVIEW_REQUIRED');
  end if;

  return jsonb_build_object(
    'eligible',cardinality(v_reasons)=0,
    'reasons',to_jsonb(v_reasons),
    'warnings',to_jsonb(v_warnings),
    'candidacyState',coalesce(v_candidacy,'UNKNOWN'),
    'screening',v_screen,
    'resume',case when v_resume.id is null then '{}'::jsonb else jsonb_build_object('documentId',v_resume.id,'versionNumber',v_resume.version_number,'checksum',v_resume.checksum,'filename',v_resume.filename,'isLatest',true) end,
    'currentMatchId',v_match.id,
    'sourceFingerprint',private.xzrecruiter_step6_source_fingerprint(p_agency,p_application)
  );
exception when invalid_text_representation then
  return jsonb_build_object('eligible',false,'reasons',jsonb_build_array('INVALID_SCREENING_OR_CONFIGURATION_DATA'),'warnings','[]'::jsonb);
end;
$fn$;
revoke all on function private.xzrecruiter_step6_eligibility(uuid,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_submission_input(
  p_token text,p_application_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_app record;
  v_candidate jsonb;v_job jsonb;v_client jsonb;v_requirement jsonb;v_criteria jsonb;v_match jsonb;v_profile jsonb;
  v_eligibility jsonb;v_screen jsonb;v_commercial jsonb;v_current jsonb;v_current_version jsonb;v_reviews jsonb;v_versions jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_step6_submission_access(v_agency,v_user,v_business_role,p_application_id,false) then
    return jsonb_build_object('ok',false,'error','submission_access_forbidden');
  end if;

  select a.*,ps.code stage_code into v_app
  from public.applications a left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
  where a.agency_id=v_agency and a.id=p_application_id and a.archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;

  select jsonb_build_object(
    'id',c.id,'fullName',c.full_name,'currentTitle',c.current_title,'currentCompany',c.current_company,
    'experienceYears',c.experience_years,'relevantExperienceYears',c.relevant_experience_years,
    'skills',coalesce(c.skills,'[]'::jsonb),'location',concat_ws(', ',nullif(c.city,''),nullif(c.region,''),nullif(c.country_code,'')),
    'workplacePreference',c.workplace_preference,'availabilityStatus',c.availability_status,'noticePeriodDays',c.notice_period_days,
    'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'workAuthorization',coalesce(c.work_authorization_summary,'[]'::jsonb),
    'consentStatus',c.consent_status,'updatedAt',c.updated_at
  ) into v_candidate from public.candidates c where c.agency_id=v_agency and c.id=v_app.candidate_id;

  select jsonb_build_object('id',j.id,'title',j.title,'clientId',j.client_id,'approvedHiringBriefId',j.approved_hiring_brief_id,'updatedAt',j.updated_at)
  into v_job from public.recruitment_jobs j where j.agency_id=v_agency and j.id=v_app.job_id;

  select to_jsonb(cl) into v_client from public.recruitment_clients cl where cl.agency_id=v_agency and cl.id=v_app.client_id;

  select jsonb_build_object('id',hb.id,'versionNumber',hb.version_number,'hiringBrief',hb.hiring_brief,'structuredData',hb.structured_data,'approvedAt',hb.approved_at,'sourceFingerprint',hb.source_fingerprint)
  into v_requirement
  from public.requirement_hiring_briefs hb where hb.agency_id=v_agency and hb.id=(v_job->>'approvedHiringBriefId')::uuid and hb.brief_status='APPROVED';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',rc.id,'criterion_kind',rc.criterion_kind,'label',rc.label,'field_key',rc.field_key,'value_text',rc.value_text,
    'enforcement',rc.enforcement,'am_confirmed',rc.am_confirmed,'evidence',rc.evidence
  ) order by rc.sort_order,rc.created_at),'[]'::jsonb) into v_criteria
  from public.requirement_criteria rc where rc.agency_id=v_agency and rc.brief_id=(v_requirement->>'id')::uuid;

  select to_jsonb(x) into v_match from (
    select m.id,m.profile_version_id,m.run_status,m.score,m.match_band,m.confidence,m.coverage,m.hard_rule_status,
      m.hard_rule_results,m.requirement_results,m.strengths,m.gaps,m.uncertainties,m.recommendation,m.brief_id,m.brief_version,
      m.scoring_version,m.model_name,m.prompt_version,m.schema_version,m.generated_at
    from public.candidate_match_runs m where m.agency_id=v_agency and m.id=v_app.current_candidate_match_id
  ) x;
  select pv.profile_json into v_profile from public.candidate_profile_versions pv
  where pv.agency_id=v_agency and pv.id=nullif(v_match->>'profile_version_id','')::uuid;

  v_eligibility:=private.xzrecruiter_step6_eligibility(v_agency,p_application_id);
  v_screen:=coalesce(v_eligibility->'screening',private.xzrecruiter_step6_screening_snapshot(v_agency,p_application_id));
  v_commercial:=private.xzrecruiter_step6_commercial_snapshot(v_agency,p_application_id,v_business_role);

  select to_jsonb(s) into v_current from public.candidate_submissions s
  where s.agency_id=v_agency and s.application_id=p_application_id order by s.created_at desc limit 1;

  if v_current is not null then
    select jsonb_build_object(
      'id',sv.id,'versionNumber',sv.version_number,'sourceFingerprint',sv.source_fingerprint,
      'submissionPack',case when v_business_role in ('OWNER','ADMIN','ACCOUNT_MANAGER') then sv.submission_pack else sv.submission_pack-'commercialInternal' end,
      'clientFacingPack',sv.client_facing_pack,
      'eligibility',sv.eligibility_snapshot,'resumeDocumentId',sv.resume_document_id,'resumeVersionNumber',sv.resume_version_number,
      'requirementVersion',sv.requirement_version,'screeningVersion',sv.screening_version,'createdAt',sv.created_at
    ) into v_current_version
    from public.candidate_submission_versions sv where sv.agency_id=v_agency and sv.id=nullif(v_current->>'current_version_id','')::uuid;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc),'[]'::jsonb) into v_reviews
    from (select id,submission_version_number,decision,reason_code,note,checklist_snapshot,actor_user_id,created_at from public.candidate_submission_reviews where agency_id=v_agency and submission_id=(v_current->>'id')::uuid order by created_at desc limit 30) r;
    select coalesce(jsonb_agg(to_jsonb(v) order by v.version_number desc),'[]'::jsonb) into v_versions
    from (select id,version_number,source_fingerprint,resume_document_id,resume_version_number,requirement_version,screening_version,change_summary,generated_by_user_id,created_at from public.candidate_submission_versions where agency_id=v_agency and submission_id=(v_current->>'id')::uuid order by version_number desc limit 20) v;
  else
    v_current_version:='{}'::jsonb;v_reviews:='[]'::jsonb;v_versions:='[]'::jsonb;
  end if;

  return jsonb_build_object(
    'ok',true,'businessRole',v_business_role,'currentUserId',v_user,
    'application',jsonb_build_object('id',v_app.id,'candidateId',v_app.candidate_id,'jobId',v_app.job_id,'clientId',v_app.client_id,'stage',v_app.stage_code,'candidacyState',coalesce(to_jsonb(v_app)->>'candidacy_state',private.xzrecruiter_canonical_candidacy_state(v_app.stage_code)),'updatedAt',v_app.updated_at),
    'candidate',v_candidate,'job',v_job,'client',coalesce(v_client,'{}'::jsonb),'requirement',coalesce(v_requirement,'{}'::jsonb),
    'criteria',v_criteria,'candidateIntelligence',coalesce(v_match,'{}'::jsonb),'candidateProfile',coalesce(v_profile,'{}'::jsonb),
    'screening',v_screen,'resume',coalesce(v_eligibility->'resume','{}'::jsonb),'commercial',v_commercial,
    'configuration',private.xzrecruiter_step6_configuration(v_agency,v_app.job_id),'compliance',coalesce(to_jsonb(v_app)->'metadata'->'compliance','{}'::jsonb),
    'conflicts',coalesce(v_screen->'conflicts','[]'::jsonb),'eligibility',v_eligibility,
    'submission',case when v_business_role in ('OWNER','ADMIN','ACCOUNT_MANAGER') then coalesce(v_current,'{}'::jsonb) else coalesce(v_current,'{}'::jsonb)-'internal_commercial_snapshot'-'client_submission_snapshot' end,
    'currentVersion',coalesce(v_current_version,'{}'::jsonb),'reviewHistory',v_reviews,'versionHistory',v_versions
  );
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','submission_context_invalid_data');
end;
$fn$;

revoke all on function public.xzrecruiter_submission_input(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_submission_input(text,uuid) to anon,authenticated;

create or replace function public.xzrecruiter_generate_submission_pack(
  p_token text,p_application_id uuid,p_recruiter_context text default null,p_idempotency_key text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_app record;v_eligibility jsonb;v_screen jsonb;
  v_candidate jsonb;v_job jsonb;v_requirement jsonb;v_criteria jsonb;v_match jsonb;v_resume jsonb;v_commercial jsonb;v_cfg jsonb;
  v_submission uuid;v_state text;v_version integer;v_source text;v_existing record;v_idempotent jsonb;v_pack jsonb;v_client_pack jsonb;
  v_profile_version uuid;v_match_id uuid;v_change jsonb;v_previous integer;v_idem text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then return jsonb_build_object('ok',false,'error','recruiter_only'); end if;
  if not private.xzrecruiter_step6_submission_access(v_agency,v_user,v_business_role,p_application_id,true) then return jsonb_build_object('ok',false,'error','submission_access_forbidden'); end if;

  v_idem:=left(coalesce(nullif(btrim(p_idempotency_key),''),'generate:'||p_application_id::text||':'||private.xzrecruiter_step6_source_fingerprint(v_agency,p_application_id)),180);
  perform pg_advisory_xact_lock(hashtext(v_agency::text||'|STEP6_GENERATE|'||v_idem));
  select response_json into v_idempotent from public.candidate_submission_idempotency where agency_id=v_agency and operation='GENERATE' and idempotency_key=v_idem;
  if v_idempotent is not null then return v_idempotent; end if;

  v_eligibility:=private.xzrecruiter_step6_eligibility(v_agency,p_application_id);
  if coalesce((v_eligibility->>'eligible')::boolean,false)=false then
    return jsonb_build_object('ok',false,'error','submission_not_eligible','eligibility',v_eligibility);
  end if;
  v_source:=v_eligibility->>'sourceFingerprint';v_screen:=v_eligibility->'screening';v_resume:=v_eligibility->'resume';

  select a.*,ps.code stage_code into v_app from public.applications a left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency where a.agency_id=v_agency and a.id=p_application_id and a.archived_at is null for update of a;
  select jsonb_build_object('id',c.id,'fullName',c.full_name,'currentTitle',c.current_title,'currentCompany',c.current_company,'experienceYears',c.experience_years,'relevantExperienceYears',c.relevant_experience_years,'skills',coalesce(c.skills,'[]'::jsonb),'location',concat_ws(', ',nullif(c.city,''),nullif(c.region,''),nullif(c.country_code,'')),'workplacePreference',c.workplace_preference,'availabilityStatus',c.availability_status,'noticePeriodDays',c.notice_period_days,'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'workAuthorization',coalesce(c.work_authorization_summary,'[]'::jsonb),'updatedAt',c.updated_at) into v_candidate from public.candidates c where c.agency_id=v_agency and c.id=v_app.candidate_id;
  select jsonb_build_object('id',j.id,'title',j.title,'clientId',j.client_id,'approvedHiringBriefId',j.approved_hiring_brief_id,'updatedAt',j.updated_at) into v_job from public.recruitment_jobs j where j.agency_id=v_agency and j.id=v_app.job_id;
  select jsonb_build_object('id',hb.id,'versionNumber',hb.version_number,'hiringBrief',hb.hiring_brief,'structuredData',hb.structured_data,'approvedAt',hb.approved_at,'sourceFingerprint',hb.source_fingerprint) into v_requirement from public.requirement_hiring_briefs hb where hb.agency_id=v_agency and hb.id=(v_job->>'approvedHiringBriefId')::uuid and hb.brief_status='APPROVED';
  select coalesce(jsonb_agg(jsonb_build_object('id',rc.id,'kind',rc.criterion_kind,'label',rc.label,'fieldKey',rc.field_key,'value',rc.value_text,'enforcement',rc.enforcement,'amConfirmed',rc.am_confirmed) order by rc.sort_order,rc.created_at),'[]'::jsonb) into v_criteria from public.requirement_criteria rc where rc.agency_id=v_agency and rc.brief_id=(v_requirement->>'id')::uuid;
  select to_jsonb(x) into v_match from (select m.id,m.profile_version_id,m.run_status,m.score,m.match_band,m.hard_rule_status,m.requirement_results,m.strengths,m.gaps,m.uncertainties,m.recommendation,m.brief_id,m.brief_version,m.scoring_version,m.model_name,m.prompt_version,m.schema_version,m.generated_at from public.candidate_match_runs m where m.agency_id=v_agency and m.id=v_app.current_candidate_match_id) x;
  v_match_id:=nullif(v_match->>'id','')::uuid;v_profile_version:=nullif(v_match->>'profile_version_id','')::uuid;
  v_commercial:=private.xzrecruiter_step6_commercial_snapshot(v_agency,p_application_id,'ACCOUNT_MANAGER');v_cfg:=private.xzrecruiter_step6_configuration(v_agency,v_app.job_id);

  select id,workflow_status,latest_version_number into v_submission,v_state,v_previous from public.candidate_submissions where agency_id=v_agency and application_id=p_application_id order by created_at desc limit 1 for update;
  if v_submission is not null and v_state in ('INTERNAL_SUBMITTED','AM_APPROVED','CLIENT_SUBMITTED') then return jsonb_build_object('ok',false,'error','submission_locked_for_review','workflow_status',v_state); end if;
  if v_submission is not null then
    select id,version_number into v_existing from public.candidate_submission_versions where agency_id=v_agency and submission_id=v_submission and source_fingerprint=v_source limit 1;
    if v_existing.id is not null then
      update public.candidate_submissions set current_version_id=v_existing.id,latest_version_number=greatest(latest_version_number,v_existing.version_number),latest_source_fingerprint=v_source,recruiter_context=nullif(left(btrim(coalesce(p_recruiter_context,'')),1200),''),updated_at=now() where id=v_submission and agency_id=v_agency;
      v_idempotent:=jsonb_build_object('ok',true,'reused',true,'submissionId',v_submission,'versionId',v_existing.id,'versionNumber',v_existing.version_number,'workflowStatus',coalesce(v_state,'DRAFT'),'eligibility',v_eligibility);
      insert into public.candidate_submission_idempotency(agency_id,submission_id,operation,idempotency_key,request_fingerprint,response_json,actor_user_id) values(v_agency,v_submission,'GENERATE',v_idem,v_source,v_idempotent,v_user) on conflict(agency_id,operation,idempotency_key) do nothing;
      return v_idempotent;
    end if;
  end if;

  if v_submission is null then
    v_submission:=gen_random_uuid();
    insert into public.candidate_submissions(id,agency_id,application_id,candidate_id,job_id,client_id,status,workflow_status,am_review_status,created_by_user_id,recruiter_context,latest_source_fingerprint)
    values(v_submission,v_agency,p_application_id,v_app.candidate_id,v_app.job_id,v_app.client_id,'DRAFT','DRAFT','NOT_REQUESTED',v_user,nullif(left(btrim(coalesce(p_recruiter_context,'')),1200),''),v_source);
    v_previous:=0;
  end if;
  v_version:=coalesce(v_previous,0)+1;

  -- Submission pack is constructed server-side from approved/versioned sources; clients cannot inject factual pack fields.
  v_pack:=jsonb_build_object(
    'schemaVersion','xz-submission-pack-v1','promptVersion','xz-submission-pack-2026-09-25-v1','generatedAt',now(),'sourceFingerprint',v_source,
    'candidateSummary',jsonb_build_object('name',jsonb_build_object('value',v_candidate->>'fullName','provenance','RESUME'),'currentTitle',jsonb_build_object('value',v_candidate->>'currentTitle','provenance','RESUME'),'currentCompany',jsonb_build_object('value',v_candidate->>'currentCompany','provenance','RESUME'),'experienceYears',jsonb_build_object('value',v_candidate->'experienceYears','provenance','RESUME')),
    'whyCandidateFits',coalesce(v_match->'strengths','[]'::jsonb),'relevantExperience',jsonb_build_object('total',v_candidate->'experienceYears','relevant',v_candidate->'relevantExperienceYears','provenance','RESUME'),
    'mustHaveMatch',coalesce(v_match->'requirement_results','[]'::jsonb),'keySkills',coalesce(v_candidate->'skills','[]'::jsonb),'roleDomainRelevance',coalesce(v_match->'requirement_results','[]'::jsonb),
    'candidateInterest',jsonb_build_object('value',case when coalesce((v_screen->>'interestConfirmed')::boolean,false) then 'CONFIRMED' else null end,'provenance',case when coalesce((v_screen->>'interestConfirmed')::boolean,false) then 'RECRUITER_VERIFIED' else 'UNKNOWN' end),
    'availability',jsonb_build_object('status',coalesce(v_screen->'verifiedFacts'->'availability'->'value',v_candidate->'availabilityStatus'),'noticePeriodDays',coalesce(v_screen->'verifiedFacts'->'noticePeriodDays'->'value',v_candidate->'noticePeriodDays'),'provenance','RECRUITER_VERIFIED'),
    'locationWorkModel',jsonb_build_object('location',v_candidate->'location','workModel',v_candidate->'workplacePreference','provenance','RESUME'),
    'compensation',jsonb_build_object('value',v_commercial->'client'->'candidateCompensation','currency',v_commercial->'client'->'currency','provenance','RECRUITER_VERIFIED'),
    'workAuthorization',jsonb_build_object('value',v_candidate->'workAuthorization','provenance',case when coalesce(v_screen->'verifiedFacts'->'workAuthorization','null'::jsonb)<>'null'::jsonb then 'RECRUITER_VERIFIED' else 'CANDIDATE_DECLARED' end),
    'confirmedStrengths',coalesce(v_match->'strengths','[]'::jsonb),'knownGaps',coalesce(v_match->'gaps','[]'::jsonb),'openRisksUncertainties',coalesce(v_match->'uncertainties','[]'::jsonb),
    'recruiterScreeningSummary',jsonb_build_object('value',v_screen->>'summary','provenance',case when nullif(v_screen->>'summary','') is null then 'UNKNOWN' else 'RECRUITER_VERIFIED' end),
    'resumeVersion',jsonb_build_object('value',v_resume,'provenance','DOCUMENT_VERIFIED'),
    'recruiter',jsonb_build_object('value',jsonb_build_object('id',coalesce(nullif(v_screen->>'recruiterId','')::uuid,v_user)),'provenance','RECRUITER_VERIFIED'),
    'requirement',jsonb_build_object('value',v_requirement,'provenance','CLIENT_CONFIRMED'),
    'commercialInternal',v_commercial->'internal','conflicts',coalesce(v_screen->'conflicts','[]'::jsonb),'eligibility',v_eligibility
  );
  v_client_pack:=jsonb_build_object(
    'schemaVersion',v_pack->'schemaVersion','generatedAt',v_pack->'generatedAt','candidateSummary',v_pack->'candidateSummary',
    'whyCandidateFits',v_pack->'whyCandidateFits','relevantExperience',v_pack->'relevantExperience','mustHaveMatch',v_pack->'mustHaveMatch',
    'keySkills',v_pack->'keySkills','roleDomainRelevance',v_pack->'roleDomainRelevance','candidateInterest',v_pack->'candidateInterest',
    'availability',v_pack->'availability','locationWorkModel',v_pack->'locationWorkModel','workAuthorization',v_pack->'workAuthorization',
    'confirmedStrengths',v_pack->'confirmedStrengths','knownGaps',v_pack->'knownGaps','openRisksUncertainties',v_pack->'openRisksUncertainties',
    'recruiterScreeningSummary',v_pack->'recruiterScreeningSummary','resumeVersion',v_pack->'resumeVersion','requirement',v_pack->'requirement','conflicts',v_pack->'conflicts'
  );
  if coalesce((v_cfg->>'includeCandidateCompensationForClient')::boolean,false)=true then v_client_pack:=v_client_pack||jsonb_build_object('compensation',v_pack->'compensation'); end if;
  v_change:=jsonb_build_object('previousVersion',nullif(v_previous,0),'sourceChanged',true,'reason',case when v_state='RETURNED_TO_RECRUITER' then 'RETURN_RESOLUTION' else 'SOURCE_UPDATE_OR_FIRST_GENERATION' end);

  insert into public.candidate_submission_versions(
    agency_id,submission_id,application_id,candidate_id,job_id,client_id,version_number,source_fingerprint,
    candidate_snapshot,requirement_snapshot,requirement_version,hiring_brief_id,candidate_match_id,candidate_profile_version_id,
    screening_snapshot,screening_version,submission_pack,client_facing_pack,provenance_map,resume_document_id,resume_version_number,resume_checksum,
    internal_commercial_snapshot,client_commercial_snapshot,eligibility_snapshot,change_summary,generator_version,generated_by_user_id
  ) values(
    v_agency,v_submission,p_application_id,v_app.candidate_id,v_app.job_id,v_app.client_id,v_version,v_source,
    v_candidate,v_requirement,nullif(v_requirement->>'versionNumber','')::integer,nullif(v_requirement->>'id','')::uuid,v_match_id,v_profile_version,
    v_screen,v_screen->>'version',v_pack,v_client_pack,jsonb_build_object('requirement','CLIENT_CONFIRMED','resume','DOCUMENT_VERIFIED','candidateIntelligence','AI_DERIVED','screening','RECRUITER_VERIFIED'),
    (v_resume->>'documentId')::uuid,nullif(v_resume->>'versionNumber','')::integer,v_resume->>'checksum',v_commercial->'internal',v_commercial->'client',v_eligibility,v_change,'xz-submission-pack-2026-09-25-v1',v_user
  ) returning id into v_existing.id;

  update public.candidate_submissions set current_version_id=v_existing.id,latest_version_number=v_version,latest_source_fingerprint=v_source,recruiter_context=nullif(left(btrim(coalesce(p_recruiter_context,'')),1200),''),summary=left(coalesce(v_screen->>'summary',v_candidate->>'currentTitle','Candidate submission'),1500),salary_expectation=nullif(v_commercial->'client'->>'candidateCompensation','')::numeric,salary_currency=nullif(upper(v_commercial->'client'->>'currency'),''),availability=coalesce(v_screen->'verifiedFacts'->'availability'->>'value',v_candidate->>'availabilityStatus'),notice_period_days=coalesce(nullif(v_screen->'verifiedFacts'->'noticePeriodDays'->>'value','')::integer,nullif(v_candidate->>'noticePeriodDays','')::integer),document_ids=jsonb_build_array(v_resume->'documentId'),internal_commercial_snapshot=v_commercial->'internal',client_commercial_snapshot=v_commercial->'client',workflow_status=case when workflow_status='RETURNED_TO_RECRUITER' then 'RETURNED_TO_RECRUITER' else 'DRAFT' end,updated_at=now() where id=v_submission and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',p_application_id,'submission.pack_generated','Versioned AI Submission Pack generated',jsonb_build_object('submission_id',v_submission,'version_number',v_version,'source_fingerprint',v_source));
  v_idempotent:=jsonb_build_object('ok',true,'reused',false,'submissionId',v_submission,'versionId',v_existing.id,'versionNumber',v_version,'workflowStatus',case when v_state='RETURNED_TO_RECRUITER' then 'RETURNED_TO_RECRUITER' else 'DRAFT' end,'eligibility',v_eligibility);
  insert into public.candidate_submission_idempotency(agency_id,submission_id,operation,idempotency_key,request_fingerprint,response_json,actor_user_id) values(v_agency,v_submission,'GENERATE',v_idem,v_source,v_idempotent,v_user) on conflict(agency_id,operation,idempotency_key) do nothing;
  return v_idempotent;
exception when unique_violation then
  select jsonb_build_object('ok',true,'reused',true,'submissionId',sv.submission_id,'versionId',sv.id,'versionNumber',sv.version_number,'workflowStatus',s.workflow_status,'eligibility',sv.eligibility_snapshot)
  into v_idempotent from public.candidate_submission_versions sv join public.candidate_submissions s on s.id=sv.submission_id and s.agency_id=v_agency where sv.agency_id=v_agency and sv.source_fingerprint=v_source and sv.application_id=p_application_id order by sv.version_number desc limit 1;
  return coalesce(v_idempotent,jsonb_build_object('ok',false,'error','submission_concurrent_conflict'));
end;
$fn$;

revoke all on function public.xzrecruiter_generate_submission_pack(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_generate_submission_pack(text,uuid,text,text) to anon,authenticated;

create or replace function public.xzrecruiter_send_submission_to_am(
  p_token text,p_submission_id uuid,p_expected_version integer,p_expected_lock bigint,p_idempotency_key text
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_s record;v_current_source text;v_elig jsonb;v_resp jsonb;v_idem text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then return jsonb_build_object('ok',false,'error','recruiter_only'); end if;
  v_idem:=left(coalesce(nullif(btrim(p_idempotency_key),''),'send:'||p_submission_id::text||':'||p_expected_version::text),180);
  perform pg_advisory_xact_lock(hashtext(v_agency::text||'|STEP6_SEND|'||p_submission_id::text));
  select response_json into v_resp from public.candidate_submission_idempotency where agency_id=v_agency and operation='SEND_TO_AM' and idempotency_key=v_idem;
  if v_resp is not null then return v_resp; end if;
  select * into v_s from public.candidate_submissions where agency_id=v_agency and id=p_submission_id for update;
  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if not private.xzrecruiter_step6_submission_access(v_agency,v_user,v_business_role,v_s.application_id,true) then return jsonb_build_object('ok',false,'error','submission_access_forbidden'); end if;
  if v_s.latest_version_number<>p_expected_version or v_s.version_lock<>p_expected_lock then return jsonb_build_object('ok',false,'error','stale_submission_version','currentVersion',v_s.latest_version_number,'currentLock',v_s.version_lock); end if;
  if v_s.workflow_status not in ('DRAFT','RETURNED_TO_RECRUITER') then return jsonb_build_object('ok',false,'error','invalid_workflow_transition','from_state',v_s.workflow_status); end if;
  v_elig:=private.xzrecruiter_step6_eligibility(v_agency,v_s.application_id);
  if coalesce((v_elig->>'eligible')::boolean,false)=false then return jsonb_build_object('ok',false,'error','submission_not_eligible','eligibility',v_elig); end if;
  v_current_source:=v_elig->>'sourceFingerprint';
  if v_current_source is distinct from v_s.latest_source_fingerprint then return jsonb_build_object('ok',false,'error','submission_pack_stale','regenerateRequired',true); end if;
  if not exists(select 1 from public.candidate_submission_versions sv where sv.agency_id=v_agency and sv.id=v_s.current_version_id and sv.version_number=v_s.latest_version_number and sv.source_fingerprint=v_current_source) then return jsonb_build_object('ok',false,'error','submission_version_missing'); end if;

  update public.candidate_submissions set workflow_status='INTERNAL_SUBMITTED',am_review_status='PENDING',internal_submitted_at=now(),am_reviewed_by_user_id=null,am_reviewed_at=null,am_review_note=null,hold_reason=null,last_return_note=null,version_lock=version_lock+1,updated_at=now() where id=p_submission_id and agency_id=v_agency;
  insert into public.candidate_submission_reviews(agency_id,submission_id,application_id,submission_version_id,submission_version_number,decision,note,requirement_version,candidate_version,resume_version_number,actor_user_id)
  select v_agency,v_s.id,v_s.application_id,sv.id,sv.version_number,'RESUBMITTED',case when v_s.workflow_status='RETURNED_TO_RECRUITER' then 'Recruiter resolved return and resubmitted' else 'Recruiter submitted to AM Quality Gate' end,sv.requirement_version,sv.source_fingerprint,sv.resume_version_number,v_user from public.candidate_submission_versions sv where sv.id=v_s.current_version_id;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_s.application_id,case when v_s.workflow_status='RETURNED_TO_RECRUITER' then 'submission.recruiter_resubmitted' else 'submission.internal_submitted' end,'Candidate sent to Account Manager Quality Gate',jsonb_build_object('submission_id',v_s.id,'version_number',v_s.latest_version_number));
  v_resp:=jsonb_build_object('ok',true,'workflowStatus','INTERNAL_SUBMITTED','amReviewStatus','PENDING','versionNumber',v_s.latest_version_number,'versionLock',v_s.version_lock+1);
  insert into public.candidate_submission_idempotency(agency_id,submission_id,operation,idempotency_key,request_fingerprint,response_json,actor_user_id) values(v_agency,v_s.id,'SEND_TO_AM',v_idem,v_current_source,v_resp,v_user) on conflict(agency_id,operation,idempotency_key) do nothing;
  return v_resp;
end;
$fn$;
revoke all on function public.xzrecruiter_send_submission_to_am(text,uuid,integer,bigint,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_send_submission_to_am(text,uuid,integer,bigint,text) to anon,authenticated;

create or replace function public.xzrecruiter_start_submission_review(
  p_token text,p_submission_id uuid,p_expected_lock bigint
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_s record;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;
  select * into v_s from public.candidate_submissions where agency_id=v_agency and id=p_submission_id for update;
  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if v_s.workflow_status<>'INTERNAL_SUBMITTED' then return jsonb_build_object('ok',false,'error','invalid_workflow_transition','from_state',v_s.workflow_status); end if;
  if v_s.version_lock<>p_expected_lock then return jsonb_build_object('ok',false,'error','stale_submission_version','currentLock',v_s.version_lock); end if;
  insert into public.candidate_submission_reviews(agency_id,submission_id,application_id,submission_version_id,submission_version_number,decision,note,actor_user_id)
  values(v_agency,v_s.id,v_s.application_id,v_s.current_version_id,v_s.latest_version_number,'START_REVIEW','AM review opened',v_user);
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_s.application_id,'submission.am_review_started','Account Manager started Quality Gate review',jsonb_build_object('submission_id',v_s.id,'version_number',v_s.latest_version_number));
  return jsonb_build_object('ok',true,'workflowStatus',v_s.workflow_status,'versionNumber',v_s.latest_version_number,'versionLock',v_s.version_lock);
end;
$fn$;
revoke all on function public.xzrecruiter_start_submission_review(text,uuid,bigint) from public,anon,authenticated;
grant execute on function public.xzrecruiter_start_submission_review(text,uuid,bigint) to anon,authenticated;

create or replace function public.xzrecruiter_am_submission_decision(
  p_token text,p_submission_id uuid,p_action text,p_reason_code text default null,p_note text default null,
  p_checklist jsonb default '{}'::jsonb,p_expected_version integer default null,p_expected_lock bigint default null,p_idempotency_key text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_s record;v_sv record;v_action text:=upper(btrim(coalesce(p_action,'')));
  v_reason text:=upper(btrim(coalesce(p_reason_code,'')));v_next text;v_review text;v_event text;v_elig jsonb;v_source text;v_resp jsonb;v_idem text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;
  if v_action not in ('APPROVE','RETURN_TO_RECRUITER','ON_HOLD','DECLINE_INTERNAL') then return jsonb_build_object('ok',false,'error','invalid_review_action'); end if;
  if v_action in ('RETURN_TO_RECRUITER','DECLINE_INTERNAL') and v_reason not in ('MISSING_CANDIDATE_INFORMATION','SCREENING_INCOMPLETE','CLIENT_REQUIREMENT_MISMATCH','COMPENSATION_ISSUE','AVAILABILITY_ISSUE','RESUME_ISSUE','SKILL_EVIDENCE_INSUFFICIENT','WORK_AUTHORIZATION_CONCERN','PRESENTATION_QUALITY','DUPLICATE_SUBMISSION','OTHER') then return jsonb_build_object('ok',false,'error','structured_reason_required'); end if;
  if v_action='ON_HOLD' and nullif(btrim(coalesce(p_note,'')),'') is null then return jsonb_build_object('ok',false,'error','hold_note_required'); end if;
  v_idem:=left(coalesce(nullif(btrim(p_idempotency_key),''),'am:'||p_submission_id::text||':'||v_action||':'||coalesce(p_expected_version::text,'')),180);
  perform pg_advisory_xact_lock(hashtext(v_agency::text||'|STEP6_AM|'||p_submission_id::text));
  select response_json into v_resp from public.candidate_submission_idempotency where agency_id=v_agency and operation='AM_DECISION' and idempotency_key=v_idem;
  if v_resp is not null then return v_resp; end if;
  select * into v_s from public.candidate_submissions where agency_id=v_agency and id=p_submission_id for update;
  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if v_s.workflow_status<>'INTERNAL_SUBMITTED' then return jsonb_build_object('ok',false,'error','invalid_workflow_transition','from_state',v_s.workflow_status); end if;
  if p_expected_version is null or p_expected_lock is null or v_s.latest_version_number<>p_expected_version or v_s.version_lock<>p_expected_lock then return jsonb_build_object('ok',false,'error','stale_submission_version','currentVersion',v_s.latest_version_number,'currentLock',v_s.version_lock); end if;
  select * into v_sv from public.candidate_submission_versions where agency_id=v_agency and id=v_s.current_version_id and submission_id=v_s.id;
  if not found then return jsonb_build_object('ok',false,'error','submission_version_missing'); end if;
  v_elig:=private.xzrecruiter_step6_eligibility(v_agency,v_s.application_id);v_source:=v_elig->>'sourceFingerprint';
  if v_action='APPROVE' and (coalesce((v_elig->>'eligible')::boolean,false)=false or v_source is distinct from v_sv.source_fingerprint) then return jsonb_build_object('ok',false,'error','stale_approval_blocked','regenerateRequired',true,'eligibility',v_elig); end if;

  if v_action='APPROVE' then v_next:='AM_APPROVED';v_review:='APPROVED';v_event:='submission.am_approved';
  elsif v_action='RETURN_TO_RECRUITER' then v_next:='RETURNED_TO_RECRUITER';v_review:='RETURNED_TO_RECRUITER';v_event:='submission.am_returned';
  elsif v_action='DECLINE_INTERNAL' then v_next:='AM_REJECTED';v_review:='REJECTED';v_event:='submission.am_rejected';
  else v_next:='INTERNAL_SUBMITTED';v_review:='PENDING';v_event:='submission.on_hold'; end if;

  update public.candidate_submissions set workflow_status=v_next,am_review_status=v_review,am_reviewed_by_user_id=v_user,am_reviewed_at=now(),am_review_note=nullif(left(btrim(coalesce(p_note,'')),1500),''),hold_reason=case when v_action='ON_HOLD' then nullif(left(btrim(coalesce(p_note,'')),1500),'') else null end,last_return_reason_code=case when v_action='RETURN_TO_RECRUITER' then v_reason else last_return_reason_code end,last_return_note=case when v_action='RETURN_TO_RECRUITER' then nullif(left(btrim(coalesce(p_note,'')),1500),'') else last_return_note end,version_lock=version_lock+1,updated_at=now() where id=v_s.id and agency_id=v_agency;
  insert into public.candidate_submission_reviews(agency_id,submission_id,application_id,submission_version_id,submission_version_number,decision,reason_code,note,checklist_snapshot,requirement_version,candidate_version,resume_version_number,actor_user_id)
  values(v_agency,v_s.id,v_s.application_id,v_sv.id,v_sv.version_number,v_action,nullif(v_reason,''),nullif(left(btrim(coalesce(p_note,'')),1500),''),coalesce(p_checklist,'{}'::jsonb),v_sv.requirement_version,v_sv.source_fingerprint,v_sv.resume_version_number,v_user);
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_s.application_id,v_event,case v_action when 'APPROVE' then 'AM Quality Gate approved' when 'RETURN_TO_RECRUITER' then 'AM returned submission to recruiter' when 'DECLINE_INTERNAL' then 'AM declined internal submission' else 'AM placed submission on hold' end,jsonb_build_object('submission_id',v_s.id,'version_number',v_sv.version_number,'reason_code',nullif(v_reason,''),'note',nullif(left(coalesce(p_note,''),500),'')));
  v_resp:=jsonb_build_object('ok',true,'workflowStatus',v_next,'amReviewStatus',v_review,'decision',v_action,'versionNumber',v_sv.version_number,'versionLock',v_s.version_lock+1);
  insert into public.candidate_submission_idempotency(agency_id,submission_id,operation,idempotency_key,request_fingerprint,response_json,actor_user_id) values(v_agency,v_s.id,'AM_DECISION',v_idem,v_sv.source_fingerprint,v_resp,v_user) on conflict(agency_id,operation,idempotency_key) do nothing;
  return v_resp;
end;
$fn$;
revoke all on function public.xzrecruiter_am_submission_decision(text,uuid,text,text,text,jsonb,integer,bigint,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_am_submission_decision(text,uuid,text,text,text,jsonb,integer,bigint,text) to anon,authenticated;

-- Override legacy AM review entry point so it cannot bypass Step-6 structured decisions/version checks.
create or replace function public.xzrecruiter_review_internal_submission(p_token text,p_submission_id uuid,p_action text,p_note text default null)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $fn$
begin
  return jsonb_build_object('ok',false,'error','step6_quality_gate_endpoint_required');
end;$fn$;

create or replace function public.xzrecruiter_client_submit(
  p_token text,p_submission_id uuid,p_client_contact jsonb default '{}'::jsonb,p_expected_version integer default null,p_expected_lock bigint default null,p_idempotency_key text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_s record;v_sv record;v_elig jsonb;v_source text;v_resp jsonb;v_idem text;v_snapshot jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','client_submit_forbidden'); end if;
  v_idem:=left(coalesce(nullif(btrim(p_idempotency_key),''),'client:'||p_submission_id::text||':'||coalesce(p_expected_version::text,'')),180);
  perform pg_advisory_xact_lock(hashtext(v_agency::text||'|STEP6_CLIENT|'||p_submission_id::text));
  select response_json into v_resp from public.candidate_submission_idempotency where agency_id=v_agency and operation='CLIENT_SUBMIT' and idempotency_key=v_idem;
  if v_resp is not null then return v_resp; end if;
  select * into v_s from public.candidate_submissions where agency_id=v_agency and id=p_submission_id for update;
  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if v_s.workflow_status='CLIENT_SUBMITTED' then return jsonb_build_object('ok',true,'reused',true,'workflowStatus','CLIENT_SUBMITTED','submittedAt',v_s.client_submitted_at,'versionNumber',v_s.client_submission_version_number); end if;
  if v_s.workflow_status<>'AM_APPROVED' then return jsonb_build_object('ok',false,'error','submission_not_am_approved','workflow_status',v_s.workflow_status); end if;
  if p_expected_version is null or p_expected_lock is null or v_s.latest_version_number<>p_expected_version or v_s.version_lock<>p_expected_lock then return jsonb_build_object('ok',false,'error','stale_submission_version','currentVersion',v_s.latest_version_number,'currentLock',v_s.version_lock); end if;
  select * into v_sv from public.candidate_submission_versions where agency_id=v_agency and id=v_s.current_version_id and submission_id=v_s.id;
  if not found then return jsonb_build_object('ok',false,'error','submission_version_missing'); end if;
  v_elig:=private.xzrecruiter_step6_eligibility(v_agency,v_s.application_id);v_source:=v_elig->>'sourceFingerprint';
  if coalesce((v_elig->>'eligible')::boolean,false)=false or v_source is distinct from v_sv.source_fingerprint then return jsonb_build_object('ok',false,'error','stale_client_submission_blocked','regenerateRequired',true,'eligibility',v_elig); end if;
  if exists(select 1 from public.candidate_submissions d where d.agency_id=v_agency and d.id<>v_s.id and d.candidate_id=v_s.candidate_id and d.job_id=v_s.job_id and d.client_id is not distinct from v_s.client_id and d.workflow_status='CLIENT_SUBMITTED') then return jsonb_build_object('ok',false,'error','duplicate_client_submission'); end if;

  v_snapshot:=jsonb_build_object('submissionId',v_s.id,'submissionVersionId',v_sv.id,'submissionVersionNumber',v_sv.version_number,'candidateId',v_s.candidate_id,'jobId',v_s.job_id,'clientId',v_s.client_id,'clientContact',coalesce(p_client_contact,'{}'::jsonb),'pack',v_sv.client_facing_pack,'resume',jsonb_build_object('documentId',v_sv.resume_document_id,'versionNumber',v_sv.resume_version_number,'checksum',v_sv.resume_checksum),'commercial',v_sv.client_commercial_snapshot,'requirementVersion',v_sv.requirement_version,'sourceFingerprint',v_sv.source_fingerprint,'submittedBy',v_user,'submittedAt',now());
  update public.candidate_submissions set workflow_status='CLIENT_SUBMITTED',status='SUBMITTED',submitted_at=coalesce(submitted_at,now()),client_submitted_at=now(),submitted_by_user_id=v_user,client_contact_snapshot=coalesce(p_client_contact,'{}'::jsonb),client_submission_snapshot=v_snapshot,client_submission_version_number=v_sv.version_number,client_resume_document_id=v_sv.resume_document_id,client_resume_version_number=v_sv.resume_version_number,client_commercial_snapshot=v_sv.client_commercial_snapshot,version_lock=version_lock+1,updated_at=now() where id=v_s.id and agency_id=v_agency;
  update public.applications set submitted_at=coalesce(submitted_at,now()),last_activity_at=now(),updated_at=now() where id=v_s.application_id and agency_id=v_agency;
  insert into public.candidate_submission_reviews(agency_id,submission_id,application_id,submission_version_id,submission_version_number,decision,note,requirement_version,candidate_version,resume_version_number,actor_user_id) values(v_agency,v_s.id,v_s.application_id,v_sv.id,v_sv.version_number,'CLIENT_SUBMITTED','Exact approved version released to client',v_sv.requirement_version,v_sv.source_fingerprint,v_sv.resume_version_number,v_user);
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_s.application_id,'submission.client_submitted','AM released exact approved Submission Pack to client',jsonb_build_object('submission_id',v_s.id,'version_number',v_sv.version_number,'resume_document_id',v_sv.resume_document_id,'resume_version_number',v_sv.resume_version_number));
  v_resp:=jsonb_build_object('ok',true,'reused',false,'workflowStatus','CLIENT_SUBMITTED','versionNumber',v_sv.version_number,'versionLock',v_s.version_lock+1,'submittedAt',now());
  insert into public.candidate_submission_idempotency(agency_id,submission_id,operation,idempotency_key,request_fingerprint,response_json,actor_user_id) values(v_agency,v_s.id,'CLIENT_SUBMIT',v_idem,v_sv.source_fingerprint,v_resp,v_user) on conflict(agency_id,operation,idempotency_key) do nothing;
  return v_resp;
end;
$fn$;
revoke all on function public.xzrecruiter_client_submit(text,uuid,jsonb,integer,bigint,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_client_submit(text,uuid,jsonb,integer,bigint,text) to anon,authenticated;

-- Legacy direct client-submit RPC cannot bypass exact Step-6 version/snapshot controls.
create or replace function public.xzrecruiter_mark_client_submitted(p_token text,p_submission_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $fn$
begin
  return jsonb_build_object('ok',false,'error','step6_client_submit_endpoint_required');
end;$fn$;

create or replace function public.xzrecruiter_submission_queue(
  p_token text,p_bucket text default 'WAITING_FOR_REVIEW',p_limit integer default 30,p_offset integer default 0
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_bucket text:=upper(coalesce(p_bucket,'WAITING_FOR_REVIEW'));v_limit integer:=greatest(1,least(coalesce(p_limit,30),100));v_offset integer:=greatest(0,coalesce(p_offset,0));v_rows jsonb;v_total bigint;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','am_only'); end if;
  if v_bucket not in ('WAITING_FOR_REVIEW','RETURNED_AWAITING_RECRUITER','READY_APPROVED','RECENTLY_CLIENT_SUBMITTED','CLIENT_FEEDBACK_PENDING') then return jsonb_build_object('ok',false,'error','invalid_queue_bucket'); end if;
  with base as (
    select s.id,s.application_id,s.candidate_id,s.job_id,s.client_id,s.workflow_status,s.am_review_status,s.latest_version_number,s.version_lock,s.internal_submitted_at,s.client_submitted_at,s.hold_reason,s.last_return_reason_code,s.updated_at,
      c.full_name candidate_name,j.title requirement_title,u.display_name recruiter_name,
      extract(epoch from (now()-coalesce(s.internal_submitted_at,s.updated_at)))::bigint age_seconds,
      coalesce(sv.eligibility_snapshot->'warnings','[]'::jsonb) quality_risk_indicators,
      coalesce(sv.submission_pack->'openRisksUncertainties','[]'::jsonb) unresolved_risks
    from public.candidate_submissions s
    join public.candidates c on c.id=s.candidate_id and c.agency_id=v_agency
    join public.recruitment_jobs j on j.id=s.job_id and j.agency_id=v_agency
    left join public.users u on u.id=s.created_by_user_id
    left join public.candidate_submission_versions sv on sv.id=s.current_version_id and sv.agency_id=v_agency
    where s.agency_id=v_agency and case v_bucket
      when 'WAITING_FOR_REVIEW' then s.workflow_status='INTERNAL_SUBMITTED'
      when 'RETURNED_AWAITING_RECRUITER' then s.workflow_status='RETURNED_TO_RECRUITER'
      when 'READY_APPROVED' then s.workflow_status='AM_APPROVED'
      when 'RECENTLY_CLIENT_SUBMITTED' then s.workflow_status='CLIENT_SUBMITTED' and s.client_submitted_at>now()-interval '14 days'
      else s.workflow_status='CLIENT_SUBMITTED'
    end
  ), counted as (select count(*) n from base), paged as (select * from base order by coalesce(internal_submitted_at,client_submitted_at,updated_at) desc limit v_limit offset v_offset)
  select coalesce((select jsonb_agg(to_jsonb(p)) from paged p),'[]'::jsonb),coalesce((select n from counted),0) into v_rows,v_total;
  return jsonb_build_object('ok',true,'bucket',v_bucket,'rows',v_rows,'total',v_total,'limit',v_limit,'offset',v_offset);
end;
$fn$;
revoke all on function public.xzrecruiter_submission_queue(text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_submission_queue(text,text,integer,integer) to anon,authenticated;
