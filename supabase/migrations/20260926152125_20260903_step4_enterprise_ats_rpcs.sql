-- XZ Recruiter Step 4: session-aware ATS RPC layer.
-- Browser callers never supply agency_id. Workspace ownership comes from the verified opaque session.

create or replace function private.xzrecruiter_can_write(p_role text)
returns boolean language sql immutable as $$
  select coalesce(p_role,'') in ('OWNER','ADMIN','RECRUITER','MEMBER');
$$;
revoke all on function private.xzrecruiter_can_write(text) from public,anon,authenticated;

create or replace function private.xzrecruiter_log_activity(
  p_agency_id uuid,p_user_id uuid,p_entity_type text,p_entity_id uuid,p_action text,p_summary text default null,p_metadata jsonb default '{}'::jsonb
) returns void language sql security definer set search_path='public','pg_temp' as $$
  insert into public.recruitment_activity_events(agency_id,actor_user_id,entity_type,entity_id,action,summary,metadata)
  values(p_agency_id,p_user_id,p_entity_type,p_entity_id,p_action,p_summary,coalesce(p_metadata,'{}'::jsonb));
$$;
revoke all on function private.xzrecruiter_log_activity(uuid,uuid,text,uuid,text,text,jsonb) from public,anon,authenticated;

create or replace function public.xzrecruiter_workspace_ready(p_token text)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid; v_user uuid; v_role text; v_status text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select status into v_status from public.onboarding_progress where agency_id=v_agency;
  return jsonb_build_object('ok',true,'ready',coalesce(v_status,'NOT_STARTED')='COMPLETED','status',coalesce(v_status,'NOT_STARTED'));
end;$fn$;

