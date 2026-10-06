-- XZ Recruiter Step 4 final quality: complete on-demand Candidate 360 editing and explicit duplicate field resolution.
-- Additive RPCs/overrides only. Existing ATS history remains preserved.

create or replace function public.xzrecruiter_candidate_profile_context(
  p_token text,p_candidate_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_profile jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select jsonb_build_object(
    'id',c.id,'fullName',c.full_name,'preferredName',c.preferred_name,'headline',c.headline,
    'email',c.email,'secondaryEmail',c.secondary_email,'phone',c.phone,'secondaryPhone',c.secondary_phone,
    'currentTitle',c.current_title,'currentCompany',c.current_company,'city',c.city,'region',c.region,
    'countryCode',c.country_code,'timezone',c.timezone,'experienceYears',c.experience_years,
    'relevantExperienceYears',c.relevant_experience_years,'jobFunction',c.job_function,'seniority',c.seniority,
    'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'noticePeriodDays',c.notice_period_days,
    'availabilityStatus',c.availability_status,'employmentPreference',c.employment_preference,
    'workplacePreference',c.workplace_preference,'relocationPreference',c.relocation_preference,
    'skills',coalesce(c.skills,'[]'::jsonb),'languages',coalesce(c.languages,'[]'::jsonb),
    'education',coalesce(c.education,'[]'::jsonb),'certifications',coalesce(c.certifications,'[]'::jsonb),
    'desiredLocations',coalesce(c.desired_locations,'[]'::jsonb),'workAuthorizationSummary',coalesce(c.work_authorization_summary,'[]'::jsonb),
    'tags',coalesce(c.tags,'[]'::jsonb),'consentStatus',c.consent_status,'consentSource',c.consent_source,
    'retentionStatus',c.retention_status,'updatedAt',c.updated_at
  ) into v_profile
  from public.candidates c
  where c.id=p_candidate_id and c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null;
  if v_profile is null then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
  return jsonb_build_object('ok',true,'profile',v_profile,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_update_candidate_profile(
  p_token text,p_candidate_id uuid,p_profile jsonb
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_country text;v_timezone text;v_currency text;
  v_email text;v_phone text;v_duplicate uuid;v_name text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if not exists(select 1 from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null) then
    return jsonb_build_object('ok',false,'error','candidate_not_found');
  end if;

  v_name:=btrim(coalesce(p_profile->>'fullName',''));
  v_email:=nullif(lower(btrim(coalesce(p_profile->>'email',''))),'');
  v_phone:=nullif(regexp_replace(coalesce(p_profile->>'phone',''),'[^0-9+]','','g'),'');
  if v_name='' or (v_email is null and v_phone is null) then return jsonb_build_object('ok',false,'error','name_and_contact_required'); end if;

  v_country:=nullif(upper(btrim(coalesce(p_profile->>'countryCode',''))),'');
  v_timezone:=nullif(btrim(coalesce(p_profile->>'timezone','')),'');
  v_currency:=nullif(upper(btrim(coalesce(p_profile->>'salaryCurrency',''))),'');
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  if v_currency is not null and v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency'); end if;

  select id into v_duplicate from public.candidates
  where agency_id=v_agency and id<>p_candidate_id and archived_at is null and merged_into_candidate_id is null
    and ((v_email is not null and lower(email)=v_email) or (v_phone is not null and phone=v_phone)) limit 1;
  if v_duplicate is not null then return jsonb_build_object('ok',false,'error','possible_duplicate','candidate_id',v_duplicate); end if;

  update public.candidates set
    full_name=v_name,
    preferred_name=nullif(btrim(coalesce(p_profile->>'preferredName','')),''),
    headline=nullif(btrim(coalesce(p_profile->>'headline','')),''),
    email=v_email,
    secondary_email=nullif(lower(btrim(coalesce(p_profile->>'secondaryEmail',''))),''),
    phone=v_phone,
    secondary_phone=nullif(regexp_replace(coalesce(p_profile->>'secondaryPhone',''),'[^0-9+]','','g'),''),
    current_title=nullif(btrim(coalesce(p_profile->>'currentTitle','')),''),
    current_company=nullif(btrim(coalesce(p_profile->>'currentCompany','')),''),
    city=nullif(btrim(coalesce(p_profile->>'city','')),''),
    region=nullif(btrim(coalesce(p_profile->>'region','')),''),
    country_code=v_country,
    timezone=v_timezone,
    experience_years=nullif(p_profile->>'experienceYears','')::numeric,
    relevant_experience_years=nullif(p_profile->>'relevantExperienceYears','')::numeric,
    job_function=nullif(btrim(coalesce(p_profile->>'jobFunction','')),''),
    seniority=nullif(btrim(coalesce(p_profile->>'seniority','')),''),
    salary_expected=nullif(p_profile->>'salaryExpected','')::numeric,
    salary_currency=v_currency,
    notice_period_days=nullif(p_profile->>'noticePeriodDays','')::integer,
    availability_status=coalesce(nullif(upper(btrim(p_profile->>'availabilityStatus')),''),'UNKNOWN'),
    employment_preference=nullif(upper(btrim(coalesce(p_profile->>'employmentPreference',''))),''),
    workplace_preference=nullif(upper(btrim(coalesce(p_profile->>'workplacePreference',''))),''),
    relocation_preference=nullif(btrim(coalesce(p_profile->>'relocationPreference','')),''),
    skills=case when jsonb_typeof(p_profile->'skills')='array' then p_profile->'skills' else '[]'::jsonb end,
    languages=case when jsonb_typeof(p_profile->'languages')='array' then p_profile->'languages' else '[]'::jsonb end,
    education=case when jsonb_typeof(p_profile->'education')='array' then p_profile->'education' else '[]'::jsonb end,
    certifications=case when jsonb_typeof(p_profile->'certifications')='array' then p_profile->'certifications' else '[]'::jsonb end,
    desired_locations=case when jsonb_typeof(p_profile->'desiredLocations')='array' then p_profile->'desiredLocations' else '[]'::jsonb end,
    work_authorization_summary=case when jsonb_typeof(p_profile->'workAuthorizationSummary')='array' then p_profile->'workAuthorizationSummary' else '[]'::jsonb end,
    tags=case when jsonb_typeof(p_profile->'tags')='array' then p_profile->'tags' else '[]'::jsonb end,
    consent_status=coalesce(nullif(upper(btrim(p_profile->>'consentStatus')),''),consent_status),
    retention_status=coalesce(nullif(upper(btrim(p_profile->>'retentionStatus')),''),retention_status),
    updated_by_user_id=v_user,updated_at=now(),data_reviewed_at=now()
  where id=p_candidate_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',p_candidate_id,'candidate.profile_updated','Candidate 360 profile updated');
  return jsonb_build_object('ok',true,'candidate_id',p_candidate_id);
end;$fn$;

-- Final duplicate merge keeps a deliberate field-resolution record and preserves alternate contact history.
create or replace function public.xzrecruiter_merge_candidates(
  p_token text,p_survivor_id uuid,p_duplicate_id uuid,p_resolution jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_dup record;v_surv record;
  v_email text;v_phone text;v_country text;v_timezone text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN','RECRUITER','MEMBER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if p_survivor_id=p_duplicate_id then return jsonb_build_object('ok',false,'error','same_candidate'); end if;
  select * into v_surv from public.candidates where id=p_survivor_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  select * into v_dup from public.candidates where id=p_duplicate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  if v_surv.id is null or v_dup.id is null then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;

  v_email:=case when lower(coalesce(p_resolution->>'primaryEmail','keep'))='duplicate' then v_dup.email else v_surv.email end;
  v_phone:=case when lower(coalesce(p_resolution->>'primaryPhone','keep'))='duplicate' then v_dup.phone else v_surv.phone end;
  v_country:=case when lower(coalesce(p_resolution->>'countryCode','keep'))='duplicate' then v_dup.country_code else v_surv.country_code end;
  v_timezone:=case when lower(coalesce(p_resolution->>'timezone','keep'))='duplicate' then v_dup.timezone else v_surv.timezone end;
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;

  update public.applications a set candidate_id=p_survivor_id,updated_at=now(),metadata=coalesce(a.metadata,'{}'::jsonb)||jsonb_build_object('merged_from_candidate_id',p_duplicate_id)
  where a.agency_id=v_agency and a.candidate_id=p_duplicate_id and a.archived_at is null
    and not exists(select 1 from public.applications s where s.agency_id=v_agency and s.candidate_id=p_survivor_id and s.job_id=a.job_id and s.archived_at is null);
  update public.applications a set archived_at=now(),metadata=coalesce(a.metadata,'{}'::jsonb)||jsonb_build_object('merged_duplicate_candidate_id',p_duplicate_id,'surviving_candidate_id',p_survivor_id)
  where a.agency_id=v_agency and a.candidate_id=p_duplicate_id and a.archived_at is null;

  -- Carry non-conflicting talent-pool membership onto the survivor before the duplicate is archived.
  insert into public.talent_pool_members(agency_id,pool_id,candidate_id,added_by_user_id,source,created_at)
  select m.agency_id,m.pool_id,p_survivor_id,coalesce(m.added_by_user_id,v_user),'MERGE',m.created_at
  from public.talent_pool_members m where m.agency_id=v_agency and m.candidate_id=p_duplicate_id
  on conflict(pool_id,candidate_id) do nothing;

  update public.candidates set
    preferred_name=case when lower(coalesce(p_resolution->>'preferredName','keep'))='duplicate' then coalesce(v_dup.preferred_name,preferred_name) else preferred_name end,
    headline=case when lower(coalesce(p_resolution->>'headline','keep'))='duplicate' then coalesce(v_dup.headline,headline) else headline end,
    email=v_email,
    secondary_email=coalesce(secondary_email,case when v_email is distinct from v_surv.email then v_surv.email when v_email is distinct from v_dup.email then v_dup.email else null end),
    phone=v_phone,
    secondary_phone=coalesce(secondary_phone,case when v_phone is distinct from v_surv.phone then v_surv.phone when v_phone is distinct from v_dup.phone then v_dup.phone else null end),
    current_title=case when lower(coalesce(p_resolution->>'currentTitle','keep'))='duplicate' then coalesce(v_dup.current_title,current_title) else current_title end,
    current_company=case when lower(coalesce(p_resolution->>'currentCompany','keep'))='duplicate' then coalesce(v_dup.current_company,current_company) else current_company end,
    city=case when lower(coalesce(p_resolution->>'city','keep'))='duplicate' then coalesce(v_dup.city,city) else city end,
    region=case when lower(coalesce(p_resolution->>'region','keep'))='duplicate' then coalesce(v_dup.region,region) else region end,
    country_code=v_country,timezone=v_timezone,
    skills=(select coalesce(jsonb_agg(distinct val),'[]'::jsonb) from jsonb_array_elements(coalesce(skills,'[]'::jsonb)||coalesce(v_dup.skills,'[]'::jsonb)) val),
    languages=(select coalesce(jsonb_agg(distinct val),'[]'::jsonb) from jsonb_array_elements(coalesce(languages,'[]'::jsonb)||coalesce(v_dup.languages,'[]'::jsonb)) val),
    certifications=(select coalesce(jsonb_agg(distinct val),'[]'::jsonb) from jsonb_array_elements(coalesce(certifications,'[]'::jsonb)||coalesce(v_dup.certifications,'[]'::jsonb)) val),
    tags=(select coalesce(jsonb_agg(distinct val),'[]'::jsonb) from jsonb_array_elements(coalesce(tags,'[]'::jsonb)||coalesce(v_dup.tags,'[]'::jsonb)) val),
    updated_by_user_id=v_user,updated_at=now()
  where id=p_survivor_id and agency_id=v_agency;

  update public.candidates set merged_into_candidate_id=p_survivor_id,archived_at=now(),archived_by_user_id=v_user,updated_by_user_id=v_user,updated_at=now()
  where id=p_duplicate_id and agency_id=v_agency;
  insert into public.candidate_merge_events(agency_id,surviving_candidate_id,merged_candidate_id,field_resolution,merged_by_user_id)
  values(v_agency,p_survivor_id,p_duplicate_id,coalesce(p_resolution,'{}'::jsonb),v_user);
  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',p_survivor_id,'candidate.merged','Duplicate candidate merged',jsonb_build_object('merged_candidate_id',p_duplicate_id,'resolution',coalesce(p_resolution,'{}'::jsonb)));
  return jsonb_build_object('ok',true,'surviving_candidate_id',p_survivor_id,'merged_candidate_id',p_duplicate_id);
end;$fn$;

grant execute on function public.xzrecruiter_candidate_profile_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_update_candidate_profile(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_merge_candidates(text,uuid,uuid,jsonb) to anon,authenticated;
