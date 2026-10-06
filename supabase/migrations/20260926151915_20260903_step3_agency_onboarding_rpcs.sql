-- XZ Recruiter Step 3: session-aware onboarding/configuration RPCs.
-- Browser clients never supply agency_id; workspace ownership is derived from the verified application session.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.xzrecruiter_session_context(p_token text)
returns table(agency_id uuid,user_id uuid,role text)
language sql
stable
security definer
set search_path='public','extensions','pg_temp'
as $function$
  select s.agency_id,s.user_id,am.role
  from public.user_sessions s
  join public.users u on u.id=s.user_id and u.email_verified_at is not null
  join public.agency_memberships am on am.agency_id=s.agency_id and am.user_id=s.user_id
  where coalesce(p_token,'')<>''
    and s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and s.revoked_at is null
    and s.expires_at>now()
    and s.agency_id is not null
  limit 1;
$function$;
revoke all on function private.xzrecruiter_session_context(text) from public,anon,authenticated;

create or replace function private.xzrecruiter_ensure_default_pipelines(p_agency_id uuid,p_user_id uuid)
returns void
language plpgsql
security definer
set search_path='public','pg_temp'
as $function$
declare
  v_recruitment uuid;
  v_bd uuid;
begin
  select id into v_recruitment from public.recruitment_pipelines
  where agency_id=p_agency_id and pipeline_kind='RECRUITMENT' and is_default=true and active=true limit 1;

  if v_recruitment is null then
    insert into public.recruitment_pipelines(agency_id,pipeline_kind,recruitment_type,name,is_default,created_by_user_id)
    values(p_agency_id,'RECRUITMENT','PERMANENT_RECRUITMENT','Default recruitment pipeline',true,p_user_id)
    returning id into v_recruitment;

    insert into public.pipeline_stages(agency_id,pipeline_id,code,name,stage_category,status_semantic,sort_order,is_system,rejection_reasons) values
      (p_agency_id,v_recruitment,'NEW','New','ACTIVE','NEUTRAL',10,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'APPLIED','Applied','ACTIVE','INFO',20,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'SCREENING','Screening','ACTIVE','INFO',30,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'QUALIFIED','Qualified','ACTIVE','INFO',40,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'SHORTLISTED','Shortlisted','ACTIVE','INFO',50,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'SUBMITTED','Submitted','ACTIVE','INFO',60,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'INTERVIEW','Interview','ACTIVE','WARNING',70,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'OFFER','Offer','ACTIVE','WARNING',80,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'PLACED','Placed / Hired','TERMINAL','SUCCESS',90,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'REJECTED','Rejected','TERMINAL','DANGER',100,true,'["Skills mismatch","Experience mismatch","Compensation mismatch","Client decision","Other"]'::jsonb),
      (p_agency_id,v_recruitment,'WITHDRAWN','Withdrawn','TERMINAL','NEUTRAL',110,true,'[]'::jsonb),
      (p_agency_id,v_recruitment,'ON_HOLD','On Hold','TERMINAL','WARNING',120,true,'[]'::jsonb);
  end if;

  select id into v_bd from public.recruitment_pipelines
  where agency_id=p_agency_id and pipeline_kind='BUSINESS_DEVELOPMENT' and is_default=true and active=true limit 1;

  if v_bd is null then
    insert into public.recruitment_pipelines(agency_id,pipeline_kind,recruitment_type,name,is_default,created_by_user_id)
    values(p_agency_id,'BUSINESS_DEVELOPMENT',null,'Default business development pipeline',true,p_user_id)
    returning id into v_bd;

    insert into public.pipeline_stages(agency_id,pipeline_id,code,name,stage_category,status_semantic,sort_order,is_system) values
      (p_agency_id,v_bd,'TARGET_ACCOUNT','Target Account','ACTIVE','NEUTRAL',10,true),
      (p_agency_id,v_bd,'LEAD','Lead','ACTIVE','INFO',20,true),
      (p_agency_id,v_bd,'QUALIFIED','Qualified','ACTIVE','INFO',30,true),
      (p_agency_id,v_bd,'CONTACTED','Contacted','ACTIVE','INFO',40,true),
      (p_agency_id,v_bd,'CONVERSATION','Conversation','ACTIVE','INFO',50,true),
      (p_agency_id,v_bd,'MEETING','Meeting','ACTIVE','WARNING',60,true),
      (p_agency_id,v_bd,'OPPORTUNITY','Opportunity','ACTIVE','WARNING',70,true),
      (p_agency_id,v_bd,'CLIENT','Client','ACTIVE','SUCCESS',80,true),
      (p_agency_id,v_bd,'REQUIREMENT','Requirement','ACTIVE','SUCCESS',90,true),
      (p_agency_id,v_bd,'PLACEMENT','Placement','TERMINAL','SUCCESS',100,true),
      (p_agency_id,v_bd,'LOST','Lost','TERMINAL','DANGER',110,true),
      (p_agency_id,v_bd,'DISQUALIFIED','Disqualified','TERMINAL','DANGER',120,true),
      (p_agency_id,v_bd,'NURTURE','Nurture','TERMINAL','NEUTRAL',130,true);
  end if;