create or replace function public.xzrecruiter_ats_context(
  p_token text,p_module text,p_query text default '',p_limit integer default 50,p_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid; v_user uuid; v_role text; v_module text:=upper(coalesce(p_module,''));
  v_query text:=lower(btrim(coalesce(p_query,''))); v_limit int:=greatest(1,least(coalesce(p_limit,50),100)); v_offset int:=greatest(coalesce(p_offset,0),0);
  v_rows jsonb:='[]'::jsonb; v_total integer:=0; v_meta jsonb:='{}'::jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  if v_module='CANDIDATES' then
    select count(*) into v_total from public.candidates c where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and (v_query='' or lower(c.full_name) like '%'||v_query||'%' or lower(coalesce(c.email,'')) like '%'||v_query||'%' or lower(coalesce(c.current_title,'')) like '%'||v_query||'%' or lower(coalesce(c.current_company,'')) like '%'||v_query||'%');
    select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
      select c.id,c.full_name,c.preferred_name,c.headline,c.email,c.phone,c.city,c.region,c.country_code,c.timezone,c.current_title,c.current_company,
             c.experience_years,c.salary_expected,c.salary_currency,c.notice_period_days,c.skills,c.availability_status,c.workplace_preference,c.owner_user_id,c.tags,c.consent_status,c.updated_at
      from public.candidates c where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
        and (v_query='' or lower(c.full_name) like '%'||v_query||'%' or lower(coalesce(c.email,'')) like '%'||v_query||'%' or lower(coalesce(c.current_title,'')) like '%'||v_query||'%' or lower(coalesce(c.current_company,'')) like '%'||v_query||'%')
      order by c.updated_at desc limit v_limit offset v_offset
    ) x;
  elsif v_module='JOBS' then
    select count(*) into v_total from public.recruitment_jobs j where j.agency_id=v_agency and j.archived_at is null
      and (v_query='' or lower(j.title) like '%'||v_query||'%' or lower(coalesce(j.location,'')) like '%'||v_query||'%' or lower(coalesce(j.internal_ref,'')) like '%'||v_query||'%');
    select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
      select j.id,j.title,j.internal_ref,j.client_id,j.company_id,j.status,j.priority,j.location,j.city,j.region,j.country_code,j.timezone,j.workplace_type,j.employment_type,
             j.salary_min,j.salary_max,j.salary_currency,j.salary_period,j.openings,j.pipeline_id,j.public_visibility,j.public_slug,j.owner_user_id,j.updated_at,
             coalesce(rc.name,c.name) as account_name
      from public.recruitment_jobs j
      left join public.recruitment_clients rc on rc.id=j.client_id and rc.agency_id=v_agency
      left join public.companies c on c.id=j.company_id
      where j.agency_id=v_agency and j.archived_at is null
        and (v_query='' or lower(j.title) like '%'||v_query||'%' or lower(coalesce(j.location,'')) like '%'||v_query||'%' or lower(coalesce(j.internal_ref,'')) like '%'||v_query||'%')
      order by j.updated_at desc limit v_limit offset v_offset
    ) x;
  elsif v_module='PIPELINE' then
    select count(*) into v_total from public.applications a where a.agency_id=v_agency and a.archived_at is null;
    select coalesce(jsonb_agg(to_jsonb(x) order by x.stage_sort,x.updated_at desc),'[]'::jsonb) into v_rows from (
      select a.id,a.candidate_id,a.job_id,a.client_id,a.pipeline_id,a.stage_id,a.stage,a.status,a.stage_entered_at,a.owner_user_id,a.updated_at,
             c.full_name as candidate_name,c.current_title,j.title as job_title,ps.name as stage_name,ps.sort_order as stage_sort,ps.status_semantic
      from public.applications a
      join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency
      join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
      left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
      where a.agency_id=v_agency and a.archived_at is null
      order by coalesce(ps.sort_order,999),a.updated_at desc limit v_limit offset v_offset
    ) x;
    select jsonb_build_object('pipelines',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'is_default',p.is_default,'stages',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'code',s.code,'name',s.name,'semantic',s.status_semantic,'sort_order',s.sort_order,'required_fields',s.required_fields,'rejection_reasons',s.rejection_reasons) order by s.sort_order) from public.pipeline_stages s where s.pipeline_id=p.id),'[]'::jsonb))) from public.recruitment_pipelines p where p.agency_id=v_agency and p.pipeline_kind='RECRUITMENT' and p.active=true),'[]'::jsonb)) into v_meta;
  elsif v_module='INTERVIEWS' then
    select count(*) into v_total from public.interviews i where i.agency_id=v_agency;
    select coalesce(jsonb_agg(to_jsonb(x) order by x.scheduled_at asc),'[]'::jsonb) into v_rows from (
      select i.id,i.application_id,i.interview_type,i.scheduled_at,i.end_at,i.timezone,i.candidate_timezone,i.recruiter_timezone,i.location_or_link,i.meeting_url,i.status,i.interviewers,
             c.full_name as candidate_name,j.title as job_title
      from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=v_agency
      join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
      where i.agency_id=v_agency order by i.scheduled_at asc limit v_limit offset v_offset
    ) x;
  elsif v_module='OFFERS' then
    select count(*) into v_total from public.offers o where o.agency_id=v_agency;
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
      select o.id,o.application_id,o.title,o.amount,o.currency,o.salary_period,o.bonus,o.ote,o.status,o.start_date,o.expires_at,o.version_number,o.created_at,
             c.full_name as candidate_name,j.title as job_title
      from public.offers o join public.applications a on a.id=o.application_id and a.agency_id=v_agency
      join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
      where o.agency_id=v_agency order by o.created_at desc limit v_limit offset v_offset
    ) x;
  elsif v_module='PLACEMENTS' then
    select count(*) into v_total from public.placements p where p.agency_id=v_agency;
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_rows from (
      select p.id,p.application_id,p.candidate_id,p.job_id,p.client_id,p.start_date,p.salary,p.salary_currency,p.placement_fee,p.fee_currency,p.fee_type,p.fee_percent,p.status,p.created_at,
             c.full_name as candidate_name,j.title as job_title
      from public.placements p
      left join public.candidates c on c.id=coalesce(p.candidate_id,(select a.candidate_id from public.applications a where a.id=p.application_id)) and c.agency_id=v_agency
      left join public.recruitment_jobs j on j.id=coalesce(p.job_id,(select a.job_id from public.applications a where a.id=p.application_id)) and j.agency_id=v_agency
      where p.agency_id=v_agency order by p.created_at desc limit v_limit offset v_offset
    ) x;
  else return jsonb_build_object('ok',false,'error','invalid_module');
  end if;

  return jsonb_build_object('ok',true,'module',v_module,'rows',v_rows,'total',v_total,'limit',v_limit,'offset',v_offset,'meta',v_meta,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_save_candidate(p_token text,p_candidate jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid; v_user uuid; v_role text; v_id uuid; v_name text; v_email text; v_phone text; v_dedupe text; v_existing uuid; v_country text; v_timezone text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_name:=btrim(coalesce(p_candidate->>'fullName',''));
  v_email:=nullif(lower(btrim(coalesce(p_candidate->>'email',''))),'');
  v_phone:=nullif(regexp_replace(coalesce(p_candidate->>'phone',''),'[^0-9+]','','g'),'');
  if v_name='' or (v_email is null and v_phone is null) then return jsonb_build_object('ok',false,'error','name_and_contact_required'); end if;
  v_country:=nullif(upper(p_candidate->>'countryCode'),''); v_timezone:=nullif(p_candidate->>'timezone','');
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  v_dedupe:=encode(extensions.digest(lower(v_name)||'|'||coalesce(v_email,'')||'|'||coalesce(v_phone,''),'sha256'),'hex');
  select id into v_existing from public.candidates where agency_id=v_agency and archived_at is null and merged_into_candidate_id is null
    and ((v_email is not null and lower(email)=v_email) or (v_phone is not null and phone=v_phone)) limit 1;
  if (p_candidate->>'id') is null and v_existing is not null then
    return jsonb_build_object('ok',false,'error','possible_duplicate','candidate_id',v_existing);
  end if;
  if nullif(p_candidate->>'id','') is not null then
    v_id:=(p_candidate->>'id')::uuid;
    update public.candidates set
      full_name=v_name,preferred_name=nullif(p_candidate->>'preferredName',''),headline=nullif(p_candidate->>'headline',''),email=v_email,phone=v_phone,
      city=nullif(p_candidate->>'city',''),region=nullif(p_candidate->>'region',''),country_code=v_country,timezone=v_timezone,
      current_title=nullif(p_candidate->>'currentTitle',''),current_company=nullif(p_candidate->>'currentCompany',''),
      experience_years=nullif(p_candidate->>'experienceYears','')::numeric,relevant_experience_years=nullif(p_candidate->>'relevantExperienceYears','')::numeric,
      salary_expected=nullif(p_candidate->>'salaryExpected','')::numeric,salary_currency=nullif(upper(p_candidate->>'salaryCurrency'),''),notice_period_days=nullif(p_candidate->>'noticePeriodDays','')::integer,
      skills=coalesce(p_candidate->'skills',skills),languages=coalesce(p_candidate->'languages',languages),education=coalesce(p_candidate->'education',education),certifications=coalesce(p_candidate->'certifications',certifications),
      availability_status=coalesce(nullif(p_candidate->>'availabilityStatus',''),availability_status),workplace_preference=nullif(p_candidate->>'workplacePreference',''),relocation_preference=nullif(p_candidate->>'relocationPreference',''),
      owner_user_id=coalesce(nullif(p_candidate->>'ownerUserId','')::uuid,owner_user_id,v_user),tags=coalesce(p_candidate->'tags',tags),consent_status=coalesce(nullif(p_candidate->>'consentStatus',''),consent_status),
      consent_source=coalesce(nullif(p_candidate->>'consentSource',''),consent_source),updated_by_user_id=v_user,updated_at=now(),dedupe_key=v_dedupe
    where id=v_id and agency_id=v_agency and archived_at is null;
    if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',v_id,'candidate.updated','Candidate profile updated');
  else
    insert into public.candidates(id,agency_id,full_name,email,phone,city,region,country_code,timezone,current_title,current_company,experience_years,salary_expected,salary_currency,notice_period_days,skills,source,dedupe_key,created_by_user_id,owner_user_id,preferred_name,headline,languages,education,certifications,availability_status,workplace_preference,relocation_preference,tags,consent_status,consent_source,updated_by_user_id)
    values(gen_random_uuid(),v_agency,v_name,v_email,v_phone,nullif(p_candidate->>'city',''),nullif(p_candidate->>'region',''),v_country,v_timezone,nullif(p_candidate->>'currentTitle',''),nullif(p_candidate->>'currentCompany',''),nullif(p_candidate->>'experienceYears','')::numeric,nullif(p_candidate->>'salaryExpected','')::numeric,nullif(upper(p_candidate->>'salaryCurrency'),''),nullif(p_candidate->>'noticePeriodDays','')::integer,coalesce(p_candidate->'skills','[]'::jsonb),coalesce(nullif(p_candidate->>'source',''),'MANUAL'),v_dedupe,v_user,v_user,nullif(p_candidate->>'preferredName',''),nullif(p_candidate->>'headline',''),coalesce(p_candidate->'languages','[]'::jsonb),coalesce(p_candidate->'education','[]'::jsonb),coalesce(p_candidate->'certifications','[]'::jsonb),coalesce(nullif(p_candidate->>'availabilityStatus',''),'UNKNOWN'),nullif(p_candidate->>'workplacePreference',''),nullif(p_candidate->>'relocationPreference',''),coalesce(p_candidate->'tags','[]'::jsonb),coalesce(nullif(p_candidate->>'consentStatus',''),'UNKNOWN'),nullif(p_candidate->>'consentSource',''),v_user)
    returning id into v_id;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',v_id,'candidate.created','Candidate created');
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
exception when unique_violation then return jsonb_build_object('ok',false,'error','possible_duplicate'); end;$fn$;

create or replace function public.xzrecruiter_archive_candidate(p_token text,p_candidate_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 update public.candidates set archived_at=now(),archived_by_user_id=v_user,updated_at=now() where id=p_candidate_id and agency_id=v_agency and archived_at is null;
 if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
 perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',p_candidate_id,'candidate.archived','Candidate archived');
 return jsonb_build_object('ok',true);
end;$fn$;

create or replace function public.xzrecruiter_save_job(p_token text,p_job jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_title text;v_country text;v_timezone text;v_pipeline uuid;v_slug text;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 v_title:=btrim(coalesce(p_job->>'title','')); if v_title='' then return jsonb_build_object('ok',false,'error','title_required'); end if;
 v_country:=nullif(upper(p_job->>'countryCode'),''); v_timezone:=nullif(p_job->>'timezone','');
 if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
 if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
 v_pipeline:=nullif(p_job->>'pipelineId','')::uuid;
 if v_pipeline is null then select id into v_pipeline from public.recruitment_pipelines where agency_id=v_agency and pipeline_kind='RECRUITMENT' and is_default=true and active=true limit 1; end if;
 if v_pipeline is not null and not exists(select 1 from public.recruitment_pipelines where id=v_pipeline and agency_id=v_agency and active=true) then return jsonb_build_object('ok',false,'error','invalid_pipeline'); end if;
 if nullif(p_job->>'id','') is not null then
   v_id:=(p_job->>'id')::uuid;
   update public.recruitment_jobs set title=v_title,internal_ref=nullif(p_job->>'internalRef',''),client_id=nullif(p_job->>'clientId','')::uuid,company_id=nullif(p_job->>'companyId','')::uuid,
     hiring_manager_name=nullif(p_job->>'hiringManagerName',''),department=nullif(p_job->>'department',''),job_function=nullif(p_job->>'jobFunction',''),industry=nullif(p_job->>'industry',''),seniority=nullif(p_job->>'seniority',''),
     location=nullif(p_job->>'location',''),city=nullif(p_job->>'city',''),region=nullif(p_job->>'region',''),country_code=v_country,timezone=v_timezone,workplace_type=nullif(p_job->>'workplaceType',''),employment_type=nullif(p_job->>'employmentType',''),
     salary_min=nullif(p_job->>'salaryMin','')::numeric,salary_max=nullif(p_job->>'salaryMax','')::numeric,salary_currency=nullif(upper(p_job->>'salaryCurrency'),''),salary_period=nullif(p_job->>'salaryPeriod',''),openings=greatest(coalesce(nullif(p_job->>'openings','')::integer,openings),1),
     description=coalesce(p_job->>'description',description),skills_required=coalesce(p_job->'skillsRequired',skills_required),skills_preferred=coalesce(p_job->'skillsPreferred',skills_preferred),priority=coalesce(nullif(p_job->>'priority',''),priority),pipeline_id=v_pipeline,
     public_visibility=coalesce(nullif(p_job->>'publicVisibility',''),public_visibility),target_fill_date=nullif(p_job->>'targetFillDate','')::date,tags=coalesce(p_job->'tags',tags),updated_at=now()
   where id=v_id and agency_id=v_agency and archived_at is null;
   if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
   perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_id,'job.updated','Job updated');
 else
   v_id:=gen_random_uuid();
   v_slug:=lower(regexp_replace(v_title,'[^a-zA-Z0-9]+','-','g'))||'-'||substr(replace(v_id::text,'-',''),1,10);
   insert into public.recruitment_jobs(id,agency_id,client_id,title,status,location,workplace_type,employment_type,salary_min,salary_max,salary_currency,description,mandatory_requirements,preferred_requirements,owner_user_id,created_by_user_id,country_code,timezone,salary_period,internal_ref,company_id,hiring_manager_name,department,job_function,industry,seniority,skills_required,skills_preferred,openings,priority,pipeline_id,public_visibility,public_slug,target_fill_date,tags,opened_at)
   values(v_id,v_agency,nullif(p_job->>'clientId','')::uuid,v_title,coalesce(nullif(p_job->>'status',''),'OPEN'),nullif(p_job->>'location',''),nullif(p_job->>'workplaceType',''),nullif(p_job->>'employmentType',''),nullif(p_job->>'salaryMin','')::numeric,nullif(p_job->>'salaryMax','')::numeric,nullif(upper(p_job->>'salaryCurrency'),''),nullif(p_job->>'description',''),coalesce(p_job->'mandatoryRequirements','[]'::jsonb),coalesce(p_job->'preferredRequirements','[]'::jsonb),v_user,v_user,v_country,v_timezone,nullif(p_job->>'salaryPeriod',''),nullif(p_job->>'internalRef',''),nullif(p_job->>'companyId','')::uuid,nullif(p_job->>'hiringManagerName',''),nullif(p_job->>'department',''),nullif(p_job->>'jobFunction',''),nullif(p_job->>'industry',''),nullif(p_job->>'seniority',''),coalesce(p_job->'skillsRequired','[]'::jsonb),coalesce(p_job->'skillsPreferred','[]'::jsonb),greatest(coalesce(nullif(p_job->>'openings','')::integer,1),1),coalesce(nullif(p_job->>'priority',''),'NORMAL'),v_pipeline,coalesce(nullif(p_job->>'publicVisibility',''),'PRIVATE'),v_slug,nullif(p_job->>'targetFillDate','')::date,coalesce(p_job->'tags','[]'::jsonb),case when coalesce(nullif(p_job->>'status',''),'OPEN')='OPEN' then now() else null end);
   perform private.xzrecruiter_log_activity(v_agency,v_user,'job',v_id,'job.created','Job created');
 end if;
 return jsonb_build_object('ok',true,'id',v_id,'public_slug',(select public_slug from public.recruitment_jobs where id=v_id));
end;$fn$;

create or replace function public.xzrecruiter_create_application(p_token text,p_candidate_id uuid,p_job_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_app uuid;v_pipeline uuid;v_stage uuid;v_stage_name text;v_client uuid;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if not exists(select 1 from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null) then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
 select pipeline_id,client_id into v_pipeline,v_client from public.recruitment_jobs where id=p_job_id and agency_id=v_agency and archived_at is null;
 if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
 if exists(select 1 from public.applications where agency_id=v_agency and candidate_id=p_candidate_id and job_id=p_job_id and archived_at is null) then return jsonb_build_object('ok',false,'error','application_exists'); end if;
 if v_pipeline is null then select id into v_pipeline from public.recruitment_pipelines where agency_id=v_agency and pipeline_kind='RECRUITMENT' and is_default=true and active=true limit 1; end if;
 select id,name into v_stage,v_stage_name from public.pipeline_stages where agency_id=v_agency and pipeline_id=v_pipeline and code in ('APPLIED','NEW') order by case code when 'APPLIED' then 0 else 1 end limit 1;
 v_app:=gen_random_uuid();
 insert into public.applications(id,agency_id,job_id,candidate_id,stage,status,match_evidence,owner_user_id,created_by_user_id,client_id,pipeline_id,stage_id,stage_entered_at,last_activity_at)
 values(v_app,v_agency,p_job_id,p_candidate_id,coalesce(v_stage_name,'Applied'),'ACTIVE','{}'::jsonb,v_user,v_user,v_client,v_pipeline,v_stage,now(),now());
 insert into public.application_stage_history(agency_id,application_id,to_stage_id,to_stage,changed_by_user_id) values(v_agency,v_app,v_stage,coalesce(v_stage_name,'Applied'),v_user);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_app,'application.created','Candidate added to job',jsonb_build_object('candidate_id',p_candidate_id,'job_id',p_job_id));
 return jsonb_build_object('ok',true,'id',v_app);
end;$fn$;

create or replace function public.xzrecruiter_move_application_stage(p_token text,p_application_id uuid,p_stage_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_pipeline uuid;v_old_stage uuid;v_old_name text;v_new_name text;v_code text;v_category text;v_required jsonb;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 select pipeline_id,stage_id,stage into v_pipeline,v_old_stage,v_old_name from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null;
 if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
 select name,code,stage_category,required_fields into v_new_name,v_code,v_category,v_required from public.pipeline_stages where id=p_stage_id and agency_id=v_agency and pipeline_id=v_pipeline;
 if not found then return jsonb_build_object('ok',false,'error','invalid_stage'); end if;
 if v_code='REJECTED' and btrim(coalesce(p_reason,''))='' then return jsonb_build_object('ok',false,'error','rejection_reason_required'); end if;
 update public.applications set stage_id=p_stage_id,stage=v_new_name,stage_entered_at=now(),last_activity_at=now(),updated_at=now(),
   rejection_reason=case when v_code='REJECTED' then p_reason else rejection_reason end,
   withdrawal_reason=case when v_code='WITHDRAWN' then p_reason else withdrawal_reason end
 where id=p_application_id and agency_id=v_agency;
 insert into public.application_stage_history(agency_id,application_id,from_stage_id,to_stage_id,from_stage,to_stage,reason,changed_by_user_id)
 values(v_agency,p_application_id,v_old_stage,p_stage_id,v_old_name,v_new_name,p_reason,v_user);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'application',p_application_id,'application.stage_changed',v_old_name||' → '||v_new_name,jsonb_build_object('reason',p_reason));
 return jsonb_build_object('ok',true,'stage_id',p_stage_id,'stage',v_new_name);
end;$fn$;

create or replace function public.xzrecruiter_schedule_interview(p_token text,p_interview jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_app uuid;v_start timestamptz;v_end timestamptz;v_tz text;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 v_app:=nullif(p_interview->>'applicationId','')::uuid; if not exists(select 1 from public.applications where id=v_app and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
 v_start:=(p_interview->>'scheduledAt')::timestamptz; v_end:=coalesce(nullif(p_interview->>'endAt','')::timestamptz,v_start+interval '1 hour'); if v_end<=v_start then return jsonb_build_object('ok',false,'error','invalid_time_range'); end if;
 v_tz:=coalesce(nullif(p_interview->>'timezone',''),'UTC'); if not public.xzrecruiter_valid_timezone(v_tz) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
 v_id:=gen_random_uuid();
 insert into public.interviews(id,agency_id,application_id,interview_type,scheduled_at,timezone,location_or_link,status,created_by_user_id,end_at,candidate_timezone,recruiter_timezone,meeting_url,instructions,interviewers,scorecard_template_id)
 values(v_id,v_agency,v_app,coalesce(nullif(p_interview->>'interviewType',''),'CUSTOM'),v_start,v_tz,nullif(p_interview->>'locationOrLink',''),coalesce(nullif(p_interview->>'status',''),'SCHEDULED'),v_user,v_end,nullif(p_interview->>'candidateTimezone',''),nullif(p_interview->>'recruiterTimezone',''),nullif(p_interview->>'meetingUrl',''),nullif(p_interview->>'instructions',''),coalesce(p_interview->'interviewers','[]'::jsonb),nullif(p_interview->>'scorecardTemplateId','')::uuid);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'interview',v_id,'interview.scheduled','Interview scheduled',jsonb_build_object('application_id',v_app,'timezone',v_tz));
 return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_save_offer(p_token text,p_offer jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_app uuid;v_parent uuid;v_version integer:=1;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 v_app:=nullif(p_offer->>'applicationId','')::uuid; if not exists(select 1 from public.applications where id=v_app and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
 v_parent:=nullif(p_offer->>'parentOfferId','')::uuid;
 if v_parent is not null then select max(version_number)+1 into v_version from public.offers where agency_id=v_agency and (id=v_parent or parent_offer_id=v_parent); v_version:=coalesce(v_version,2); end if;
 v_id:=gen_random_uuid();
 insert into public.offers(id,agency_id,application_id,amount,currency,status,start_date,note,created_by_user_id,title,location,salary_period,bonus,commission,ote,equity,allowances,expires_at,employment_type,version_number,parent_offer_id)
 values(v_id,v_agency,v_app,nullif(p_offer->>'amount','')::numeric,nullif(upper(p_offer->>'currency'),''),coalesce(nullif(p_offer->>'status',''),'DRAFT'),nullif(p_offer->>'startDate','')::date,nullif(p_offer->>'note',''),v_user,nullif(p_offer->>'title',''),nullif(p_offer->>'location',''),nullif(p_offer->>'salaryPeriod',''),nullif(p_offer->>'bonus','')::numeric,nullif(p_offer->>'commission','')::numeric,nullif(p_offer->>'ote','')::numeric,nullif(p_offer->>'equity',''),coalesce(p_offer->'allowances','[]'::jsonb),nullif(p_offer->>'expiresAt','')::timestamptz,nullif(p_offer->>'employmentType',''),v_version,v_parent);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'offer',v_id,'offer.created','Offer version created',jsonb_build_object('application_id',v_app,'version',v_version));
 return jsonb_build_object('ok',true,'id',v_id,'version',v_version);
end;$fn$;

create or replace function public.xzrecruiter_create_placement(p_token text,p_placement jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_app uuid;v_candidate uuid;v_job uuid;v_client uuid;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 v_app:=nullif(p_placement->>'applicationId','')::uuid;
 select candidate_id,job_id,client_id into v_candidate,v_job,v_client from public.applications where id=v_app and agency_id=v_agency and archived_at is null;
 if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
 if exists(select 1 from public.placements where agency_id=v_agency and application_id=v_app and status not in ('CANCELLED')) then return jsonb_build_object('ok',false,'error','placement_exists'); end if;
 v_id:=gen_random_uuid();
 insert into public.placements(id,agency_id,application_id,offer_id,placement_fee,fee_currency,start_date,created_by_user_id,candidate_id,job_id,client_id,recruiter_user_id,salary,salary_currency,status,fee_type,fee_percent,guarantee_end_date,commission_amount)
 values(v_id,v_agency,v_app,nullif(p_placement->>'offerId','')::uuid,nullif(p_placement->>'placementFee','')::numeric,nullif(upper(p_placement->>'feeCurrency'),''),nullif(p_placement->>'startDate','')::date,v_user,v_candidate,v_job,v_client,v_user,nullif(p_placement->>'salary','')::numeric,nullif(upper(p_placement->>'salaryCurrency'),''),coalesce(nullif(p_placement->>'status',''),'PLANNED'),nullif(p_placement->>'feeType',''),nullif(p_placement->>'feePercent','')::numeric,nullif(p_placement->>'guaranteeEndDate','')::date,nullif(p_placement->>'commissionAmount','')::numeric);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'placement',v_id,'placement.created','Placement created',jsonb_build_object('application_id',v_app));
 return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_issue_candidate_portal_access(p_token text,p_candidate_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_raw text;v_id uuid;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if not exists(select 1 from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
 update public.candidate_portal_sessions set revoked_at=coalesce(revoked_at,now()) where agency_id=v_agency and candidate_id=p_candidate_id and revoked_at is null;
 v_raw:=encode(extensions.gen_random_bytes(32),'hex'); v_id:=gen_random_uuid();
 insert into public.candidate_portal_sessions(id,agency_id,candidate_id,token_hash,expires_at) values(v_id,v_agency,p_candidate_id,encode(extensions.digest(v_raw,'sha256'),'hex'),now()+interval '7 days');
 return jsonb_build_object('ok',true,'portal_token',v_raw,'expires_at',now()+interval '7 days');
end;$fn$;

create or replace function public.xzrecruiter_candidate_portal_snapshot(p_portal_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_candidate uuid;v_result jsonb;
begin
 select agency_id,candidate_id into v_agency,v_candidate from public.candidate_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
 if v_candidate is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 update public.candidate_portal_sessions set last_seen_at=now() where token_hash=encode(extensions.digest(p_portal_token,'sha256'),'hex');
 select jsonb_build_object('ok',true,'candidate',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'headline',c.headline,'email',c.email,'phone',c.phone,'city',c.city,'country_code',c.country_code,'availability_status',c.availability_status) from public.candidates c where c.id=v_candidate and c.agency_id=v_agency),
   'applications',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'stage',a.stage,'status',a.status,'job_id',j.id,'job_title',j.title,'updated_at',a.updated_at) order by a.updated_at desc) from public.applications a join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency where a.agency_id=v_agency and a.candidate_id=v_candidate and a.archived_at is null),'[]'::jsonb),
   'interviews',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'type',i.interview_type,'scheduled_at',i.scheduled_at,'timezone',i.timezone,'meeting_url',i.meeting_url,'location',i.location_or_link,'status',i.status) order by i.scheduled_at) from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=v_agency where a.candidate_id=v_candidate and i.agency_id=v_agency),'[]'::jsonb),
   'offers',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'title',o.title,'amount',o.amount,'currency',o.currency,'status',o.status,'start_date',o.start_date,'expires_at',o.expires_at,'version',o.version_number) order by o.created_at desc) from public.offers o join public.applications a on a.id=o.application_id and a.agency_id=v_agency where a.candidate_id=v_candidate and o.agency_id=v_agency and o.status in ('SENT','VIEWED','ACCEPTED','DECLINED','EXPIRED')),'[]'::jsonb)) into v_result;
 return v_result;
