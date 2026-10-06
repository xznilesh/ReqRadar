-- XZ Recruiter Step 4 candidate intelligence RPCs: completion, duplicate evidence, human review and talent discovery.

create or replace function public.xzrecruiter_complete_candidate_intelligence(
  p_token text,p_run_id uuid,p_profile_json jsonb,p_profile_hash text,p_source_fingerprint text,
  p_match_json jsonb,p_ai_meta jsonb,p_latency_ms integer,p_error_code text default null,p_error_detail text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_run record;
  v_candidate_updated timestamptz;v_parse_updated timestamptz;v_current_brief uuid;v_current_fingerprint text;
  v_scoring jsonb;v_profile uuid;v_profile_version integer;v_doc uuid;v_match uuid;v_profile_status text;
  v_email text;v_phone text;v_name text;v_company text;v_location text;v_source_ref text;v_checksum text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);

  select * into v_run
  from public.candidate_intelligence_jobs
  where id=p_run_id and agency_id=v_agency
  for update;
  if v_run.id is null then return jsonb_build_object('ok',false,'error','intelligence_job_not_found'); end if;
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,v_run.job_id,v_run.candidate_id) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;

  if nullif(coalesce(p_error_code,''),'') is not null then
    update public.candidate_intelligence_jobs
    set run_status='FAILED',model_resolved=nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
        provider_response_id=nullif(left(coalesce(p_ai_meta->>'providerResponseId',''),200),''),
        provider_usage=coalesce(p_ai_meta->'usage','{}'::jsonb),latency_ms=greatest(coalesce(p_latency_ms,0),0),
        error_code=left(p_error_code,120),error_detail=left(coalesce(p_error_detail,'AI execution failed; retry is safe.'),1000),
        completed_at=now()
    where id=p_run_id and agency_id=v_agency;
    return jsonb_build_object('ok',false,'error',left(p_error_code,120),'retry_safe',true);
  end if;

  select c.updated_at into v_candidate_updated
  from public.candidates c where c.id=v_run.candidate_id and c.agency_id=v_agency;

  if v_run.parse_run_id is not null then
    select pr.updated_at,d.id into v_parse_updated,v_doc
    from public.candidate_parse_runs pr
    left join public.candidate_documents d on d.id=pr.document_id and d.agency_id=v_agency
    where pr.id=v_run.parse_run_id and pr.agency_id=v_agency;
  end if;

  select j.approved_hiring_brief_id,hb.source_fingerprint
  into v_current_brief,v_current_fingerprint
  from public.recruitment_jobs j
  join public.requirement_hiring_briefs hb on hb.id=j.approved_hiring_brief_id and hb.agency_id=v_agency
  where j.id=v_run.job_id and j.agency_id=v_agency and j.recruiter_ready=true and hb.brief_status='APPROVED';

  v_scoring:=private.xzrecruiter_candidate_scoring_config(v_agency);

  if v_candidate_updated is distinct from v_run.candidate_updated_at_snapshot
     or v_current_brief is distinct from v_run.brief_id
     or coalesce(v_current_fingerprint,'') is distinct from coalesce(v_run.brief_source_fingerprint,'')
     or (v_run.parse_run_id is not null and v_parse_updated is distinct from v_run.parse_run_updated_at_snapshot)
     or coalesce(v_scoring->>'version','') is distinct from coalesce(v_run.scoring_version,'') then
    update public.candidate_intelligence_jobs
    set run_status='FAILED',error_code='stale_input_during_analysis',
        error_detail='Candidate, resume, approved requirement or scoring configuration changed during analysis. Recompute from fresh inputs.',
        latency_ms=greatest(coalesce(p_latency_ms,0),0),completed_at=now()
    where id=p_run_id and agency_id=v_agency;
    return jsonb_build_object('ok',false,'error','stale_input_during_analysis','recompute_required',true);
  end if;

  if nullif(btrim(coalesce(p_profile_hash,'')),'') is null then
    return jsonb_build_object('ok',false,'error','profile_hash_required');
  end if;

  select id,version_number into v_profile,v_profile_version
  from public.candidate_profile_versions
  where agency_id=v_agency and candidate_id=v_run.candidate_id and profile_hash=p_profile_hash
  limit 1;

  if v_profile is null then
    select coalesce(max(version_number),0)+1 into v_profile_version
    from public.candidate_profile_versions
    where agency_id=v_agency and candidate_id=v_run.candidate_id;

    update public.candidate_profile_versions
    set is_current=false,profile_status=case when profile_status='FAILED' then profile_status else 'SUPERSEDED' end
    where agency_id=v_agency and candidate_id=v_run.candidate_id and is_current=true;

    v_profile:=gen_random_uuid();
    v_profile_status:=case
      when jsonb_array_length(coalesce(p_profile_json#>'{signals,missingCriticalInformation}','[]'::jsonb))>0 then 'PARTIAL'
      else 'READY'
    end;

    insert into public.candidate_profile_versions(
      id,agency_id,candidate_id,document_id,parse_run_id,version_number,profile_status,profile_json,profile_hash,
      source_fingerprint,parser_version,model_name,prompt_version,schema_version,profile_schema_version,input_hash,is_current,created_by_user_id
    )
    select
      v_profile,v_agency,v_run.candidate_id,v_doc,v_run.parse_run_id,v_profile_version,v_profile_status,coalesce(p_profile_json,'{}'::jsonb),
      left(p_profile_hash,128),left(coalesce(p_source_fingerprint,v_run.input_hash),128),
      pr.parser_version,nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
      left(v_run.prompt_version,120),left(v_run.schema_version,120),'xz-candidate-profile-v2',left(v_run.input_hash,128),true,v_user
    from (select 1) one
    left join public.candidate_parse_runs pr on pr.id=v_run.parse_run_id and pr.agency_id=v_agency;

    insert into public.candidate_profile_skills(
      agency_id,candidate_id,profile_version_id,original_value,normalized_value,confidence,estimated_years,evidence
    )
    select v_agency,v_run.candidate_id,v_profile,s->>'original',s->>'normalized',
      greatest(0,least(1,coalesce(nullif(s->>'confidence','')::numeric,0))),
      nullif(s->>'estimatedYears','')::numeric,coalesce(s->'evidence','[]'::jsonb)
    from jsonb_array_elements(coalesce(p_profile_json->'skills','[]'::jsonb)) s
    where nullif(btrim(coalesce(s->>'normalized','')),'') is not null
    on conflict(profile_version_id,normalized_value) do nothing;

    update public.candidates
    set current_intelligence_profile_id=v_profile
    where id=v_run.candidate_id and agency_id=v_agency;
  else
    update public.candidate_profile_versions set is_current=(id=v_profile)
    where agency_id=v_agency and candidate_id=v_run.candidate_id;
    update public.candidates set current_intelligence_profile_id=v_profile
    where id=v_run.candidate_id and agency_id=v_agency;
  end if;

  update public.candidate_match_runs
  set run_status='STALE',stale_at=now(),stale_reason=case
    when brief_id<>v_run.brief_id then 'APPROVED_REQUIREMENT_CHANGED'
    when profile_version_id<>v_profile then 'CANDIDATE_PROFILE_CHANGED'
    when scoring_version<>v_run.scoring_version then 'SCORING_CONFIG_CHANGED'
    else 'RECOMPUTED'
  end
  where agency_id=v_agency and application_id=v_run.application_id and run_status='SUCCEEDED';

  v_match:=gen_random_uuid();
  insert into public.candidate_match_runs(
    id,agency_id,job_id,candidate_id,application_id,intelligence_job_id,brief_id,brief_version,profile_version_id,
    scoring_config_id,scoring_version,model_name,prompt_version,schema_version,match_schema_version,input_hash,run_status,score,match_band,
    confidence,coverage,hard_rule_status,component_scores,hard_rule_results,requirement_results,strengths,gaps,uncertainties,evidence_meta,
    recommendation
  )
  select
    v_match,v_agency,v_run.job_id,v_run.candidate_id,v_run.application_id,v_run.id,v_run.brief_id,hb.version_number,v_profile,
    nullif(v_scoring->>'id','')::uuid,v_run.scoring_version,nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
    v_run.prompt_version,v_run.schema_version,'xz-candidate-match-v2',v_run.input_hash,'SUCCEEDED',
    nullif(p_match_json->>'score','')::numeric,nullif(p_match_json->>'band',''),
    nullif(p_match_json->>'confidence','')::numeric,nullif(p_match_json->>'coverage','')::numeric,
    nullif(p_match_json->>'hardRuleStatus',''),coalesce(p_match_json->'components','{}'::jsonb),
    coalesce(p_match_json->'hardRules','[]'::jsonb),coalesce(p_match_json->'requirementResults','[]'::jsonb),coalesce(p_match_json->'strengths','[]'::jsonb),
    coalesce(p_match_json->'gaps','[]'::jsonb),coalesce(p_match_json->'uncertainties','[]'::jsonb),
    coalesce(p_match_json->'evidenceMeta','{}'::jsonb),nullif(p_match_json->>'recommendation','')
  from public.requirement_hiring_briefs hb
  where hb.id=v_run.brief_id and hb.agency_id=v_agency;

  update public.applications
  set current_candidate_match_id=v_match,intelligence_review_state='NOT_REVIEWED',intelligence_reviewed_at=null,updated_at=now()
  where id=v_run.application_id and agency_id=v_agency;

  -- Explainable duplicate scan. Same-tenant only. Never auto-merges.
  v_email:=lower(coalesce(p_profile_json#>>'{identity,email,normalized}',''));
  v_phone:=coalesce(p_profile_json#>>'{identity,phone,normalized}','');
  v_name:=lower(coalesce(p_profile_json#>>'{identity,name,normalized}',''));
  v_company:=lower(coalesce(p_profile_json#>>'{professional,currentCompany,normalized}',''));
  v_location:=lower(coalesce(p_profile_json#>>'{identity,location,normalized}',''));
  select regexp_replace(split_part(lower(btrim(coalesce(a.source_reference,''))),'?',1),'/+$','') into v_source_ref
  from public.applications a where a.id=v_run.application_id and a.agency_id=v_agency;
  select d.checksum into v_checksum from public.candidate_documents d where d.id=v_doc and d.agency_id=v_agency;

  delete from public.candidate_duplicate_signals
  where agency_id=v_agency and profile_version_id=v_profile;

  insert into public.candidate_duplicate_signals(
    agency_id,candidate_id,compared_candidate_id,profile_version_id,duplicate_status,score,signals,algorithm_version
  )
  select v_agency,v_run.candidate_id,x.id,v_profile,
    case
      when x.exact_email or x.exact_phone or x.exact_resume or x.exact_source then 'exact_duplicate'
      when x.name_company and x.name_location then 'likely_duplicate'
      else 'possible_duplicate'
    end,
    case
      when x.exact_email or x.exact_phone or x.exact_resume or x.exact_source then 100
      when x.name_company and x.name_location then 80
      when x.name_company then 45 else 35
    end,
    jsonb_build_object(
      'exactEmail',x.exact_email,'exactPhone',x.exact_phone,'exactResume',x.exact_resume,'exactSourceReference',x.exact_source,
      'nameEmployer',x.name_company,'nameLocation',x.name_location
    ),
    'xz-duplicate-2026-09-25-v1'
  from (
    select c.id,
      (v_email<>'' and lower(btrim(coalesce(c.email,'')))=v_email) exact_email,
      (v_phone<>'' and c.phone=v_phone) exact_phone,
      (v_name<>'' and lower(btrim(coalesce(c.full_name,'')))=v_name and v_company<>'' and lower(btrim(coalesce(c.current_company,'')))=v_company) name_company,
      (v_name<>'' and lower(coalesce(c.full_name,''))=v_name and v_location<>'' and lower(trim(concat_ws(', ',c.city,c.region,c.country_code)))=v_location) name_location,
      (v_checksum is not null and exists(
        select 1 from public.candidate_documents d2
        where d2.agency_id=v_agency and d2.candidate_id=c.id and d2.archived_at is null and d2.checksum=v_checksum
      )) exact_resume,
      (v_source_ref<>'' and exists(
        select 1 from public.applications a2
        where a2.agency_id=v_agency and a2.candidate_id=c.id and a2.archived_at is null
          and regexp_replace(split_part(lower(btrim(coalesce(a2.source_reference,''))),'?',1),'/+$','')=v_source_ref
      )) exact_source
    from public.candidates c
    where c.agency_id=v_agency and c.id<>v_run.candidate_id and c.archived_at is null and c.merged_into_candidate_id is null
  ) x
  where x.exact_email or x.exact_phone or x.exact_resume or x.exact_source or x.name_company or x.name_location;

  update public.candidate_intelligence_jobs
  set run_status='SUCCEEDED',model_resolved=nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
      provider_response_id=nullif(left(coalesce(p_ai_meta->>'providerResponseId',''),200),''),
      provider_usage=coalesce(p_ai_meta->'usage','{}'::jsonb),latency_ms=greatest(coalesce(p_latency_ms,0),0),
      error_code=null,error_detail=null,completed_at=now()
  where id=p_run_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_run.application_id,'candidate.intelligence_generated','Candidate intelligence generated',
    jsonb_build_object('candidate_id',v_run.candidate_id,'job_id',v_run.job_id,'match_id',v_match,'profile_version_id',v_profile,
      'brief_id',v_run.brief_id,'score',p_match_json->'score','band',p_match_json->'band','hard_rule_status',p_match_json->'hardRuleStatus')
  );
  return jsonb_build_object('ok',true,'match_id',v_match,'profile_version_id',v_profile,'profile_version',v_profile_version,'run_id',p_run_id);
exception when unique_violation then
  return jsonb_build_object('ok',false,'error','candidate_intelligence_concurrent_conflict','retry_safe',true);
end;
$fn$;

create or replace function public.xzrecruiter_review_candidate_intelligence(
  p_token text,p_match_id uuid,p_action text,p_reason text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_match record;v_action text:=upper(coalesce(p_action,''));
  v_override boolean:=false;v_review uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_action not in ('ACKNOWLEDGE','PROCEED_TO_HUMAN_SCREENING','HOLD_FOR_CLARIFICATION') then
    return jsonb_build_object('ok',false,'error','invalid_review_action');
  end if;

  select m.*,a.current_candidate_match_id into v_match
  from public.candidate_match_runs m
  join public.applications a on a.id=m.application_id and a.agency_id=v_agency
  where m.id=p_match_id and m.agency_id=v_agency;
  if v_match.id is null then return jsonb_build_object('ok',false,'error','match_not_found'); end if;
  if v_match.run_status<>'SUCCEEDED' or v_match.current_candidate_match_id<>v_match.id then
    return jsonb_build_object('ok',false,'error','stale_match_recompute_required');
  end if;
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,v_match.job_id,v_match.candidate_id) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;

  v_override:=v_action='PROCEED_TO_HUMAN_SCREENING' and (
    coalesce(v_match.recommendation,'')<>'WORTH_SCREENING' or coalesce(v_match.hard_rule_status,'UNKNOWN')<>'PASS'
  );
  if v_override and nullif(btrim(coalesce(p_reason,'')),'') is null then
    return jsonb_build_object('ok',false,'error','override_reason_required');
  end if;

  v_review:=gen_random_uuid();
  insert into public.candidate_intelligence_reviews(
    id,agency_id,application_id,match_run_id,action,ai_recommendation,recruiter_override,reason,reviewer_user_id
  ) values(
    v_review,v_agency,v_match.application_id,v_match.id,v_action,v_match.recommendation,v_override,
    nullif(left(btrim(coalesce(p_reason,'')),1500),''),v_user
  );

  update public.applications
  set intelligence_review_state=case
      when v_action='PROCEED_TO_HUMAN_SCREENING' then 'PROCEED_TO_HUMAN_SCREENING'
      when v_action='HOLD_FOR_CLARIFICATION' then 'HOLD_FOR_CLARIFICATION'
      else 'REVIEWED'
    end,
    intelligence_reviewed_at=now(),updated_at=now()
  where id=v_match.application_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_match.application_id,'candidate.intelligence_reviewed','Recruiter reviewed candidate intelligence',
    jsonb_build_object('match_id',v_match.id,'action',v_action,'override',v_override,'reason',nullif(left(coalesce(p_reason,''),500),''))
  );
  return jsonb_build_object('ok',true,'review_id',v_review,'action',v_action,'override',v_override,
    'handoff',case when v_action='PROCEED_TO_HUMAN_SCREENING' then 'STEP_5_HUMAN_SCREENING' else null end);
end;
$fn$;

create or replace function public.xzrecruiter_talent_match_search(
  p_token text,p_job_id uuid,p_query text default '',p_limit integer default 30
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_brief uuid;
  v_q text:=lower(btrim(coalesce(p_query,'')));v_limit integer:=greatest(1,least(coalesce(p_limit,30),50));v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  select approved_hiring_brief_id into v_brief from public.recruitment_jobs
  where id=p_job_id and agency_id=v_agency and recruiter_ready=true and approved_hiring_brief_id is not null;
  if v_brief is null then return jsonb_build_object('ok',false,'error','approved_brief_required'); end if;

  with required_skills as (
    select distinct private.xzrecruiter_normalize_candidate_skill(c.value_text) skill
    from public.requirement_criteria c
    where c.agency_id=v_agency and c.brief_id=v_brief and c.criterion_kind='MUST_HAVE'
      and lower(c.field_key) ~ '(skill|technology|tool)'
      and nullif(btrim(c.value_text),'') is not null
  ), ranked as (
    select c.id,c.full_name,c.current_title,c.current_company,c.city,c.region,c.country_code,c.updated_at,
      c.owner_user_id,
      exists(select 1 from public.applications a where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=c.id and a.archived_at is null) already_on_requirement,
      (select count(*) from required_skills) required_skill_count,
      (
        select count(distinct rs.skill)
        from required_skills rs
        where exists(
          select 1 from public.candidate_profile_skills s
          where s.agency_id=v_agency and s.candidate_id=c.id and s.normalized_value=rs.skill
            and s.profile_version_id=c.current_intelligence_profile_id
        ) or exists(
          select 1 from jsonb_array_elements_text(coalesce(c.skills,'[]'::jsonb)) raw
          where private.xzrecruiter_normalize_candidate_skill(raw)=rs.skill
        )
      ) matched_skill_count,
      case when v_q='' then 0 else
        (case when lower(coalesce(c.full_name,'')) like '%'||v_q||'%' then 4 else 0 end)+
        (case when lower(coalesce(c.current_title,'')) like '%'||v_q||'%' then 3 else 0 end)+
        (case when lower(coalesce(c.current_company,'')) like '%'||v_q||'%' then 2 else 0 end)
      end lexical_score,
      (c.current_intelligence_profile_id is not null) intelligence_available
    from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and (
        v_q='' or lower(coalesce(c.full_name,'')) like '%'||v_q||'%'
        or lower(coalesce(c.current_title,'')) like '%'||v_q||'%'
        or lower(coalesce(c.current_company,'')) like '%'||v_q||'%'
        or lower(coalesce(c.city,'')) like '%'||v_q||'%'
        or exists(select 1 from jsonb_array_elements_text(coalesce(c.skills,'[]'::jsonb)) raw where lower(raw) like '%'||v_q||'%')
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'full_name',r.full_name,'current_title',r.current_title,'current_company',r.current_company,
    'city',r.city,'region',r.region,'country_code',r.country_code,'already_on_requirement',r.already_on_requirement,
    'required_skill_count',r.required_skill_count,'matched_skill_count',r.matched_skill_count,
    'skill_coverage',case when r.required_skill_count=0 then null else round(r.matched_skill_count*100.0/r.required_skill_count) end,
    'intelligence_available',r.intelligence_available,
    'email',case when v_business_role<>'RECRUITER' or r.owner_user_id=v_user or r.already_on_requirement then c.email else null end,
    'phone',case when v_business_role<>'RECRUITER' or r.owner_user_id=v_user or r.already_on_requirement then c.phone else null end
  ) order by r.matched_skill_count desc,r.lexical_score desc,r.updated_at desc),'[]'::jsonb)
  into v_rows
  from (
    select * from ranked
    order by matched_skill_count desc,lexical_score desc,updated_at desc
    limit v_limit
  ) r
  join public.candidates c on c.id=r.id and c.agency_id=v_agency;

  return jsonb_build_object('ok',true,'rows',v_rows,'ranking','TENANT_SCOPE_THEN_STRUCTURED_SKILLS_THEN_LEXICAL','semantic_used',false);
end;
$fn$;

revoke all on function public.xzrecruiter_complete_candidate_intelligence(text,uuid,jsonb,text,text,jsonb,jsonb,integer,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_review_candidate_intelligence(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.xzrecruiter_talent_match_search(text,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_complete_candidate_intelligence(text,uuid,jsonb,text,text,jsonb,jsonb,integer,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_review_candidate_intelligence(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_talent_match_search(text,uuid,text,integer) to anon,authenticated;