end;
$function$;
revoke all on function private.xzrecruiter_ensure_default_pipelines(uuid,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_onboarding_context(p_token text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;
  v_user_id uuid;
  v_role text;
  v_result jsonb;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  perform private.xzrecruiter_ensure_default_pipelines(v_agency_id,v_user_id);

  select jsonb_build_object(
    'ok',true,
    'workspace_id',v_agency_id,
    'role',v_role,
    'progress',coalesce((select to_jsonb(p) from public.onboarding_progress p where p.agency_id=v_agency_id),
      jsonb_build_object('setup_mode','QUICK','status','NOT_STARTED','current_step','profile','completed_steps','[]'::jsonb,'skipped_steps','[]'::jsonb,'progress_percent',0)),
    'profile',coalesce((select to_jsonb(p) from public.agency_operating_profiles p where p.agency_id=v_agency_id),'{}'::jsonb),
    'business_models',coalesce((select jsonb_agg(model_code order by is_primary desc,model_code) from public.agency_business_models where agency_id=v_agency_id),'[]'::jsonb),
    'markets',coalesce((select jsonb_agg(to_jsonb(m) order by case when priority='PRIMARY' then 0 else 1 end,country_code,region,city) from public.agency_market_targets m where m.agency_id=v_agency_id),'[]'::jsonb),
    'taxonomy_preferences',coalesce((select jsonb_agg(jsonb_build_object('context',p.context,'favourite',p.favourite,'id',t.id,'domain',t.domain,'code',t.code,'label',t.label,'parent_id',t.parent_id,'level',t.level) order by p.context,t.domain,t.sort_order,t.label)
      from public.agency_taxonomy_preferences p join public.taxonomy_nodes t on t.id=p.taxonomy_id where p.agency_id=v_agency_id),'[]'::jsonb),
    'icp',coalesce((select to_jsonb(i) from public.agency_icp_profiles i where i.agency_id=v_agency_id),'{}'::jsonb),
    'specializations',coalesce((select jsonb_agg(to_jsonb(s) order by context,item_type,created_at) from public.agency_specialization_items s where s.agency_id=v_agency_id),'[]'::jsonb),
    'pipelines',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'pipeline_kind',p.pipeline_kind,'recruitment_type',p.recruitment_type,'name',p.name,'is_default',p.is_default,'active',p.active,
      'stages',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order,s.created_at) from public.pipeline_stages s where s.pipeline_id=p.id),'[]'::jsonb)) order by p.pipeline_kind,p.is_default desc,p.name)
      from public.recruitment_pipelines p where p.agency_id=v_agency_id and p.active=true),'[]'::jsonb),
    'custom_field_groups',coalesce((select jsonb_agg(to_jsonb(g) order by module,sort_order,name) from public.custom_field_groups g where g.agency_id=v_agency_id and active=true),'[]'::jsonb),
    'custom_fields',coalesce((select jsonb_agg(to_jsonb(f) order by module,sort_order,label) from public.custom_field_definitions f where f.agency_id=v_agency_id and active=true),'[]'::jsonb),
    'saved_views',coalesce((select jsonb_agg(to_jsonb(v) order by module,name) from public.saved_views v where v.agency_id=v_agency_id and v.active=true and (v.scope='TEAM' or v.owner_user_id=v_user_id)),'[]'::jsonb),
    'departments',coalesce((select jsonb_agg(to_jsonb(d) order by name) from public.workspace_departments d where d.agency_id=v_agency_id and active=true),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(to_jsonb(t) order by name) from public.workspace_teams t where t.agency_id=v_agency_id and active=true),'[]'::jsonb),
    'member_profile',coalesce((select to_jsonb(mp) from public.workspace_member_profiles mp where mp.agency_id=v_agency_id and mp.user_id=v_user_id),'{}'::jsonb),
    'invitations',coalesce((select jsonb_agg(to_jsonb(i) order by created_at desc) from public.workspace_invitations i where i.agency_id=v_agency_id),'[]'::jsonb),
    'territories',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'parent_id',t.parent_id,'rules',coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order) from public.territory_rules r where r.territory_id=t.id),'[]'::jsonb)) order by t.name) from public.workspace_territories t where t.agency_id=v_agency_id and t.active=true),'[]'::jsonb),
    'presets',coalesce((select jsonb_agg(to_jsonb(p) order by sort_order,name) from public.agency_presets p where p.active=true),'[]'::jsonb),
    'taxonomies',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'domain',t.domain,'code',t.code,'label',t.label,'parent_id',t.parent_id,'level',t.level,'sort_order',t.sort_order,'custom',t.agency_id is not null) order by t.domain,t.level,t.sort_order,t.label)
      from public.taxonomy_nodes t where t.active=true and (t.agency_id is null or t.agency_id=v_agency_id) and t.domain in ('INDUSTRY','COMPANY_SIZE','COMPANY_TYPE','FUNDING_STAGE','JOB_FUNCTION','SENIORITY','EMPLOYMENT_TYPE','WORK_AUTHORIZATION_STATUS')),'[]'::jsonb),
    'section_state',coalesce((select jsonb_object_agg(section_key,jsonb_build_object('payload',payload,'completed',completed,'updated_at',updated_at)) from public.onboarding_section_state where agency_id=v_agency_id),'{}'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;

create or replace function public.xzrecruiter_save_onboarding_section(p_token text,p_section text,p_payload jsonb,p_mark_complete boolean default false)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;
  v_user_id uuid;
  v_role text;
  v_section text:=lower(btrim(coalesce(p_section,'')));
  v_code text;
  v_item jsonb;
  v_taxonomy uuid;
  v_country text;
  v_timezone text;
  v_currency text;
  v_language text;
  v_locale text;
  v_completed jsonb;
  v_progress smallint;
  v_department_id uuid;
  v_office_id uuid;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_section not in ('profile','markets','industries','icp','specialization','candidate','pipelines','team','import','review') then
    return jsonb_build_object('ok',false,'error','invalid_section');
  end if;

  insert into public.onboarding_section_state(agency_id,section_key,payload,completed,updated_by_user_id)
  values(v_agency_id,v_section,coalesce(p_payload,'{}'::jsonb),p_mark_complete,v_user_id)
  on conflict(agency_id,section_key) do update set payload=excluded.payload,completed=(public.onboarding_section_state.completed or excluded.completed),updated_by_user_id=excluded.updated_by_user_id,updated_at=now();

  if v_section='profile' then
    v_country:=upper(btrim(coalesce(p_payload->>'countryCode','')));
    v_timezone:=btrim(coalesce(p_payload->>'timezoneId',''));
    v_currency:=upper(btrim(coalesce(p_payload->>'currencyCode','')));
    v_language:=lower(btrim(coalesce(p_payload->>'languageCode','')));
    v_locale:=btrim(coalesce(p_payload->>'locale',''));
    if not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
    if not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
    if v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency'); end if;
    if not exists(select 1 from public.global_languages where language_code=v_language and enabled=true) then return jsonb_build_object('ok',false,'error','invalid_language'); end if;
    if v_locale !~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$' then return jsonb_build_object('ok',false,'error','invalid_locale'); end if;

    update public.agencies set name=coalesce(nullif(btrim(p_payload->>'workspaceName'),''),name),country=v_country,timezone=v_timezone,updated_at=now() where id=v_agency_id;
    insert into public.workspace_global_settings(agency_id,country_code,locale,currency_code,timezone_id,language_code)
    values(v_agency_id,v_country,v_locale,v_currency,v_timezone,v_language)
    on conflict(agency_id) do update set country_code=excluded.country_code,locale=excluded.locale,currency_code=excluded.currency_code,timezone_id=excluded.timezone_id,language_code=excluded.language_code,updated_at=now();
    insert into public.user_global_preferences(agency_id,user_id,locale,timezone_id,language_code,currency_code)
    values(v_agency_id,v_user_id,v_locale,v_timezone,v_language,v_currency)
    on conflict(agency_id,user_id) do update set locale=excluded.locale,timezone_id=excluded.timezone_id,language_code=excluded.language_code,currency_code=excluded.currency_code,updated_at=now();
    update public.users set locale=v_locale,timezone=v_timezone,language_code=v_language,updated_at=now() where id=v_user_id;

    insert into public.agency_operating_profiles(agency_id,business_name,website,team_size,recruiter_count,setup_mode,terminology_mode)
    values(v_agency_id,nullif(btrim(p_payload->>'businessName'),''),nullif(btrim(p_payload->>'website'),''),nullif(p_payload->>'teamSize','')::integer,nullif(p_payload->>'recruiterCount','')::integer,
      case when upper(coalesce(p_payload->>'setupMode','QUICK'))='ADVANCED' then 'ADVANCED' else 'QUICK' end,
      case when upper(coalesce(p_payload->>'terminologyMode','AUTO')) in ('CV','RESUME') then upper(p_payload->>'terminologyMode') else 'AUTO' end)
    on conflict(agency_id) do update set business_name=excluded.business_name,website=excluded.website,team_size=excluded.team_size,recruiter_count=excluded.recruiter_count,setup_mode=excluded.setup_mode,terminology_mode=excluded.terminology_mode,updated_at=now();

    delete from public.agency_business_models where agency_id=v_agency_id;
    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'businessModels','[]'::jsonb)) loop
      insert into public.agency_business_models(agency_id,model_code,is_primary)
      values(v_agency_id,v_code,not exists(select 1 from public.agency_business_models where agency_id=v_agency_id))
      on conflict do nothing;
    end loop;

    for v_item in select value from jsonb_array_elements(coalesce(p_payload->'offices','[]'::jsonb)) loop
      if nullif(btrim(v_item->>'name'),'') is not null
         and exists(select 1 from public.global_country_profiles where country_code=upper(v_item->>'countryCode'))
         and public.xzrecruiter_valid_timezone(v_item->>'timezoneId') then
        select id into v_office_id from public.recruitment_offices where agency_id=v_agency_id and lower(name)=lower(v_item->>'name') limit 1;
        if v_office_id is null then
          insert into public.recruitment_offices(agency_id,name,country_code,timezone_id,locale,currency_code)
          values(v_agency_id,btrim(v_item->>'name'),upper(v_item->>'countryCode'),v_item->>'timezoneId',nullif(v_item->>'locale',''),upper(nullif(v_item->>'currencyCode','')))
          returning id into v_office_id;
        else
          update public.recruitment_offices set country_code=upper(v_item->>'countryCode'),timezone_id=v_item->>'timezoneId',locale=nullif(v_item->>'locale',''),currency_code=upper(nullif(v_item->>'currencyCode','')),active=true,updated_at=now() where id=v_office_id;
        end if;
      end if;
    end loop;
  end if;

  if v_section='markets' then
    update public.workspace_markets set enabled=false,updated_at=now() where agency_id=v_agency_id;
    delete from public.agency_market_targets where agency_id=v_agency_id and target_kind in ('RECRUITING','HEADQUARTERS','OFFICE');
    for v_item in select value from jsonb_array_elements(coalesce(p_payload->'markets','[]'::jsonb)) loop
      v_country:=upper(btrim(coalesce(v_item->>'countryCode','')));
      if exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then
        insert into public.workspace_markets(agency_id,country_code,enabled) values(v_agency_id,v_country,true)
        on conflict(agency_id,country_code) do update set enabled=true,updated_at=now();
        insert into public.agency_market_targets(agency_id,country_code,region,city,market_type,priority,target_kind,timezone_id,preferred)
        values(v_agency_id,v_country,nullif(btrim(v_item->>'region'),''),nullif(btrim(v_item->>'city'),''),
          case when upper(coalesce(v_item->>'marketType','ANY')) in ('ONSITE','REMOTE','HYBRID') then upper(v_item->>'marketType') else 'ANY' end,
          case when upper(coalesce(v_item->>'priority','SECONDARY'))='PRIMARY' then 'PRIMARY' else 'SECONDARY' end,
          case when upper(coalesce(v_item->>'targetKind','RECRUITING')) in ('HEADQUARTERS','OFFICE','CANDIDATE') then upper(v_item->>'targetKind') else 'RECRUITING' end,
          case when nullif(v_item->>'timezoneId','') is null then null when public.xzrecruiter_valid_timezone(v_item->>'timezoneId') then v_item->>'timezoneId' else null end,
          coalesce((v_item->>'preferred')::boolean,false));
      end if;
    end loop;
  end if;

  if v_section='industries' then
    delete from public.agency_taxonomy_preferences where agency_id=v_agency_id and context='INDUSTRY';
    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'industries','[]'::jsonb)) loop
      select id into v_taxonomy from public.taxonomy_nodes where domain='INDUSTRY' and code=v_code and active=true and (agency_id is null or agency_id=v_agency_id) limit 1;
      if v_taxonomy is not null then insert into public.agency_taxonomy_preferences(agency_id,taxonomy_id,context,favourite) values(v_agency_id,v_taxonomy,'INDUSTRY',false) on conflict do nothing; end if;
      v_taxonomy:=null;
    end loop;
  end if;

  if v_section='icp' then
    insert into public.agency_icp_profiles(agency_id,employee_growth_preference,hiring_volume_preference,remote_first_preference,company_scope,revenue_bands,notes)
    values(v_agency_id,
      case when upper(coalesce(p_payload->>'employeeGrowth','ANY')) in ('GROWING','FAST_GROWING','STABLE') then upper(p_payload->>'employeeGrowth') else 'ANY' end,
      case when upper(coalesce(p_payload->>'hiringVolume','ANY')) in ('LOW','MEDIUM','HIGH','VERY_HIGH') then upper(p_payload->>'hiringVolume') else 'ANY' end,
      case when upper(coalesce(p_payload->>'remotePreference','ANY')) in ('REMOTE_FIRST','HYBRID','OFFICE_FIRST') then upper(p_payload->>'remotePreference') else 'ANY' end,
      case when upper(coalesce(p_payload->>'companyScope','ANY')) in ('LOCAL','MULTINATIONAL') then upper(p_payload->>'companyScope') else 'ANY' end,
      coalesce(p_payload->'revenueBands','[]'::jsonb),nullif(btrim(p_payload->>'notes'),''))
    on conflict(agency_id) do update set employee_growth_preference=excluded.employee_growth_preference,hiring_volume_preference=excluded.hiring_volume_preference,remote_first_preference=excluded.remote_first_preference,company_scope=excluded.company_scope,revenue_bands=excluded.revenue_bands,notes=excluded.notes,updated_at=now();

    delete from public.agency_taxonomy_preferences where agency_id=v_agency_id and context='ICP';
    for v_item in select value from jsonb_array_elements(jsonb_build_array(
      jsonb_build_object('domain','COMPANY_SIZE','items',coalesce(p_payload->'companySizes','[]'::jsonb)),
      jsonb_build_object('domain','COMPANY_TYPE','items',coalesce(p_payload->'companyTypes','[]'::jsonb)),
      jsonb_build_object('domain','FUNDING_STAGE','items',coalesce(p_payload->'fundingStages','[]'::jsonb)),
      jsonb_build_object('domain','INDUSTRY','items',coalesce(p_payload->'industries','[]'::jsonb)))) loop
      for v_code in select jsonb_array_elements_text(v_item->'items') loop
        select id into v_taxonomy from public.taxonomy_nodes where domain=v_item->>'domain' and code=v_code and active=true and (agency_id is null or agency_id=v_agency_id) limit 1;
        if v_taxonomy is not null then insert into public.agency_taxonomy_preferences(agency_id,taxonomy_id,context) values(v_agency_id,v_taxonomy,'ICP') on conflict do nothing; end if;
        v_taxonomy:=null;
      end loop;
    end loop;
  end if;

  if v_section in ('specialization','candidate') then
    delete from public.agency_taxonomy_preferences where agency_id=v_agency_id and context=case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end;
    delete from public.agency_specialization_items where agency_id=v_agency_id and context=case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end;

    for v_item in select value from jsonb_array_elements(jsonb_build_array(
      jsonb_build_object('domain','JOB_FUNCTION','items',coalesce(p_payload->'jobFunctions','[]'::jsonb)),
      jsonb_build_object('domain','SENIORITY','items',coalesce(p_payload->'seniority','[]'::jsonb)),
      jsonb_build_object('domain','EMPLOYMENT_TYPE','items',coalesce(p_payload->'employmentTypes','[]'::jsonb)),
      jsonb_build_object('domain','INDUSTRY','items',coalesce(p_payload->'industries','[]'::jsonb)))) loop
      for v_code in select jsonb_array_elements_text(v_item->'items') loop
        select id into v_taxonomy from public.taxonomy_nodes where domain=v_item->>'domain' and code=v_code and active=true and (agency_id is null or agency_id=v_agency_id) limit 1;
        if v_taxonomy is not null then insert into public.agency_taxonomy_preferences(agency_id,taxonomy_id,context) values(v_agency_id,v_taxonomy,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end) on conflict do nothing; end if;
        v_taxonomy:=null;
      end loop;
    end loop;

    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'skills','[]'::jsonb)) loop
      insert into public.agency_specialization_items(agency_id,context,item_type,text_value) values(v_agency_id,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end,'SKILL',v_code);
    end loop;
    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'roles','[]'::jsonb)) loop
      insert into public.agency_specialization_items(agency_id,context,item_type,text_value) values(v_agency_id,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end,'ROLE',v_code);
    end loop;
    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'languages','[]'::jsonb)) loop
      insert into public.agency_specialization_items(agency_id,context,item_type,text_value) values(v_agency_id,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end,'LANGUAGE',v_code);
    end loop;
    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'countries','[]'::jsonb)) loop
      if exists(select 1 from public.global_country_profiles where country_code=upper(v_code) and active=true) then
        insert into public.agency_specialization_items(agency_id,context,item_type,country_code) values(v_agency_id,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end,'COUNTRY',upper(v_code));
      end if;
    end loop;
    if p_payload ? 'salaryMin' and nullif(p_payload->>'salaryMin','') is not null then
      insert into public.agency_specialization_items(agency_id,context,item_type,currency_code,amount_min,amount_max)
      values(v_agency_id,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end,'SALARY_BAND',upper(coalesce(p_payload->>'currencyCode','USD')),nullif(p_payload->>'salaryMin','')::numeric,nullif(p_payload->>'salaryMax','')::numeric);
    end if;
    if v_section='candidate' and nullif(p_payload->>'noticeDaysMin','') is not null then
      insert into public.agency_specialization_items(agency_id,context,item_type,notice_days_min,notice_days_max)
      values(v_agency_id,'CANDIDATE','NOTICE_PERIOD',nullif(p_payload->>'noticeDaysMin','')::integer,nullif(p_payload->>'noticeDaysMax','')::integer);
    end if;
    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'workplace','[]'::jsonb)) loop
      insert into public.agency_specialization_items(agency_id,context,item_type,text_value) values(v_agency_id,case when v_section='candidate' then 'CANDIDATE' else 'RECRUITMENT' end,'WORKPLACE',upper(v_code));
    end loop;
  end if;

  if v_section='pipelines' then
    perform private.xzrecruiter_ensure_default_pipelines(v_agency_id,v_user_id);
  end if;

  if v_section='team' then
    insert into public.workspace_member_profiles(agency_id,user_id,business_role)
    values(v_agency_id,v_user_id,case when v_role='OWNER' then 'OWNER' when v_role='ADMIN' then 'ADMIN' else 'RECRUITER' end)
    on conflict(agency_id,user_id) do update set updated_at=now();

    for v_code in select jsonb_array_elements_text(coalesce(p_payload->'departments','[]'::jsonb)) loop
      if nullif(btrim(v_code),'') is not null then insert into public.workspace_departments(agency_id,name) values(v_agency_id,btrim(v_code)) on conflict(agency_id,name) do update set active=true,updated_at=now(); end if;
    end loop;
    for v_item in select value from jsonb_array_elements(coalesce(p_payload->'teams','[]'::jsonb)) loop
      v_department_id:=null;
      if nullif(btrim(v_item->>'department'),'') is not null then select id into v_department_id from public.workspace_departments where agency_id=v_agency_id and lower(name)=lower(v_item->>'department') limit 1; end if;
      if nullif(btrim(v_item->>'name'),'') is not null then
        insert into public.workspace_teams(agency_id,name,department_id) values(v_agency_id,btrim(v_item->>'name'),v_department_id)
        on conflict(agency_id,name) do update set department_id=excluded.department_id,active=true,updated_at=now();
      end if;
    end loop;
    for v_item in select value from jsonb_array_elements(coalesce(p_payload->'invites','[]'::jsonb)) loop
      if lower(coalesce(v_item->>'email','')) ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        insert into public.workspace_invitations(agency_id,email,rbac_role,business_role,status,invited_by_user_id)
        values(v_agency_id,lower(btrim(v_item->>'email')),
          case when upper(coalesce(v_item->>'rbacRole','RECRUITER')) in ('ADMIN','VIEWER','MEMBER') then upper(v_item->>'rbacRole') else 'RECRUITER' end,
          upper(coalesce(v_item->>'businessRole','RECRUITER')),'DRAFT',v_user_id)
        on conflict(agency_id,email) do update set rbac_role=excluded.rbac_role,business_role=excluded.business_role,updated_at=now();
      end if;
    end loop;
  end if;

  insert into public.onboarding_progress(agency_id,setup_mode,status,current_step,completed_steps,progress_percent,started_at,last_saved_at)
  values(v_agency_id,case when upper(coalesce(p_payload->>'setupMode','QUICK'))='ADVANCED' then 'ADVANCED' else coalesce((select setup_mode from public.agency_operating_profiles where agency_id=v_agency_id),'QUICK') end,
    'IN_PROGRESS',v_section,case when p_mark_complete then jsonb_build_array(v_section) else '[]'::jsonb end,case when p_mark_complete then 12 else 2 end,now(),now())
  on conflict(agency_id) do update set
    status=case when public.onboarding_progress.status='COMPLETED' then 'COMPLETED' else 'IN_PROGRESS' end,
    current_step=excluded.current_step,
    completed_steps=case when p_mark_complete and not (public.onboarding_progress.completed_steps ? v_section) then public.onboarding_progress.completed_steps || jsonb_build_array(v_section) else public.onboarding_progress.completed_steps end,
    progress_percent=case when public.onboarding_progress.status='COMPLETED' then 100 else least(95, greatest(public.onboarding_progress.progress_percent, jsonb_array_length(case when p_mark_complete and not (public.onboarding_progress.completed_steps ? v_section) then public.onboarding_progress.completed_steps || jsonb_build_array(v_section) else public.onboarding_progress.completed_steps end)*12)) end,
    started_at=coalesce(public.onboarding_progress.started_at,now()),last_saved_at=now(),updated_at=now();

  select completed_steps,progress_percent into v_completed,v_progress from public.onboarding_progress where agency_id=v_agency_id;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(gen_random_uuid(),v_agency_id,v_user_id,'onboarding.section_saved','agency',v_agency_id,jsonb_build_object('section',v_section,'completed',p_mark_complete));
  return jsonb_build_object('ok',true,'section',v_section,'completed_steps',v_completed,'progress_percent',v_progress);