end;$fn$;

create or replace function public.xzrecruiter_public_job(p_slug text)
returns jsonb language sql stable security definer set search_path='public','pg_temp' as $$
 select coalesce((select jsonb_build_object('ok',true,'job',jsonb_build_object('slug',j.public_slug,'title',j.title,'location',j.location,'city',j.city,'region',j.region,'country_code',j.country_code,'workplace_type',j.workplace_type,'employment_type',j.employment_type,'salary_min',j.salary_min,'salary_max',j.salary_max,'salary_currency',j.salary_currency,'salary_period',j.salary_period,'description',j.description,'benefits',j.benefits,'screening_questions',j.screening_questions)) from public.recruitment_jobs j where j.public_slug=p_slug and j.public_visibility='PUBLIC' and j.archived_at is null and j.status='OPEN' limit 1),jsonb_build_object('ok',false,'error','not_found'));
$$;

create or replace function public.xzrecruiter_public_apply(p_slug text,p_application jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_job public.recruitment_jobs%rowtype;v_candidate uuid;v_app uuid;v_actor uuid;v_email text;v_phone text;v_name text;v_dedupe text;v_stage uuid;v_stage_name text;
begin
 select * into v_job from public.recruitment_jobs where public_slug=p_slug and public_visibility='PUBLIC' and archived_at is null and status='OPEN' limit 1;
 if v_job.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
 v_name:=btrim(coalesce(p_application->>'fullName',''));v_email:=nullif(lower(btrim(coalesce(p_application->>'email',''))),'');v_phone:=nullif(regexp_replace(coalesce(p_application->>'phone',''),'[^0-9+]','','g'),'');
 if v_name='' or v_email is null then return jsonb_build_object('ok',false,'error','name_email_required'); end if;
 v_actor:=v_job.created_by_user_id;v_dedupe:=encode(extensions.digest(lower(v_name)||'|'||v_email||'|'||coalesce(v_phone,''),'sha256'),'hex');
 select id into v_candidate from public.candidates where agency_id=v_job.agency_id and lower(email)=v_email and archived_at is null and merged_into_candidate_id is null limit 1;
 if v_candidate is null then
   v_candidate:=gen_random_uuid();insert into public.candidates(id,agency_id,full_name,email,phone,location,city,region,country_code,timezone,current_title,skills,resume_text,source,dedupe_key,created_by_user_id,owner_user_id,consent_status,consent_source,consent_at,updated_by_user_id)
   values(v_candidate,v_job.agency_id,v_name,v_email,v_phone,coalesce(p_application->>'location',v_job.location),nullif(p_application->>'city',''),nullif(p_application->>'region',''),coalesce(nullif(upper(p_application->>'countryCode'),''),v_job.country_code),nullif(p_application->>'timezone',''),nullif(p_application->>'currentTitle',''),coalesce(p_application->'skills','[]'::jsonb),nullif(p_application->>'resumeText',''),'CAREER_SITE',v_dedupe,v_actor,v_job.owner_user_id,case when coalesce((p_application->>'consent')::boolean,false) then 'GRANTED' else 'PENDING' end,'PUBLIC_APPLICATION',case when coalesce((p_application->>'consent')::boolean,false) then now() else null end,v_actor);
 end if;
 if exists(select 1 from public.applications where agency_id=v_job.agency_id and candidate_id=v_candidate and job_id=v_job.id and archived_at is null) then return jsonb_build_object('ok',false,'error','already_applied'); end if;
 select id,name into v_stage,v_stage_name from public.pipeline_stages where agency_id=v_job.agency_id and pipeline_id=v_job.pipeline_id and code in ('APPLIED','NEW') order by case code when 'APPLIED' then 0 else 1 end limit 1;
 v_app:=gen_random_uuid(); insert into public.applications(id,agency_id,job_id,candidate_id,stage,status,match_evidence,owner_user_id,created_by_user_id,client_id,pipeline_id,stage_id,stage_entered_at,last_activity_at,metadata)
 values(v_app,v_job.agency_id,v_job.id,v_candidate,coalesce(v_stage_name,'Applied'),'ACTIVE','{}'::jsonb,v_job.owner_user_id,v_actor,v_job.client_id,v_job.pipeline_id,v_stage,now(),now(),jsonb_build_object('source','CAREER_SITE'));
 insert into public.application_stage_history(agency_id,application_id,to_stage_id,to_stage,changed_by_user_id) values(v_job.agency_id,v_app,v_stage,coalesce(v_stage_name,'Applied'),v_actor);
 return jsonb_build_object('ok',true,'application_id',v_app);
end;$fn$;

-- Explicit grants only for RPC surfaces used by the application.
grant execute on function public.xzrecruiter_workspace_ready(text) to anon,authenticated;
grant execute on function public.xzrecruiter_ats_context(text,text,text,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_save_candidate(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_candidate(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_save_job(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_create_application(text,uuid,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_move_application_stage(text,uuid,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_schedule_interview(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_offer(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_create_placement(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_issue_candidate_portal_access(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_portal_snapshot(text) to anon,authenticated;
grant execute on function public.xzrecruiter_public_job(text) to anon,authenticated;
grant execute on function public.xzrecruiter_public_apply(text,jsonb) to anon,authenticated;
