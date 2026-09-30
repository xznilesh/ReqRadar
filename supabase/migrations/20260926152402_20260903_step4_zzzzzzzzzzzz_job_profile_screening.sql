-- XZ Recruiter Step 4 final quality: complete Job 360 editing and structured public screening.
-- Additive RPCs/overrides only. Knockout answers are evidence; this migration never auto-rejects candidates.

create or replace function public.xzrecruiter_job_profile_context(
  p_token text,p_job_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_job jsonb;v_clients jsonb;v_pipelines jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select jsonb_build_object(
    'id',j.id,'title',j.title,'internalRef',j.internal_ref,'clientId',j.client_id,'companyId',j.company_id,
    'hiringManagerName',j.hiring_manager_name,'hiringManagerEmail',j.hiring_manager_email,'department',j.department,
    'jobFunction',j.job_function,'industry',j.industry,'seniority',j.seniority,'status',j.status,'priority',j.priority,
    'location',j.location,'city',j.city,'region',j.region,'countryCode',j.country_code,'timezone',j.timezone,
    'workplaceType',j.workplace_type,'remoteAllowed',j.remote_allowed,'employmentType',j.employment_type,'contractDuration',j.contract_duration,
    'experienceMin',j.experience_min,'experienceMax',j.experience_max,'openings',j.openings,
    'salaryMin',j.salary_min,'salaryMax',j.salary_max,'salaryCurrency',j.salary_currency,'salaryPeriod',j.salary_period,
    'salaryOte',j.salary_ote,'bonus',j.bonus,'commission',j.commission,
    'workAuthorizationRequirements',coalesce(j.work_authorization_requirements,'[]'::jsonb),'sponsorshipAvailable',j.sponsorship_available,
    'description',j.description,'mandatoryRequirements',coalesce(j.mandatory_requirements,'[]'::jsonb),'preferredRequirements',coalesce(j.preferred_requirements,'[]'::jsonb),
    'skillsRequired',coalesce(j.skills_required,'[]'::jsonb),'skillsPreferred',coalesce(j.skills_preferred,'[]'::jsonb),
    'benefits',coalesce(j.benefits,'[]'::jsonb),'screeningQuestions',coalesce(j.screening_questions,'[]'::jsonb),
    'pipelineId',j.pipeline_id,'publicVisibility',j.public_visibility,'publicSlug',j.public_slug,'slaHours',j.sla_hours,
    'targetFillDate',j.target_fill_date,'tags',coalesce(j.tags,'[]'::jsonb),'openedAt',j.opened_at,'closedAt',j.closed_at,'updatedAt',j.updated_at
  ) into v_job
  from public.recruitment_jobs j where j.id=p_job_id and j.agency_id=v_agency and j.archived_at is null;
  if v_job is null then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name),'[]'::jsonb) into v_clients
  from (select id,name from public.recruitment_clients where agency_id=v_agency order by name limit 500) c;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'isDefault',p.is_default,'recruitmentType',p.recruitment_type) order by p.is_default desc,p.name),'[]'::jsonb) into v_pipelines
  from public.recruitment_pipelines p where p.agency_id=v_agency and p.pipeline_kind='RECRUITMENT' and p.active=true;
  return jsonb_build_object('ok',true,'job',v_job,'clients',v_clients,'pipelines',v_pipelines,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_update_job_profile(
  p_token text,p_job_id uuid,p_job jsonb
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_country text;v_timezone text;v_currency text;v_client uuid;v_pipeline uuid;
  v_title text;v_status text;v_visibility text;v_questions jsonb;v_question jsonb;v_key text;v_salary_min numeric;v_salary_max numeric;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if not exists(select 1 from public.recruitment_jobs where id=p_job_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  v_title:=btrim(coalesce(p_job->>'title',''));if v_title='' then return jsonb_build_object('ok',false,'error','title_required'); end if;
  v_country:=nullif(upper(btrim(coalesce(p_job->>'countryCode',''))),'');v_timezone:=nullif(btrim(coalesce(p_job->>'timezone','')),'');v_currency:=nullif(upper(btrim(coalesce(p_job->>'salaryCurrency',''))),'');
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  if v_currency is not null and v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency'); end if;

  begin v_client:=nullif(p_job->>'clientId','')::uuid; exception when others then return jsonb_build_object('ok',false,'error','invalid_client'); end;
  if v_client is not null and not exists(select 1 from public.recruitment_clients where id=v_client and agency_id=v_agency) then return jsonb_build_object('ok',false,'error','invalid_client'); end if;
  begin v_pipeline:=nullif(p_job->>'pipelineId','')::uuid; exception when others then return jsonb_build_object('ok',false,'error','invalid_pipeline'); end;
  if v_pipeline is not null and not exists(select 1 from public.recruitment_pipelines where id=v_pipeline and agency_id=v_agency and pipeline_kind='RECRUITMENT' and active=true) then return jsonb_build_object('ok',false,'error','invalid_pipeline'); end if;

  v_status:=upper(coalesce(nullif(btrim(p_job->>'status'),''),'OPEN'));
  if v_status not in ('DRAFT','PENDING_APPROVAL','OPEN','ON_HOLD','FILLED','CLOSED','CANCELLED','ARCHIVED') then return jsonb_build_object('ok',false,'error','invalid_status'); end if;
  v_visibility:=upper(coalesce(nullif(btrim(p_job->>'publicVisibility'),''),'PRIVATE'));
  if v_visibility not in ('PRIVATE','INTERNAL','PUBLIC') then return jsonb_build_object('ok',false,'error','invalid_visibility'); end if;
  if coalesce(p_job->>'hiringManagerEmail','')<>'' and lower(p_job->>'hiringManagerEmail') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then return jsonb_build_object('ok',false,'error','invalid_hiring_manager_email'); end if;

  v_salary_min:=nullif(p_job->>'salaryMin','')::numeric;v_salary_max:=nullif(p_job->>'salaryMax','')::numeric;
  if v_salary_min is not null and v_salary_min<0 or v_salary_max is not null and v_salary_max<0 then return jsonb_build_object('ok',false,'error','invalid_salary'); end if;
  if v_salary_min is not null and v_salary_max is not null and v_salary_min>v_salary_max then return jsonb_build_object('ok',false,'error','invalid_salary_range'); end if;

  v_questions:=coalesce(p_job->'screeningQuestions','[]'::jsonb);
  if jsonb_typeof(v_questions)<>'array' or jsonb_array_length(v_questions)>50 then return jsonb_build_object('ok',false,'error','invalid_screening_questions'); end if;
  for v_question in select value from jsonb_array_elements(v_questions) loop
    v_key:=btrim(coalesce(v_question->>'id',''));
    if v_key='' or length(v_key)>100 or btrim(coalesce(v_question->>'question',''))='' then return jsonb_build_object('ok',false,'error','invalid_screening_question'); end if;
    if upper(coalesce(v_question->>'type','TEXT')) not in ('TEXT','YES_NO','SINGLE_SELECT','MULTI_SELECT','NUMBER','DATE','RATING') then return jsonb_build_object('ok',false,'error','invalid_screening_question_type'); end if;
  end loop;

  update public.recruitment_jobs set
    title=v_title,internal_ref=nullif(btrim(p_job->>'internalRef'),''),client_id=v_client,
    hiring_manager_name=nullif(btrim(p_job->>'hiringManagerName'),''),hiring_manager_email=nullif(lower(btrim(p_job->>'hiringManagerEmail')),''),
    department=nullif(btrim(p_job->>'department'),''),job_function=nullif(btrim(p_job->>'jobFunction'),''),industry=nullif(btrim(p_job->>'industry'),''),seniority=nullif(btrim(p_job->>'seniority'),''),
    status=v_status,priority=upper(coalesce(nullif(btrim(p_job->>'priority'),''),'NORMAL')),
    location=nullif(btrim(p_job->>'location'),''),city=nullif(btrim(p_job->>'city'),''),region=nullif(btrim(p_job->>'region'),''),country_code=v_country,timezone=v_timezone,
    workplace_type=nullif(upper(btrim(p_job->>'workplaceType')),''),remote_allowed=coalesce((p_job->>'remoteAllowed')::boolean,false),employment_type=nullif(upper(btrim(p_job->>'employmentType')),''),contract_duration=nullif(btrim(p_job->>'contractDuration'),''),
    experience_min=nullif(p_job->>'experienceMin','')::numeric,experience_max=nullif(p_job->>'experienceMax','')::numeric,openings=greatest(coalesce(nullif(p_job->>'openings','')::integer,1),1),
    salary_min=v_salary_min,salary_max=v_salary_max,salary_currency=v_currency,salary_period=nullif(upper(btrim(p_job->>'salaryPeriod')),''),salary_ote=nullif(p_job->>'salaryOte','')::numeric,bonus=nullif(p_job->>'bonus','')::numeric,commission=nullif(p_job->>'commission','')::numeric,
    work_authorization_requirements=case when jsonb_typeof(p_job->'workAuthorizationRequirements')='array' then p_job->'workAuthorizationRequirements' else '[]'::jsonb end,
    sponsorship_available=coalesce((p_job->>'sponsorshipAvailable')::boolean,false),description=coalesce(p_job->>'description',''),
    mandatory_requirements=case when jsonb_typeof(p_job->'mandatoryRequirements')='array' then p_job->'mandatoryRequirements' else '[]'::jsonb end,
    preferred_requirements=case when jsonb_typeof(p_job->'preferredRequirements')='array' then p_job->'preferredRequirements' else '[]'::jsonb end,
    skills_required=case when jsonb_typeof(p_job->'skillsRequired')='array' then p_job->'skillsRequired' else '[]'::jsonb end,
    skills_preferred=case when jsonb_typeof(p_job->'skillsPreferred')='array' then p_job->'skillsPreferred' else '[]'::jsonb end,
    benefits=case when jsonb_typeof(p_job->'benefits')='array' then p_job->'benefits' else '[]'::jsonb end,
    screening_questions=v_questions,pipeline_id=v_pipeline,public_visibility=v_visibility,sla_hours=nullif(p_job->>'slaHours','')::integer,target_fill_date=nullif(p_job->>'targetFillDate','')::date,
    tags=case when jsonb_typeof(p_job->'tags')='array' then p_job->'tags' else '[]'::jsonb end,
    opened_at=case when v_status='OPEN' then coalesce(opened_at,now()) else opened_at end,
    closed_at=case when v_status in ('FILLED','CLOSED','CANCELLED','ARCHIVED') then coalesce(closed_at,now()) when v_status in ('OPEN','ON_HOLD') then null else closed_at end,
    updated_at=now()
  where id=p_job_id and agency_id=v_agency and archived_at is null;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'job',p_job_id,'job.profile_updated','Job 360 profile updated',jsonb_build_object('status',v_status,'visibility',v_visibility,'screening_questions',jsonb_array_length(v_questions)));
  return jsonb_build_object('ok',true,'job_id',p_job_id,'public_slug',(select public_slug from public.recruitment_jobs where id=p_job_id));
end;$fn$;

-- Public apply override: validate configured questions before creating the application and persist answers as evidence.
create or replace function public.xzrecruiter_public_apply(p_slug text,p_application jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_job public.recruitment_jobs%rowtype;v_candidate uuid;v_app uuid;v_actor uuid;v_email text;v_phone text;v_name text;v_dedupe text;v_stage uuid;v_stage_name text;
  v_country text;v_timezone text;v_has_resume boolean:=coalesce((p_application->>'hasResumeFile')::boolean,false);v_resume_token text;
  v_answers jsonb:=coalesce(p_application->'screeningAnswers','{}'::jsonb);v_question jsonb;v_answer jsonb;v_key text;v_text text;v_required boolean;v_knockout boolean;
begin
  select * into v_job from public.recruitment_jobs where public_slug=p_slug and public_visibility='PUBLIC' and archived_at is null and status='OPEN' limit 1;
  if v_job.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not coalesce((p_application->>'consent')::boolean,false) then return jsonb_build_object('ok',false,'error','consent_required'); end if;
  if jsonb_typeof(v_answers)<>'object' then return jsonb_build_object('ok',false,'error','invalid_screening_answers'); end if;

  for v_question in select value from jsonb_array_elements(coalesce(v_job.screening_questions,'[]'::jsonb)) loop
    v_key:=btrim(coalesce(v_question->>'id',''));v_text:=btrim(coalesce(v_question->>'question',''));v_required:=coalesce((v_question->>'required')::boolean,false);v_answer:=v_answers->v_key;
    if v_required and (v_answer is null or v_answer='null'::jsonb or (jsonb_typeof(v_answer)='string' and btrim(v_answer#>>'{}')='') or (jsonb_typeof(v_answer)='array' and jsonb_array_length(v_answer)=0)) then
      return jsonb_build_object('ok',false,'error','screening_required','question_id',v_key,'question',v_text);
    end if;
  end loop;

  v_name:=btrim(coalesce(p_application->>'fullName',''));v_email:=nullif(lower(btrim(coalesce(p_application->>'email',''))),'');v_phone:=nullif(regexp_replace(coalesce(p_application->>'phone',''),'[^0-9+]','','g'),'');
  if v_name='' or v_email is null then return jsonb_build_object('ok',false,'error','name_email_required'); end if;
  v_country:=coalesce(nullif(upper(btrim(p_application->>'countryCode')),''),v_job.country_code);v_timezone:=nullif(btrim(p_application->>'timezone'),'');
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;

  v_actor:=v_job.created_by_user_id;v_dedupe:=encode(extensions.digest(lower(v_name)||'|'||v_email||'|'||coalesce(v_phone,''),'sha256'),'hex');
  select id into v_candidate from public.candidates where agency_id=v_job.agency_id and lower(email)=v_email and archived_at is null and merged_into_candidate_id is null limit 1;
  if v_candidate is null then
    v_candidate:=gen_random_uuid();
    insert into public.candidates(id,agency_id,full_name,email,phone,location,city,region,country_code,timezone,current_title,skills,resume_text,source,dedupe_key,created_by_user_id,owner_user_id,consent_status,consent_source,consent_at,updated_by_user_id)
    values(v_candidate,v_job.agency_id,v_name,v_email,v_phone,coalesce(nullif(p_application->>'location',''),v_job.location),nullif(p_application->>'city',''),nullif(p_application->>'region',''),v_country,v_timezone,nullif(p_application->>'currentTitle',''),coalesce(p_application->'skills','[]'::jsonb),nullif(p_application->>'resumeText',''),'CAREER_SITE',v_dedupe,v_actor,v_job.owner_user_id,'GRANTED','PUBLIC_APPLICATION',now(),v_actor);
  else
    update public.candidates set consent_status='GRANTED',consent_source='PUBLIC_APPLICATION',consent_at=now(),updated_at=now() where id=v_candidate and agency_id=v_job.agency_id;
  end if;
  if exists(select 1 from public.applications where agency_id=v_job.agency_id and candidate_id=v_candidate and job_id=v_job.id and archived_at is null) then return jsonb_build_object('ok',false,'error','already_applied'); end if;
  select id,name into v_stage,v_stage_name from public.pipeline_stages where agency_id=v_job.agency_id and pipeline_id=v_job.pipeline_id and code in ('APPLIED','NEW') order by case code when 'APPLIED' then 0 else 1 end limit 1;
  v_app:=gen_random_uuid();
  insert into public.applications(id,agency_id,job_id,candidate_id,stage,status,match_evidence,owner_user_id,created_by_user_id,client_id,pipeline_id,stage_id,stage_entered_at,last_activity_at,metadata)
  values(v_app,v_job.agency_id,v_job.id,v_candidate,coalesce(v_stage_name,'Applied'),'ACTIVE','{}'::jsonb,v_job.owner_user_id,v_actor,v_job.client_id,v_job.pipeline_id,v_stage,now(),now(),jsonb_build_object('source','CAREER_SITE','consent_at',now(),'resume_file_expected',v_has_resume));
  insert into public.application_stage_history(agency_id,application_id,to_stage_id,to_stage,changed_by_user_id) values(v_job.agency_id,v_app,v_stage,coalesce(v_stage_name,'Applied'),v_actor);

  for v_question in select value from jsonb_array_elements(coalesce(v_job.screening_questions,'[]'::jsonb)) loop
    v_key:=btrim(coalesce(v_question->>'id',''));v_text:=btrim(coalesce(v_question->>'question',''));v_answer:=v_answers->v_key;v_knockout:=coalesce((v_question->>'knockout')::boolean,false);
    if v_answer is not null and v_answer<>'null'::jsonb then
      insert into public.application_screening_answers(agency_id,application_id,question_key,question_text,answer,knockout)
      values(v_job.agency_id,v_app,v_key,v_text,v_answer,v_knockout)
      on conflict(application_id,question_key) do update set answer=excluded.answer,question_text=excluded.question_text,knockout=excluded.knockout,updated_at=now();
    end if;
  end loop;

  if v_has_resume then
    v_resume_token:=encode(extensions.gen_random_bytes(32),'hex');
    insert into public.public_application_resume_tokens(agency_id,application_id,candidate_id,token_hash,expires_at)
    values(v_job.agency_id,v_app,v_candidate,encode(extensions.digest(v_resume_token,'sha256'),'hex'),now()+interval '15 minutes');
  end if;
  return jsonb_build_object('ok',true,'application_id',v_app,'resume_upload_token',case when v_has_resume then v_resume_token else null end);
end;$fn$;

grant execute on function public.xzrecruiter_job_profile_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_update_job_profile(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_public_apply(text,jsonb) to anon,authenticated;