end;
$function$;

create or replace function public.xzrecruiter_complete_onboarding(p_token text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;
  v_user_id uuid;
  v_role text;
  v_missing jsonb:='[]'::jsonb;
  v_section text;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  perform private.xzrecruiter_ensure_default_pipelines(v_agency_id,v_user_id);
  foreach v_section in array array['profile','markets','industries','icp','specialization','pipelines'] loop
    if not exists(select 1 from public.onboarding_section_state where agency_id=v_agency_id and section_key=v_section and completed=true) then v_missing:=v_missing||jsonb_build_array(v_section); end if;
  end loop;
  if jsonb_array_length(v_missing)>0 then return jsonb_build_object('ok',false,'error','setup_incomplete','missing',v_missing); end if;
  if not exists(select 1 from public.recruitment_pipelines where agency_id=v_agency_id and pipeline_kind='RECRUITMENT' and active=true) or not exists(select 1 from public.recruitment_pipelines where agency_id=v_agency_id and pipeline_kind='BUSINESS_DEVELOPMENT' and active=true) then
    return jsonb_build_object('ok',false,'error','pipelines_missing');
  end if;
  insert into public.onboarding_progress(agency_id,status,current_step,completed_steps,progress_percent,started_at,last_saved_at,completed_at)
  values(v_agency_id,'COMPLETED','review','["profile","markets","industries","icp","specialization","pipelines","review"]'::jsonb,100,now(),now(),now())
  on conflict(agency_id) do update set status='COMPLETED',current_step='review',progress_percent=100,last_saved_at=now(),completed_at=now(),updated_at=now();
  update public.agencies set onboarding_status='COMPLETED',onboarding_completed_at=now(),updated_at=now() where id=v_agency_id;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(gen_random_uuid(),v_agency_id,v_user_id,'onboarding.completed','agency',v_agency_id,jsonb_build_object('version','step3'));
  return jsonb_build_object('ok',true,'status','COMPLETED');
end;
$function$;

create or replace function public.xzrecruiter_save_pipeline(p_token text,p_pipeline jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid; v_user_id uuid; v_role text; v_pipeline_id uuid; v_stage jsonb; v_code text; v_seen text[]:='{}';
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  begin v_pipeline_id:=nullif(p_pipeline->>'id','')::uuid; exception when others then v_pipeline_id:=null; end;
  if v_pipeline_id is not null then
    if not exists(select 1 from public.recruitment_pipelines where id=v_pipeline_id and agency_id=v_agency_id) then return jsonb_build_object('ok',false,'error','pipeline_not_found'); end if;
    update public.recruitment_pipelines set name=coalesce(nullif(btrim(p_pipeline->>'name'),''),name),recruitment_type=nullif(p_pipeline->>'recruitmentType',''),is_default=coalesce((p_pipeline->>'isDefault')::boolean,is_default),updated_at=now() where id=v_pipeline_id and agency_id=v_agency_id;
  else
    insert into public.recruitment_pipelines(agency_id,pipeline_kind,recruitment_type,name,is_default,created_by_user_id)
    values(v_agency_id,case when upper(coalesce(p_pipeline->>'pipelineKind','RECRUITMENT'))='BUSINESS_DEVELOPMENT' then 'BUSINESS_DEVELOPMENT' else 'RECRUITMENT' end,nullif(p_pipeline->>'recruitmentType',''),coalesce(nullif(btrim(p_pipeline->>'name'),''),'Custom pipeline'),coalesce((p_pipeline->>'isDefault')::boolean,false),v_user_id)
    returning id into v_pipeline_id;
  end if;
  for v_stage in select value from jsonb_array_elements(coalesce(p_pipeline->'stages','[]'::jsonb)) loop
    v_code:=upper(regexp_replace(coalesce(nullif(v_stage->>'code',''),v_stage->>'name','STAGE'),'[^A-Za-z0-9]+','_','g'));
    v_seen:=array_append(v_seen,v_code);
    insert into public.pipeline_stages(agency_id,pipeline_id,code,name,stage_category,status_semantic,sort_order,required_fields,rejection_reasons,transition_rules,is_system)
    values(v_agency_id,v_pipeline_id,v_code,coalesce(nullif(btrim(v_stage->>'name'),''),initcap(replace(v_code,'_',' '))),case when upper(coalesce(v_stage->>'category','ACTIVE'))='TERMINAL' then 'TERMINAL' else 'ACTIVE' end,
      case when upper(coalesce(v_stage->>'semantic','NEUTRAL')) in ('INFO','WARNING','SUCCESS','DANGER') then upper(v_stage->>'semantic') else 'NEUTRAL' end,
      coalesce(nullif(v_stage->>'sortOrder','')::integer,100),coalesce(v_stage->'requiredFields','[]'::jsonb),coalesce(v_stage->'rejectionReasons','[]'::jsonb),coalesce(v_stage->'transitionRules','{}'::jsonb),false)
    on conflict(pipeline_id,code) do update set name=excluded.name,stage_category=excluded.stage_category,status_semantic=excluded.status_semantic,sort_order=excluded.sort_order,required_fields=excluded.required_fields,rejection_reasons=excluded.rejection_reasons,transition_rules=excluded.transition_rules,updated_at=now();
  end loop;
  if cardinality(v_seen)>0 then delete from public.pipeline_stages where agency_id=v_agency_id and pipeline_id=v_pipeline_id and not (code=any(v_seen)) and is_system=false; end if;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'config.pipeline_saved','pipeline',v_pipeline_id,jsonb_build_object('name',p_pipeline->>'name'));
  return jsonb_build_object('ok',true,'id',v_pipeline_id);
end;
$function$;

create or replace function public.xzrecruiter_add_custom_taxonomy(p_token text,p_domain text,p_parent_id uuid,p_label text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_id uuid;v_code text;v_level smallint:=0;v_domain text:=upper(btrim(coalesce(p_domain,'')));
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_domain not in ('INDUSTRY','JOB_FUNCTION','SENIORITY','EMPLOYMENT_TYPE') or nullif(btrim(p_label),'') is null then return jsonb_build_object('ok',false,'error','invalid_taxonomy'); end if;
  if p_parent_id is not null then select level+1 into v_level from public.taxonomy_nodes where id=p_parent_id and domain=v_domain and active=true and (agency_id is null or agency_id=v_agency_id); if v_level is null then return jsonb_build_object('ok',false,'error','invalid_parent'); end if; end if;
  v_code:='CUSTOM_'||upper(regexp_replace(btrim(p_label),'[^A-Za-z0-9]+','_','g'))||'_'||upper(substr(md5(v_agency_id::text||p_label),1,6));
  insert into public.taxonomy_nodes(agency_id,domain,code,label,parent_id,level,sort_order) values(v_agency_id,v_domain,v_code,btrim(p_label),p_parent_id,v_level,900) returning id into v_id;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'config.taxonomy_created','taxonomy',v_id,jsonb_build_object('domain',v_domain,'label',p_label));
  return jsonb_build_object('ok',true,'id',v_id,'code',v_code,'label',btrim(p_label));
exception when unique_violation then
  select id into v_id from public.taxonomy_nodes where agency_id=v_agency_id and domain=v_domain and code=v_code limit 1;
  return jsonb_build_object('ok',true,'id',v_id,'code',v_code,'label',btrim(p_label),'existing',true);
end;
$function$;

create or replace function public.xzrecruiter_save_custom_field(p_token text,p_field jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_id uuid;v_module text:=upper(coalesce(p_field->>'module',''));v_type text:=upper(coalesce(p_field->>'fieldType','TEXT'));v_key text;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_module not in ('CANDIDATE','JOB','COMPANY','CLIENT','CONTACT','OPPORTUNITY') then return jsonb_build_object('ok',false,'error','invalid_module'); end if;
  if v_type not in ('TEXT','LONG_TEXT','NUMBER','DECIMAL','CURRENCY','PERCENTAGE','DATE','DATETIME','CHECKBOX','SINGLE_SELECT','MULTI_SELECT','EMAIL','PHONE','URL','COUNTRY','TIMEZONE','USER','COMPANY','CANDIDATE','JOB','TAG') then return jsonb_build_object('ok',false,'error','invalid_field_type'); end if;
  if nullif(btrim(p_field->>'label'),'') is null then return jsonb_build_object('ok',false,'error','label_required'); end if;
  v_key:=lower(regexp_replace(coalesce(nullif(p_field->>'fieldKey',''),p_field->>'label'),'[^A-Za-z0-9]+','_','g'));
  begin v_id:=nullif(p_field->>'id','')::uuid; exception when others then v_id:=null; end;
  if v_id is null then
    insert into public.custom_field_definitions(agency_id,module,field_key,label,field_type,required,help_text,default_value,validation_rules,options,searchable,filterable,visibility,sort_order)
    values(v_agency_id,v_module,v_key,btrim(p_field->>'label'),v_type,coalesce((p_field->>'required')::boolean,false),nullif(p_field->>'helpText',''),p_field->'defaultValue',coalesce(p_field->'validation','{}'::jsonb),coalesce(p_field->'options','[]'::jsonb),coalesce((p_field->>'searchable')::boolean,false),coalesce((p_field->>'filterable')::boolean,false),upper(coalesce(p_field->>'visibility','ALL')),coalesce(nullif(p_field->>'sortOrder','')::integer,100)) returning id into v_id;
  else
    if not exists(select 1 from public.custom_field_definitions where id=v_id and agency_id=v_agency_id) then return jsonb_build_object('ok',false,'error','field_not_found'); end if;
    update public.custom_field_definitions set label=btrim(p_field->>'label'),field_type=v_type,required=coalesce((p_field->>'required')::boolean,false),help_text=nullif(p_field->>'helpText',''),default_value=p_field->'defaultValue',validation_rules=coalesce(p_field->'validation','{}'::jsonb),options=coalesce(p_field->'options','[]'::jsonb),searchable=coalesce((p_field->>'searchable')::boolean,false),filterable=coalesce((p_field->>'filterable')::boolean,false),visibility=upper(coalesce(p_field->>'visibility','ALL')),sort_order=coalesce(nullif(p_field->>'sortOrder','')::integer,100),updated_at=now() where id=v_id and agency_id=v_agency_id;
  end if;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'config.custom_field_saved','custom_field',v_id,jsonb_build_object('module',v_module,'field_key',v_key));
  return jsonb_build_object('ok',true,'id',v_id,'field_key',v_key);
end;
$function$;

create or replace function public.xzrecruiter_save_view(p_token text,p_view jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_id uuid;v_scope text:=upper(coalesce(p_view->>'scope','PERSONAL'));
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_scope='TEAM' and v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if nullif(btrim(p_view->>'module'),'') is null or nullif(btrim(p_view->>'name'),'') is null then return jsonb_build_object('ok',false,'error','invalid_view'); end if;
  begin v_id:=nullif(p_view->>'id','')::uuid; exception when others then v_id:=null; end;
  if v_id is null then
    insert into public.saved_views(agency_id,owner_user_id,module,name,scope,filter_logic,filters,sort_config,visible_columns,column_order,is_default)
    values(v_agency_id,v_user_id,upper(p_view->>'module'),btrim(p_view->>'name'),case when v_scope='TEAM' then 'TEAM' else 'PERSONAL' end,case when upper(coalesce(p_view->>'filterLogic','AND'))='OR' then 'OR' else 'AND' end,coalesce(p_view->'filters','[]'::jsonb),coalesce(p_view->'sort','[]'::jsonb),coalesce(p_view->'visibleColumns','[]'::jsonb),coalesce(p_view->'columnOrder','[]'::jsonb),coalesce((p_view->>'isDefault')::boolean,false)) returning id into v_id;
  else
    if not exists(select 1 from public.saved_views where id=v_id and agency_id=v_agency_id and (owner_user_id=v_user_id or v_role in ('OWNER','ADMIN'))) then return jsonb_build_object('ok',false,'error','view_not_found'); end if;
    update public.saved_views set name=btrim(p_view->>'name'),scope=case when v_scope='TEAM' then 'TEAM' else 'PERSONAL' end,filter_logic=case when upper(coalesce(p_view->>'filterLogic','AND'))='OR' then 'OR' else 'AND' end,filters=coalesce(p_view->'filters','[]'::jsonb),sort_config=coalesce(p_view->'sort','[]'::jsonb),visible_columns=coalesce(p_view->'visibleColumns','[]'::jsonb),column_order=coalesce(p_view->'columnOrder','[]'::jsonb),updated_at=now() where id=v_id and agency_id=v_agency_id;
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
end;
$function$;

create or replace function public.xzrecruiter_save_territory(p_token text,p_territory jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare v_agency_id uuid;v_user_id uuid;v_role text;v_id uuid;v_rule jsonb;v_sort integer:=0;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if nullif(btrim(p_territory->>'name'),'') is null then return jsonb_build_object('ok',false,'error','name_required'); end if;
  begin v_id:=nullif(p_territory->>'id','')::uuid; exception when others then v_id:=null; end;
  if v_id is null then insert into public.workspace_territories(agency_id,name,parent_id) values(v_agency_id,btrim(p_territory->>'name'),nullif(p_territory->>'parentId','')::uuid) returning id into v_id;
  else update public.workspace_territories set name=btrim(p_territory->>'name'),parent_id=nullif(p_territory->>'parentId','')::uuid,updated_at=now() where id=v_id and agency_id=v_agency_id; if not found then return jsonb_build_object('ok',false,'error','territory_not_found'); end if; end if;
  delete from public.territory_rules where agency_id=v_agency_id and territory_id=v_id;
  for v_rule in select value from jsonb_array_elements(coalesce(p_territory->'rules','[]'::jsonb)) loop
    v_sort:=v_sort+10;
    if upper(coalesce(v_rule->>'dimension','')) in ('COUNTRY','REGION','CITY','INDUSTRY','JOB_FUNCTION','ACCOUNT_SEGMENT') then
      insert into public.territory_rules(agency_id,territory_id,dimension,operator,values_json,sort_order) values(v_agency_id,v_id,upper(v_rule->>'dimension'),case when upper(coalesce(v_rule->>'operator','IN')) in ('NOT_IN','EQUALS') then upper(v_rule->>'operator') else 'IN' end,coalesce(v_rule->'values','[]'::jsonb),v_sort);
    end if;
  end loop;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'config.territory_saved','territory',v_id,jsonb_build_object('name',p_territory->>'name'));
  return jsonb_build_object('ok',true,'id',v_id);
end;
$function$;

revoke all on function public.xzrecruiter_onboarding_context(text) from public,authenticated;
grant execute on function public.xzrecruiter_onboarding_context(text) to anon;
revoke all on function public.xzrecruiter_save_onboarding_section(text,text,jsonb,boolean) from public,authenticated;
grant execute on function public.xzrecruiter_save_onboarding_section(text,text,jsonb,boolean) to anon;
revoke all on function public.xzrecruiter_complete_onboarding(text) from public,authenticated;
grant execute on function public.xzrecruiter_complete_onboarding(text) to anon;
revoke all on function public.xzrecruiter_save_pipeline(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_pipeline(text,jsonb) to anon;
revoke all on function public.xzrecruiter_add_custom_taxonomy(text,text,uuid,text) from public,authenticated;
grant execute on function public.xzrecruiter_add_custom_taxonomy(text,text,uuid,text) to anon;
revoke all on function public.xzrecruiter_save_custom_field(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_custom_field(text,jsonb) to anon;
revoke all on function public.xzrecruiter_save_view(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_view(text,jsonb) to anon;
revoke all on function public.xzrecruiter_save_territory(text,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_save_territory(text,jsonb) to anon;
