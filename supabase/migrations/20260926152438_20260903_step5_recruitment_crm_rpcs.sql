-- XZRecruiter Step 5: session-aware CRM RPC boundary.
-- All workspace ownership is derived from the verified application session.

-- Extend the Step-4 generic private attachment/note ownership helper for CRM entities.
create or replace function private.xzrecruiter_entity_belongs_to_agency(p_agency uuid,p_entity_type text,p_entity_id uuid)
returns boolean language plpgsql stable security definer set search_path='public','pg_temp' as $fn$
declare v_type text:=upper(coalesce(p_entity_type,''));
begin
  if v_type='CANDIDATE' then return exists(select 1 from public.candidates where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='JOB' then return exists(select 1 from public.recruitment_jobs where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='APPLICATION' then return exists(select 1 from public.applications where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='INTERVIEW' then return exists(select 1 from public.interviews where id=p_entity_id and agency_id=p_agency);
  elsif v_type='OFFER' then return exists(select 1 from public.offers where id=p_entity_id and agency_id=p_agency);
  elsif v_type='PLACEMENT' then return exists(select 1 from public.placements where id=p_entity_id and agency_id=p_agency);
  elsif v_type in ('CLIENT','ACCOUNT') then return exists(select 1 from public.recruitment_clients where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='CONTACT' then return exists(select 1 from public.recruitment_contacts where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='OPPORTUNITY' then return exists(select 1 from public.crm_opportunities where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='CRM_TASK' then return exists(select 1 from public.crm_tasks where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='CONTRACT' then return exists(select 1 from public.recruitment_client_contracts where id=p_entity_id and agency_id=p_agency and archived_at is null);
  end if;
  return false;
end;$fn$;
revoke all on function private.xzrecruiter_entity_belongs_to_agency(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_crm_reference_context(p_token text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_pipeline uuid;v_summary jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  perform private.xzrecruiter_ensure_default_pipelines(v_agency,v_user);
  select id into v_pipeline from public.recruitment_pipelines where agency_id=v_agency and pipeline_kind='BUSINESS_DEVELOPMENT' and is_default=true and active=true limit 1;
  select jsonb_build_object(
    'accounts',count(*) filter(where archived_at is null),
    'active_clients',count(*) filter(where archived_at is null and status='ACTIVE'),
    'prospects',count(*) filter(where archived_at is null and status in ('PROSPECT','QUALIFIED','NURTURE'))
  ) into v_summary from public.recruitment_clients where agency_id=v_agency;
  v_summary:=coalesce(v_summary,'{}'::jsonb)||jsonb_build_object(
    'open_opportunities',(select count(*) from public.crm_opportunities where agency_id=v_agency and archived_at is null and status='OPEN'),
    'pipeline_value',(select coalesce(sum(estimated_value),0) from public.crm_opportunities where agency_id=v_agency and archived_at is null and status='OPEN'),
    'weighted_pipeline',(select coalesce(sum(estimated_value*probability/100.0),0) from public.crm_opportunities where agency_id=v_agency and archived_at is null and status='OPEN'),
    'placement_fees',(select coalesce(sum(placement_fee),0) from public.placements where agency_id=v_agency and status not in ('CANCELLED')),
    'tasks_due',(select count(*) from public.crm_tasks where agency_id=v_agency and archived_at is null and status in ('OPEN','IN_PROGRESS') and due_at is not null and due_at<=now()+interval '24 hours')
  );
  return jsonb_build_object(
    'ok',true,'role',v_role,'current_user_id',v_user,'summary',v_summary,
    'members',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(u.display_name,u.email),'email',u.email,'role',am.role) order by coalesce(u.display_name,u.email)) from public.agency_memberships am join public.users u on u.id=am.user_id where am.agency_id=v_agency),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name) order by t.name) from public.workspace_teams t where t.agency_id=v_agency and t.active=true),'[]'::jsonb),
    'territories',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'parent_id',t.parent_id) order by t.name) from public.workspace_territories t where t.agency_id=v_agency and t.active=true),'[]'::jsonb),
    'bd_pipeline',coalesce((select jsonb_build_object('id',p.id,'name',p.name,'stages',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'code',s.code,'name',s.name,'category',s.stage_category,'semantic',s.status_semantic,'sort_order',s.sort_order) order by s.sort_order) from public.pipeline_stages s where s.pipeline_id=p.id and s.agency_id=v_agency),'[]'::jsonb)) from public.recruitment_pipelines p where p.id=v_pipeline),'{}'::jsonb),
    'custom_fields',coalesce((select jsonb_agg(to_jsonb(f) order by f.module,f.sort_order,f.label) from public.custom_field_definitions f where f.agency_id=v_agency and f.active=true and f.module in ('CLIENT','CONTACT','OPPORTUNITY')),'[]'::jsonb)
  );
end;$fn$;

create or replace function public.xzrecruiter_crm_search(p_token text,p_module text,p_query text default '',p_filters jsonb default '{}'::jsonb,p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_module text:=upper(coalesce(p_module,''));v_q text:='%'||lower(btrim(coalesce(p_query,'')))||'%';v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);v_offset integer:=greatest(coalesce(p_offset,0),0);v_rows jsonb:='[]'::jsonb;v_total bigint:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_module='CLIENT' then
    select count(*) into v_total from public.recruitment_clients c where c.agency_id=v_agency and c.archived_at is null
      and (btrim(coalesce(p_query,''))='' or lower(c.name) like v_q or lower(coalesce(c.domain,'')) like v_q or lower(coalesce(c.industry,'')) like v_q or lower(coalesce(c.city,'')) like v_q)
      and (coalesce(p_filters->>'status','')='' or c.status=upper(p_filters->>'status'))
      and (coalesce(p_filters->>'countryCode','')='' or c.country_code=upper(p_filters->>'countryCode'))
      and (coalesce(p_filters->>'health','')='' or c.health_status=upper(p_filters->>'health'))
      and (coalesce(p_filters->>'ownerId','')='' or c.owner_user_id=(p_filters->>'ownerId')::uuid);
    select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
      select c.id,c.name,c.legal_name,c.domain,c.website,c.industry,c.status,c.lifecycle_stage,c.health_status,c.priority,c.country_code,c.region,c.city,c.timezone,c.currency_code,c.owner_user_id,c.team_id,c.territory_id,c.last_activity_at,c.next_action,c.next_action_at,c.tags,c.updated_at,
        u.display_name owner_name,
        (select count(*) from public.recruitment_contacts rc where rc.agency_id=v_agency and rc.client_id=c.id and rc.archived_at is null) contact_count,
        (select count(*) from public.recruitment_jobs j where j.agency_id=v_agency and j.client_id=c.id and j.archived_at is null and j.status='OPEN') open_jobs,
        (select count(*) from public.crm_opportunities o where o.agency_id=v_agency and o.client_id=c.id and o.archived_at is null and o.status='OPEN') open_opportunities,
        (select coalesce(sum(p.placement_fee),0) from public.placements p where p.agency_id=v_agency and p.client_id=c.id and p.status<>'CANCELLED') placement_fees
      from public.recruitment_clients c left join public.users u on u.id=c.owner_user_id
      where c.agency_id=v_agency and c.archived_at is null
        and (btrim(coalesce(p_query,''))='' or lower(c.name) like v_q or lower(coalesce(c.domain,'')) like v_q or lower(coalesce(c.industry,'')) like v_q or lower(coalesce(c.city,'')) like v_q)
        and (coalesce(p_filters->>'status','')='' or c.status=upper(p_filters->>'status'))
        and (coalesce(p_filters->>'countryCode','')='' or c.country_code=upper(p_filters->>'countryCode'))
        and (coalesce(p_filters->>'health','')='' or c.health_status=upper(p_filters->>'health'))
        and (coalesce(p_filters->>'ownerId','')='' or c.owner_user_id=(p_filters->>'ownerId')::uuid)
      order by c.updated_at desc limit v_limit offset v_offset
    ) x;
  elsif v_module='CONTACT' then
    select count(*) into v_total from public.recruitment_contacts c join public.recruitment_clients a on a.id=c.client_id and a.agency_id=v_agency where c.agency_id=v_agency and c.archived_at is null and a.archived_at is null
      and (btrim(coalesce(p_query,''))='' or lower(c.full_name) like v_q or lower(coalesce(c.email,'')) like v_q or lower(coalesce(c.title,'')) like v_q or lower(a.name) like v_q)
      and (coalesce(p_filters->>'clientId','')='' or c.client_id=(p_filters->>'clientId')::uuid)
      and (coalesce(p_filters->>'roleType','')='' or c.role_type=upper(p_filters->>'roleType'))
      and (coalesce(p_filters->>'status','')='' or c.status=upper(p_filters->>'status'));
    select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
      select c.id,c.client_id,c.full_name,c.title,c.department,c.email,c.phone,c.role_type,c.status,c.influence_level,c.decision_authority,c.preferred_channel,c.linkedin_url,c.country_code,c.timezone,c.owner_user_id,c.tags,c.last_contacted_at,c.next_followup_at,c.updated_at,a.name client_name,u.display_name owner_name
      from public.recruitment_contacts c join public.recruitment_clients a on a.id=c.client_id and a.agency_id=v_agency left join public.users u on u.id=c.owner_user_id
      where c.agency_id=v_agency and c.archived_at is null and a.archived_at is null
        and (btrim(coalesce(p_query,''))='' or lower(c.full_name) like v_q or lower(coalesce(c.email,'')) like v_q or lower(coalesce(c.title,'')) like v_q or lower(a.name) like v_q)
        and (coalesce(p_filters->>'clientId','')='' or c.client_id=(p_filters->>'clientId')::uuid)
        and (coalesce(p_filters->>'roleType','')='' or c.role_type=upper(p_filters->>'roleType'))
        and (coalesce(p_filters->>'status','')='' or c.status=upper(p_filters->>'status'))
      order by c.updated_at desc limit v_limit offset v_offset
    ) x;
  elsif v_module='OPPORTUNITY' then
    select count(*) into v_total from public.crm_opportunities o join public.recruitment_clients c on c.id=o.client_id and c.agency_id=v_agency where o.agency_id=v_agency and o.archived_at is null and c.archived_at is null
      and (btrim(coalesce(p_query,''))='' or lower(o.name) like v_q or lower(c.name) like v_q)
      and (coalesce(p_filters->>'status','')='' or o.status=upper(p_filters->>'status'))
      and (coalesce(p_filters->>'stageId','')='' or o.stage_id=(p_filters->>'stageId')::uuid)
      and (coalesce(p_filters->>'ownerId','')='' or o.owner_user_id=(p_filters->>'ownerId')::uuid);
    select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
      select o.id,o.client_id,o.primary_contact_id,o.pipeline_id,o.stage_id,o.name,o.status,o.opportunity_type,o.estimated_roles,o.estimated_value,o.currency_code,o.probability,round(coalesce(o.estimated_value,0)*o.probability/100.0,2) weighted_value,o.expected_close_date,o.source,o.owner_user_id,o.next_action,o.next_action_at,o.lost_reason,o.last_activity_at,o.tags,o.updated_at,c.name client_name,rc.full_name primary_contact_name,s.name stage_name,s.code stage_code,s.status_semantic,u.display_name owner_name
      from public.crm_opportunities o join public.recruitment_clients c on c.id=o.client_id and c.agency_id=v_agency join public.pipeline_stages s on s.id=o.stage_id and s.agency_id=v_agency left join public.recruitment_contacts rc on rc.id=o.primary_contact_id and rc.agency_id=v_agency left join public.users u on u.id=o.owner_user_id
      where o.agency_id=v_agency and o.archived_at is null and c.archived_at is null
        and (btrim(coalesce(p_query,''))='' or lower(o.name) like v_q or lower(c.name) like v_q)
        and (coalesce(p_filters->>'status','')='' or o.status=upper(p_filters->>'status'))
        and (coalesce(p_filters->>'stageId','')='' or o.stage_id=(p_filters->>'stageId')::uuid)
        and (coalesce(p_filters->>'ownerId','')='' or o.owner_user_id=(p_filters->>'ownerId')::uuid)
      order by o.updated_at desc limit v_limit offset v_offset
    ) x;
  elsif v_module='TASK' then
    select count(*) into v_total from public.crm_tasks t where t.agency_id=v_agency and t.archived_at is null
      and (btrim(coalesce(p_query,''))='' or lower(t.title) like v_q or lower(coalesce(t.description,'')) like v_q)
      and (coalesce(p_filters->>'status','')='' or t.status=upper(p_filters->>'status'))
      and (coalesce(p_filters->>'priority','')='' or t.priority=upper(p_filters->>'priority'))
      and (coalesce(p_filters->>'assignedUserId','')='' or t.assigned_user_id=(p_filters->>'assignedUserId')::uuid)
      and (coalesce(p_filters->>'due','')<>'OVERDUE' or (t.status in ('OPEN','IN_PROGRESS') and t.due_at<now()));
    select coalesce(jsonb_agg(to_jsonb(x) order by x.due_at nulls last,x.created_at desc),'[]'::jsonb) into v_rows from (
      select t.id,t.title,t.description,t.status,t.priority,t.due_at,t.assigned_user_id,t.client_id,t.contact_id,t.opportunity_id,t.completed_at,t.updated_at,u.display_name assigned_name,c.name client_name,rc.full_name contact_name,o.name opportunity_name
      from public.crm_tasks t left join public.users u on u.id=t.assigned_user_id left join public.recruitment_clients c on c.id=t.client_id and c.agency_id=v_agency left join public.recruitment_contacts rc on rc.id=t.contact_id and rc.agency_id=v_agency left join public.crm_opportunities o on o.id=t.opportunity_id and o.agency_id=v_agency
      where t.agency_id=v_agency and t.archived_at is null
        and (btrim(coalesce(p_query,''))='' or lower(t.title) like v_q or lower(coalesce(t.description,'')) like v_q)
        and (coalesce(p_filters->>'status','')='' or t.status=upper(p_filters->>'status'))
        and (coalesce(p_filters->>'priority','')='' or t.priority=upper(p_filters->>'priority'))
        and (coalesce(p_filters->>'assignedUserId','')='' or t.assigned_user_id=(p_filters->>'assignedUserId')::uuid)
        and (coalesce(p_filters->>'due','')<>'OVERDUE' or (t.status in ('OPEN','IN_PROGRESS') and t.due_at<now()))
      order by t.due_at nulls last,t.created_at desc limit v_limit offset v_offset
    ) x;
  else return jsonb_build_object('ok',false,'error','invalid_module'); end if;
  return jsonb_build_object('ok',true,'module',v_module,'rows',v_rows,'total',v_total,'limit',v_limit,'offset',v_offset,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_save_client(p_token text,p_client jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_name text;v_country text;v_timezone text;v_currency text;v_status text;v_owner uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_name:=btrim(coalesce(p_client->>'name','')); if v_name='' then return jsonb_build_object('ok',false,'error','name_required'); end if;
  v_country:=nullif(upper(btrim(coalesce(p_client->>'countryCode',''))),'');
  v_timezone:=nullif(btrim(coalesce(p_client->>'timezone','')),'');
  v_currency:=nullif(upper(btrim(coalesce(p_client->>'currencyCode',''))),'');
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then return jsonb_build_object('ok',false,'error','invalid_country'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  if v_currency is not null and v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency'); end if;
  v_status:=upper(coalesce(nullif(p_client->>'status',''),'PROSPECT'));
  if v_status not in ('PROSPECT','QUALIFIED','ACTIVE','NURTURE','INACTIVE','LOST') then return jsonb_build_object('ok',false,'error','invalid_status'); end if;
  v_owner:=nullif(p_client->>'ownerUserId','')::uuid;
  if v_owner is not null and not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_owner) then return jsonb_build_object('ok',false,'error','invalid_owner'); end if;
  if nullif(p_client->>'id','') is null then
    if exists(select 1 from public.recruitment_clients where agency_id=v_agency and lower(name)=lower(v_name) and archived_at is null) then return jsonb_build_object('ok',false,'error','account_exists'); end if;
    v_id:=gen_random_uuid();
    insert into public.recruitment_clients(id,agency_id,name,website,industry,status,owner_user_id,created_by_user_id,country_code,locale,timezone,currency_code,legal_name,domain,email,phone,address_line1,address_line2,city,region,postal_code,employee_size_min,employee_size_max,company_type,lifecycle_stage,health_status,source,source_detail,priority,tags,team_id,territory_id,next_action,next_action_at,client_since,company_id)
    values(v_id,v_agency,v_name,nullif(p_client->>'website',''),nullif(p_client->>'industry',''),v_status,coalesce(v_owner,v_user),v_user,v_country,nullif(p_client->>'locale',''),v_timezone,v_currency,nullif(p_client->>'legalName',''),nullif(p_client->>'domain',''),nullif(lower(p_client->>'email'),''),nullif(p_client->>'phone',''),nullif(p_client->>'addressLine1',''),nullif(p_client->>'addressLine2',''),nullif(p_client->>'city',''),nullif(p_client->>'region',''),nullif(p_client->>'postalCode',''),nullif(p_client->>'employeeSizeMin','')::integer,nullif(p_client->>'employeeSizeMax','')::integer,nullif(p_client->>'companyType',''),coalesce(nullif(upper(p_client->>'lifecycleStage'),''),case when v_status='ACTIVE' then 'CLIENT' else 'PROSPECT' end),coalesce(nullif(upper(p_client->>'healthStatus'),''),'UNASSESSED'),nullif(p_client->>'source',''),nullif(p_client->>'sourceDetail',''),coalesce(nullif(upper(p_client->>'priority'),''),'NORMAL'),coalesce(p_client->'tags','[]'::jsonb),nullif(p_client->>'teamId','')::uuid,nullif(p_client->>'territoryId','')::uuid,nullif(p_client->>'nextAction',''),nullif(p_client->>'nextActionAt','')::timestamptz,case when v_status='ACTIVE' then coalesce(nullif(p_client->>'clientSince','')::date,current_date) else nullif(p_client->>'clientSince','')::date end,nullif(p_client->>'companyId','')::uuid);
    perform private.xzrecruiter_log_activity(v_agency,v_user,'client',v_id,'client.created','Account created',jsonb_build_object('status',v_status));
  else
    v_id:=(p_client->>'id')::uuid;
    update public.recruitment_clients set name=v_name,website=nullif(p_client->>'website',''),industry=nullif(p_client->>'industry',''),status=v_status,owner_user_id=coalesce(v_owner,owner_user_id),country_code=v_country,locale=nullif(p_client->>'locale',''),timezone=v_timezone,currency_code=v_currency,legal_name=nullif(p_client->>'legalName',''),domain=nullif(p_client->>'domain',''),email=nullif(lower(p_client->>'email'),''),phone=nullif(p_client->>'phone',''),address_line1=nullif(p_client->>'addressLine1',''),address_line2=nullif(p_client->>'addressLine2',''),city=nullif(p_client->>'city',''),region=nullif(p_client->>'region',''),postal_code=nullif(p_client->>'postalCode',''),employee_size_min=nullif(p_client->>'employeeSizeMin','')::integer,employee_size_max=nullif(p_client->>'employeeSizeMax','')::integer,company_type=nullif(p_client->>'companyType',''),lifecycle_stage=coalesce(nullif(upper(p_client->>'lifecycleStage'),''),lifecycle_stage),health_status=coalesce(nullif(upper(p_client->>'healthStatus'),''),health_status),source=nullif(p_client->>'source',''),source_detail=nullif(p_client->>'sourceDetail',''),priority=coalesce(nullif(upper(p_client->>'priority'),''),priority),tags=coalesce(p_client->'tags',tags),team_id=nullif(p_client->>'teamId','')::uuid,territory_id=nullif(p_client->>'territoryId','')::uuid,next_action=nullif(p_client->>'nextAction',''),next_action_at=nullif(p_client->>'nextActionAt','')::timestamptz,client_since=case when v_status='ACTIVE' then coalesce(client_since,nullif(p_client->>'clientSince','')::date,current_date) else client_since end,company_id=nullif(p_client->>'companyId','')::uuid,updated_at=now() where id=v_id and agency_id=v_agency and archived_at is null;
    if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'client',v_id,'client.updated','Account updated',jsonb_build_object('status',v_status));
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
exception when unique_violation then return jsonb_build_object('ok',false,'error','account_exists'); end;$fn$;

create or replace function public.xzrecruiter_save_contact(p_token text,p_contact jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_client uuid;v_name text;v_email text;v_timezone text;v_owner uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  v_client:=nullif(p_contact->>'clientId','')::uuid;v_name:=btrim(coalesce(p_contact->>'fullName',''));v_email:=nullif(lower(btrim(coalesce(p_contact->>'email',''))),'');v_timezone:=nullif(p_contact->>'timezone','');v_owner:=nullif(p_contact->>'ownerUserId','')::uuid;
  if v_name='' then return jsonb_build_object('ok',false,'error','name_required'); end if;
  if not exists(select 1 from public.recruitment_clients where id=v_client and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','client_not_found'); end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  if v_owner is not null and not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_owner) then return jsonb_build_object('ok',false,'error','invalid_owner'); end if;
  if nullif(p_contact->>'id','') is null then
    if v_email is not null and exists(select 1 from public.recruitment_contacts where agency_id=v_agency and client_id=v_client and lower(email)=v_email and archived_at is null) then return jsonb_build_object('ok',false,'error','contact_exists'); end if;
    v_id:=gen_random_uuid();insert into public.recruitment_contacts(id,agency_id,client_id,full_name,title,email,phone,department,role_type,status,influence_level,decision_authority,preferred_channel,linkedin_url,country_code,timezone,language_code,owner_user_id,tags,next_followup_at)
    values(v_id,v_agency,v_client,v_name,nullif(p_contact->>'title',''),v_email,nullif(p_contact->>'phone',''),nullif(p_contact->>'department',''),coalesce(nullif(upper(p_contact->>'roleType'),''),'OTHER'),coalesce(nullif(upper(p_contact->>'status'),''),'ACTIVE'),coalesce(nullif(upper(p_contact->>'influenceLevel'),''),'UNKNOWN'),coalesce(nullif(upper(p_contact->>'decisionAuthority'),''),'UNKNOWN'),nullif(upper(p_contact->>'preferredChannel'),''),nullif(p_contact->>'linkedinUrl',''),nullif(upper(p_contact->>'countryCode'),''),v_timezone,nullif(lower(p_contact->>'languageCode'),''),coalesce(v_owner,v_user),coalesce(p_contact->'tags','[]'::jsonb),nullif(p_contact->>'nextFollowupAt','')::timestamptz);
    perform private.xzrecruiter_log_activity(v_agency,v_user,'contact',v_id,'contact.created','Contact created',jsonb_build_object('client_id',v_client));
  else
    v_id:=(p_contact->>'id')::uuid;update public.recruitment_contacts set client_id=v_client,full_name=v_name,title=nullif(p_contact->>'title',''),email=v_email,phone=nullif(p_contact->>'phone',''),department=nullif(p_contact->>'department',''),role_type=coalesce(nullif(upper(p_contact->>'roleType'),''),role_type),status=coalesce(nullif(upper(p_contact->>'status'),''),status),influence_level=coalesce(nullif(upper(p_contact->>'influenceLevel'),''),influence_level),decision_authority=coalesce(nullif(upper(p_contact->>'decisionAuthority'),''),decision_authority),preferred_channel=nullif(upper(p_contact->>'preferredChannel'),''),linkedin_url=nullif(p_contact->>'linkedinUrl',''),country_code=nullif(upper(p_contact->>'countryCode'),''),timezone=v_timezone,language_code=nullif(lower(p_contact->>'languageCode'),''),owner_user_id=coalesce(v_owner,owner_user_id),tags=coalesce(p_contact->'tags',tags),next_followup_at=nullif(p_contact->>'nextFollowupAt','')::timestamptz,updated_at=now() where id=v_id and agency_id=v_agency and archived_at is null;
    if not found then return jsonb_build_object('ok',false,'error','not_found'); end if;
    perform private.xzrecruiter_log_activity(v_agency,v_user,'contact',v_id,'contact.updated','Contact updated',jsonb_build_object('client_id',v_client));
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_save_opportunity(p_token text,p_opportunity jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_client uuid;v_contact uuid;v_pipeline uuid;v_stage uuid;v_name text;v_currency text;v_stage_name text;v_stage_code text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;
  perform private.xzrecruiter_ensure_default_pipelines(v_agency,v_user);
  v_client:=nullif(p_opportunity->>'clientId','')::uuid;v_contact:=nullif(p_opportunity->>'primaryContactId','')::uuid;v_name:=btrim(coalesce(p_opportunity->>'name',''));v_currency:=nullif(upper(p_opportunity->>'currencyCode'),'');
  if v_name='' then return jsonb_build_object('ok',false,'error','name_required');end if;if not exists(select 1 from public.recruitment_clients where id=v_client and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','client_not_found');end if;
  if v_contact is not null and not exists(select 1 from public.recruitment_contacts where id=v_contact and agency_id=v_agency and client_id=v_client and archived_at is null) then return jsonb_build_object('ok',false,'error','contact_not_found');end if;
  if v_currency is not null and v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency');end if;
  v_pipeline:=nullif(p_opportunity->>'pipelineId','')::uuid;if v_pipeline is null then select id into v_pipeline from public.recruitment_pipelines where agency_id=v_agency and pipeline_kind='BUSINESS_DEVELOPMENT' and is_default=true and active=true limit 1;end if;
  if not exists(select 1 from public.recruitment_pipelines where id=v_pipeline and agency_id=v_agency and pipeline_kind='BUSINESS_DEVELOPMENT' and active=true) then return jsonb_build_object('ok',false,'error','invalid_pipeline');end if;
  v_stage:=nullif(p_opportunity->>'stageId','')::uuid;if v_stage is null then select id into v_stage from public.pipeline_stages where agency_id=v_agency and pipeline_id=v_pipeline and code in ('LEAD','TARGET_ACCOUNT') order by case code when 'LEAD' then 0 else 1 end,sort_order limit 1;end if;
  select name,code into v_stage_name,v_stage_code from public.pipeline_stages where id=v_stage and agency_id=v_agency and pipeline_id=v_pipeline;if v_stage_name is null then return jsonb_build_object('ok',false,'error','invalid_stage');end if;
  if nullif(p_opportunity->>'id','') is null then
    v_id:=gen_random_uuid();insert into public.crm_opportunities(id,agency_id,client_id,primary_contact_id,pipeline_id,stage_id,name,status,opportunity_type,estimated_roles,estimated_value,currency_code,probability,expected_close_date,source,source_company_id,source_signal_key,owner_user_id,team_id,territory_id,next_action,next_action_at,tags,created_by_user_id)
    values(v_id,v_agency,v_client,v_contact,v_pipeline,v_stage,v_name,'OPEN',coalesce(nullif(upper(p_opportunity->>'opportunityType'),''),'NEW_BUSINESS'),nullif(p_opportunity->>'estimatedRoles','')::integer,nullif(p_opportunity->>'estimatedValue','')::numeric,v_currency,least(greatest(coalesce(nullif(p_opportunity->>'probability','')::numeric,20),0),100),nullif(p_opportunity->>'expectedCloseDate','')::date,nullif(p_opportunity->>'source',''),nullif(p_opportunity->>'sourceCompanyId','')::uuid,nullif(p_opportunity->>'sourceSignalKey',''),coalesce(nullif(p_opportunity->>'ownerUserId','')::uuid,v_user),nullif(p_opportunity->>'teamId','')::uuid,nullif(p_opportunity->>'territoryId','')::uuid,nullif(p_opportunity->>'nextAction',''),nullif(p_opportunity->>'nextActionAt','')::timestamptz,coalesce(p_opportunity->'tags','[]'::jsonb),v_user);
    insert into public.crm_opportunity_stage_history(agency_id,opportunity_id,to_stage_id,to_stage,changed_by_user_id) values(v_agency,v_id,v_stage,v_stage_name,v_user);
    perform private.xzrecruiter_log_activity(v_agency,v_user,'opportunity',v_id,'opportunity.created','Opportunity created',jsonb_build_object('client_id',v_client,'stage',v_stage_name));
  else
    v_id:=(p_opportunity->>'id')::uuid;update public.crm_opportunities set client_id=v_client,primary_contact_id=v_contact,name=v_name,opportunity_type=coalesce(nullif(upper(p_opportunity->>'opportunityType'),''),opportunity_type),estimated_roles=nullif(p_opportunity->>'estimatedRoles','')::integer,estimated_value=nullif(p_opportunity->>'estimatedValue','')::numeric,currency_code=v_currency,probability=least(greatest(coalesce(nullif(p_opportunity->>'probability','')::numeric,probability),0),100),expected_close_date=nullif(p_opportunity->>'expectedCloseDate','')::date,source=nullif(p_opportunity->>'source',''),owner_user_id=coalesce(nullif(p_opportunity->>'ownerUserId','')::uuid,owner_user_id),team_id=nullif(p_opportunity->>'teamId','')::uuid,territory_id=nullif(p_opportunity->>'territoryId','')::uuid,next_action=nullif(p_opportunity->>'nextAction',''),next_action_at=nullif(p_opportunity->>'nextActionAt','')::timestamptz,tags=coalesce(p_opportunity->'tags',tags),updated_at=now() where id=v_id and agency_id=v_agency and archived_at is null;
    if not found then return jsonb_build_object('ok',false,'error','not_found');end if;perform private.xzrecruiter_log_activity(v_agency,v_user,'opportunity',v_id,'opportunity.updated','Opportunity updated');
  end if;
  return jsonb_build_object('ok',true,'id',v_id,'stage_id',v_stage,'stage',v_stage_name);
end;$fn$;

create or replace function public.xzrecruiter_move_opportunity_stage(p_token text,p_opportunity_id uuid,p_stage_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_pipeline uuid;v_old uuid;v_old_name text;v_client uuid;v_new_name text;v_code text;v_status text:='OPEN';
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;
  select pipeline_id,stage_id,client_id into v_pipeline,v_old,v_client from public.crm_opportunities where id=p_opportunity_id and agency_id=v_agency and archived_at is null;if not found then return jsonb_build_object('ok',false,'error','not_found');end if;
  select name,code into v_new_name,v_code from public.pipeline_stages where id=p_stage_id and agency_id=v_agency and pipeline_id=v_pipeline;if not found then return jsonb_build_object('ok',false,'error','invalid_stage');end if;
  select name into v_old_name from public.pipeline_stages where id=v_old;
  if v_code in ('LOST','DISQUALIFIED') and btrim(coalesce(p_reason,''))='' then return jsonb_build_object('ok',false,'error','reason_required');end if;
  if v_code='PLACEMENT' then v_status:='WON';elsif v_code in ('LOST','DISQUALIFIED') then v_status:='LOST';elsif v_code='NURTURE' then v_status:='NURTURE';end if;
  update public.crm_opportunities set stage_id=p_stage_id,status=v_status,lost_reason=case when v_status='LOST' then p_reason else null end,won_at=case when v_status='WON' then now() else won_at end,lost_at=case when v_status='LOST' then now() else null end,updated_at=now() where id=p_opportunity_id and agency_id=v_agency;
  insert into public.crm_opportunity_stage_history(agency_id,opportunity_id,from_stage_id,to_stage_id,from_stage,to_stage,reason,changed_by_user_id) values(v_agency,p_opportunity_id,v_old,p_stage_id,v_old_name,v_new_name,p_reason,v_user);
  if v_code in ('CLIENT','REQUIREMENT','PLACEMENT') then update public.recruitment_clients set status='ACTIVE',lifecycle_stage='CLIENT',client_since=coalesce(client_since,current_date),updated_at=now() where id=v_client and agency_id=v_agency;end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'opportunity',p_opportunity_id,'opportunity.stage_changed',coalesce(v_old_name,'Unknown')||' → '||v_new_name,jsonb_build_object('reason',p_reason));
  return jsonb_build_object('ok',true,'stage_id',p_stage_id,'stage',v_new_name,'status',v_status);
end;$fn$;

create or replace function public.xzrecruiter_save_crm_activity(p_token text,p_activity jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid:=gen_random_uuid();v_client uuid;v_contact uuid;v_opp uuid;v_type text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;
  v_client:=nullif(p_activity->>'clientId','')::uuid;v_contact:=nullif(p_activity->>'contactId','')::uuid;v_opp:=nullif(p_activity->>'opportunityId','')::uuid;v_type:=upper(coalesce(nullif(p_activity->>'activityType',''),'NOTE'));
  if v_client is not null and not private.xzrecruiter_entity_belongs_to_agency(v_agency,'CLIENT',v_client) then return jsonb_build_object('ok',false,'error','client_not_found');end if;if v_contact is not null and not private.xzrecruiter_entity_belongs_to_agency(v_agency,'CONTACT',v_contact) then return jsonb_build_object('ok',false,'error','contact_not_found');end if;if v_opp is not null and not private.xzrecruiter_entity_belongs_to_agency(v_agency,'OPPORTUNITY',v_opp) then return jsonb_build_object('ok',false,'error','opportunity_not_found');end if;if v_client is null and v_contact is null and v_opp is null then return jsonb_build_object('ok',false,'error','parent_required');end if;
  insert into public.crm_activities(id,agency_id,activity_type,client_id,contact_id,opportunity_id,subject,body,direction,outcome,occurred_at,next_action,next_action_at,actor_user_id,metadata) values(v_id,v_agency,v_type,v_client,v_contact,v_opp,nullif(p_activity->>'subject',''),nullif(p_activity->>'body',''),nullif(upper(p_activity->>'direction'),''),nullif(p_activity->>'outcome',''),coalesce(nullif(p_activity->>'occurredAt','')::timestamptz,now()),nullif(p_activity->>'nextAction',''),nullif(p_activity->>'nextActionAt','')::timestamptz,v_user,coalesce(p_activity->'metadata','{}'::jsonb));
  if v_client is not null then update public.recruitment_clients set last_activity_at=now(),next_action=coalesce(nullif(p_activity->>'nextAction',''),next_action),next_action_at=coalesce(nullif(p_activity->>'nextActionAt','')::timestamptz,next_action_at),updated_at=now() where id=v_client and agency_id=v_agency;end if;
  if v_contact is not null then update public.recruitment_contacts set last_contacted_at=now(),next_followup_at=coalesce(nullif(p_activity->>'nextActionAt','')::timestamptz,next_followup_at),updated_at=now() where id=v_contact and agency_id=v_agency;end if;
  if v_opp is not null then update public.crm_opportunities set last_activity_at=now(),next_action=coalesce(nullif(p_activity->>'nextAction',''),next_action),next_action_at=coalesce(nullif(p_activity->>'nextActionAt','')::timestamptz,next_action_at),updated_at=now() where id=v_opp and agency_id=v_agency;end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,case when v_opp is not null then 'opportunity' when v_contact is not null then 'contact' else 'client' end,coalesce(v_opp,v_contact,v_client),'crm.activity','CRM activity recorded',jsonb_build_object('activity_type',v_type,'activity_id',v_id));
  return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_save_crm_task(p_token text,p_task jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_client uuid;v_contact uuid;v_opp uuid;v_assigned uuid;v_title text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;
  v_title:=btrim(coalesce(p_task->>'title',''));if v_title='' then return jsonb_build_object('ok',false,'error','title_required');end if;v_client:=nullif(p_task->>'clientId','')::uuid;v_contact:=nullif(p_task->>'contactId','')::uuid;v_opp:=nullif(p_task->>'opportunityId','')::uuid;v_assigned:=coalesce(nullif(p_task->>'assignedUserId','')::uuid,v_user);
  if not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_assigned) then return jsonb_build_object('ok',false,'error','invalid_assignee');end if;if v_client is null and v_contact is null and v_opp is null then return jsonb_build_object('ok',false,'error','parent_required');end if;
  if v_client is not null and not private.xzrecruiter_entity_belongs_to_agency(v_agency,'CLIENT',v_client) then return jsonb_build_object('ok',false,'error','client_not_found');end if;if v_contact is not null and not private.xzrecruiter_entity_belongs_to_agency(v_agency,'CONTACT',v_contact) then return jsonb_build_object('ok',false,'error','contact_not_found');end if;if v_opp is not null and not private.xzrecruiter_entity_belongs_to_agency(v_agency,'OPPORTUNITY',v_opp) then return jsonb_build_object('ok',false,'error','opportunity_not_found');end if;
  if nullif(p_task->>'id','') is null then v_id:=gen_random_uuid();insert into public.crm_tasks(id,agency_id,title,description,status,priority,due_at,assigned_user_id,client_id,contact_id,opportunity_id,created_by_user_id) values(v_id,v_agency,v_title,nullif(p_task->>'description',''),coalesce(nullif(upper(p_task->>'status'),''),'OPEN'),coalesce(nullif(upper(p_task->>'priority'),''),'NORMAL'),nullif(p_task->>'dueAt','')::timestamptz,v_assigned,v_client,v_contact,v_opp,v_user);else v_id:=(p_task->>'id')::uuid;update public.crm_tasks set title=v_title,description=nullif(p_task->>'description',''),status=coalesce(nullif(upper(p_task->>'status'),''),status),priority=coalesce(nullif(upper(p_task->>'priority'),''),priority),due_at=nullif(p_task->>'dueAt','')::timestamptz,assigned_user_id=v_assigned,client_id=v_client,contact_id=v_contact,opportunity_id=v_opp,updated_at=now() where id=v_id and agency_id=v_agency and archived_at is null;if not found then return jsonb_build_object('ok',false,'error','not_found');end if;end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'crm_task',v_id,'task.saved','CRM task saved',jsonb_build_object('assigned_user_id',v_assigned));return jsonb_build_object('ok',true,'id',v_id);
end;$fn$;

create or replace function public.xzrecruiter_set_crm_task_status(p_token text,p_task_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_status text:=upper(coalesce(p_status,''));
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;if v_status not in ('OPEN','IN_PROGRESS','DONE','CANCELLED') then return jsonb_build_object('ok',false,'error','invalid_status');end if;update public.crm_tasks set status=v_status,completed_at=case when v_status='DONE' then now() else null end,updated_at=now() where id=p_task_id and agency_id=v_agency and archived_at is null;if not found then return jsonb_build_object('ok',false,'error','not_found');end if;perform private.xzrecruiter_log_activity(v_agency,v_user,'crm_task',p_task_id,'task.status_changed','Task status changed',jsonb_build_object('status',v_status));return jsonb_build_object('ok',true,'status',v_status);end;$fn$;

create or replace function public.xzrecruiter_save_client_contract(p_token text,p_contract jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_client uuid;v_name text;
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;v_client:=nullif(p_contract->>'clientId','')::uuid;v_name:=btrim(coalesce(p_contract->>'name',''));if v_name='' then return jsonb_build_object('ok',false,'error','name_required');end if;if not private.xzrecruiter_entity_belongs_to_agency(v_agency,'CLIENT',v_client) then return jsonb_build_object('ok',false,'error','client_not_found');end if;if nullif(p_contract->>'id','') is null then v_id:=gen_random_uuid();insert into public.recruitment_client_contracts(id,agency_id,client_id,name,contract_type,status,fee_type,fee_percent,fee_amount,currency_code,payment_terms_days,guarantee_days,effective_from,effective_to,exclusivity,notes,created_by_user_id) values(v_id,v_agency,v_client,v_name,coalesce(nullif(upper(p_contract->>'contractType'),''),'CONTINGENCY'),coalesce(nullif(upper(p_contract->>'status'),''),'DRAFT'),nullif(upper(p_contract->>'feeType'),''),nullif(p_contract->>'feePercent','')::numeric,nullif(p_contract->>'feeAmount','')::numeric,nullif(upper(p_contract->>'currencyCode'),''),nullif(p_contract->>'paymentTermsDays','')::integer,nullif(p_contract->>'guaranteeDays','')::integer,nullif(p_contract->>'effectiveFrom','')::date,nullif(p_contract->>'effectiveTo','')::date,coalesce((p_contract->>'exclusivity')::boolean,false),nullif(p_contract->>'notes',''),v_user);else v_id:=(p_contract->>'id')::uuid;update public.recruitment_client_contracts set name=v_name,contract_type=coalesce(nullif(upper(p_contract->>'contractType'),''),contract_type),status=coalesce(nullif(upper(p_contract->>'status'),''),status),fee_type=nullif(upper(p_contract->>'feeType'),''),fee_percent=nullif(p_contract->>'feePercent','')::numeric,fee_amount=nullif(p_contract->>'feeAmount','')::numeric,currency_code=nullif(upper(p_contract->>'currencyCode'),''),payment_terms_days=nullif(p_contract->>'paymentTermsDays','')::integer,guarantee_days=nullif(p_contract->>'guaranteeDays','')::integer,effective_from=nullif(p_contract->>'effectiveFrom','')::date,effective_to=nullif(p_contract->>'effectiveTo','')::date,exclusivity=coalesce((p_contract->>'exclusivity')::boolean,exclusivity),notes=nullif(p_contract->>'notes',''),updated_at=now() where id=v_id and agency_id=v_agency and client_id=v_client and archived_at is null;if not found then return jsonb_build_object('ok',false,'error','not_found');end if;end if;perform private.xzrecruiter_log_activity(v_agency,v_user,'contract',v_id,'contract.saved','Client commercial terms saved',jsonb_build_object('client_id',v_client));return jsonb_build_object('ok',true,'id',v_id);end;$fn$;

create or replace function public.xzrecruiter_save_crm_custom_values(p_token text,p_entity_type text,p_entity_id uuid,p_values jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text:=upper(coalesce(p_entity_type,''));v_module text;v_item jsonb;v_field uuid;v_count integer:=0;
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;if v_type not in ('CLIENT','CONTACT','OPPORTUNITY') or not private.xzrecruiter_entity_belongs_to_agency(v_agency,v_type,p_entity_id) then return jsonb_build_object('ok',false,'error','entity_not_found');end if;v_module:=v_type;if jsonb_typeof(coalesce(p_values,'[]'::jsonb))<>'array' then return jsonb_build_object('ok',false,'error','invalid_values');end if;for v_item in select value from jsonb_array_elements(coalesce(p_values,'[]'::jsonb)) loop v_field:=nullif(v_item->>'fieldId','')::uuid;if not exists(select 1 from public.custom_field_definitions where id=v_field and agency_id=v_agency and module=v_module and active=true) then return jsonb_build_object('ok',false,'error','invalid_field');end if;insert into public.crm_custom_field_values(agency_id,entity_type,entity_id,field_id,value,updated_by_user_id) values(v_agency,v_type,p_entity_id,v_field,v_item->'value',v_user) on conflict(agency_id,entity_type,entity_id,field_id) do update set value=excluded.value,updated_by_user_id=v_user,updated_at=now();v_count:=v_count+1;end loop;return jsonb_build_object('ok',true,'saved',v_count);end;$fn$;

create or replace function public.xzrecruiter_client_360(p_token text,p_client_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_client jsonb;
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;select to_jsonb(c) into v_client from public.recruitment_clients c where c.id=p_client_id and c.agency_id=v_agency and c.archived_at is null;if v_client is null then return jsonb_build_object('ok',false,'error','not_found');end if;return jsonb_build_object('ok',true,'client',v_client,
 'contacts',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (select id,full_name,title,department,email,phone,role_type,status,influence_level,decision_authority,last_contacted_at,next_followup_at,updated_at from public.recruitment_contacts where agency_id=v_agency and client_id=p_client_id and archived_at is null order by updated_at desc limit 100)x),'[]'::jsonb),
 'jobs',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (select id,title,status,location,country_code,priority,openings,updated_at from public.recruitment_jobs where agency_id=v_agency and client_id=p_client_id and archived_at is null order by updated_at desc limit 100)x),'[]'::jsonb),
 'opportunities',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (select o.id,o.name,o.status,o.estimated_value,o.currency_code,o.probability,o.expected_close_date,o.next_action,o.updated_at,s.name stage_name,s.code stage_code from public.crm_opportunities o join public.pipeline_stages s on s.id=o.stage_id where o.agency_id=v_agency and o.client_id=p_client_id and o.archived_at is null order by o.updated_at desc limit 100)x),'[]'::jsonb),
 'placements',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select p.id,p.placement_fee,p.fee_currency,p.start_date,p.status,p.created_at,c.full_name candidate_name,j.title job_title from public.placements p left join public.candidates c on c.id=p.candidate_id left join public.recruitment_jobs j on j.id=p.job_id where p.agency_id=v_agency and p.client_id=p_client_id order by p.created_at desc limit 100)x),'[]'::jsonb),
 'contracts',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (select id,name,contract_type,status,fee_type,fee_percent,fee_amount,currency_code,payment_terms_days,guarantee_days,effective_from,effective_to,exclusivity,updated_at from public.recruitment_client_contracts where agency_id=v_agency and client_id=p_client_id and archived_at is null order by updated_at desc)x),'[]'::jsonb),
 'activities',coalesce((select jsonb_agg(to_jsonb(x) order by x.occurred_at desc) from (select a.id,a.activity_type,a.subject,a.body,a.direction,a.outcome,a.occurred_at,a.next_action,a.next_action_at,u.display_name actor_name from public.crm_activities a left join public.users u on u.id=a.actor_user_id where a.agency_id=v_agency and a.client_id=p_client_id order by a.occurred_at desc limit 100)x),'[]'::jsonb),
 'tasks',coalesce((select jsonb_agg(to_jsonb(x) order by x.due_at nulls last) from (select t.id,t.title,t.status,t.priority,t.due_at,u.display_name assigned_name from public.crm_tasks t left join public.users u on u.id=t.assigned_user_id where t.agency_id=v_agency and t.client_id=p_client_id and t.archived_at is null order by t.due_at nulls last limit 100)x),'[]'::jsonb),
 'custom_values',coalesce((select jsonb_agg(jsonb_build_object('field_id',v.field_id,'value',v.value)) from public.crm_custom_field_values v where v.agency_id=v_agency and v.entity_type='CLIENT' and v.entity_id=p_client_id),'[]'::jsonb),
 'metrics',jsonb_build_object('open_jobs',(select count(*) from public.recruitment_jobs where agency_id=v_agency and client_id=p_client_id and archived_at is null and status='OPEN'),'open_opportunities',(select count(*) from public.crm_opportunities where agency_id=v_agency and client_id=p_client_id and archived_at is null and status='OPEN'),'pipeline_value',(select coalesce(sum(estimated_value),0) from public.crm_opportunities where agency_id=v_agency and client_id=p_client_id and archived_at is null and status='OPEN'),'placement_fees',(select coalesce(sum(placement_fee),0) from public.placements where agency_id=v_agency and client_id=p_client_id and status<>'CANCELLED')));
end;$fn$;

create or replace function public.xzrecruiter_contact_360(p_token text,p_contact_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_contact jsonb;
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;select to_jsonb(c)||jsonb_build_object('client_name',a.name) into v_contact from public.recruitment_contacts c join public.recruitment_clients a on a.id=c.client_id and a.agency_id=v_agency where c.id=p_contact_id and c.agency_id=v_agency and c.archived_at is null;if v_contact is null then return jsonb_build_object('ok',false,'error','not_found');end if;return jsonb_build_object('ok',true,'contact',v_contact,'opportunities',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'status',o.status,'stage',s.name,'value',o.estimated_value,'currency',o.currency_code,'next_action',o.next_action) order by o.updated_at desc) from public.crm_opportunities o join public.pipeline_stages s on s.id=o.stage_id where o.agency_id=v_agency and o.primary_contact_id=p_contact_id and o.archived_at is null),'[]'::jsonb),'activities',coalesce((select jsonb_agg(to_jsonb(a) order by a.occurred_at desc) from public.crm_activities a where a.agency_id=v_agency and a.contact_id=p_contact_id),'[]'::jsonb),'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_at nulls last) from public.crm_tasks t where t.agency_id=v_agency and t.contact_id=p_contact_id and t.archived_at is null),'[]'::jsonb),'custom_values',coalesce((select jsonb_agg(jsonb_build_object('field_id',v.field_id,'value',v.value)) from public.crm_custom_field_values v where v.agency_id=v_agency and v.entity_type='CONTACT' and v.entity_id=p_contact_id),'[]'::jsonb));end;$fn$;

create or replace function public.xzrecruiter_opportunity_360(p_token text,p_opportunity_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_opp jsonb;
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;select to_jsonb(o)||jsonb_build_object('client_name',c.name,'contact_name',rc.full_name,'stage_name',s.name,'stage_code',s.code) into v_opp from public.crm_opportunities o join public.recruitment_clients c on c.id=o.client_id and c.agency_id=v_agency join public.pipeline_stages s on s.id=o.stage_id left join public.recruitment_contacts rc on rc.id=o.primary_contact_id where o.id=p_opportunity_id and o.agency_id=v_agency and o.archived_at is null;if v_opp is null then return jsonb_build_object('ok',false,'error','not_found');end if;return jsonb_build_object('ok',true,'opportunity',v_opp,'stage_history',coalesce((select jsonb_agg(to_jsonb(h) order by h.changed_at desc) from public.crm_opportunity_stage_history h where h.agency_id=v_agency and h.opportunity_id=p_opportunity_id),'[]'::jsonb),'activities',coalesce((select jsonb_agg(to_jsonb(a) order by a.occurred_at desc) from public.crm_activities a where a.agency_id=v_agency and a.opportunity_id=p_opportunity_id),'[]'::jsonb),'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_at nulls last) from public.crm_tasks t where t.agency_id=v_agency and t.opportunity_id=p_opportunity_id and t.archived_at is null),'[]'::jsonb),'custom_values',coalesce((select jsonb_agg(jsonb_build_object('field_id',v.field_id,'value',v.value)) from public.crm_custom_field_values v where v.agency_id=v_agency and v.entity_type='OPPORTUNITY' and v.entity_id=p_opportunity_id),'[]'::jsonb));end;$fn$;

create or replace function public.xzrecruiter_archive_crm_entity(p_token text,p_entity_type text,p_entity_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_type text:=upper(coalesce(p_entity_type,''));
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;if v_type='CLIENT' then if exists(select 1 from public.recruitment_jobs where agency_id=v_agency and client_id=p_entity_id and archived_at is null and status='OPEN') or exists(select 1 from public.crm_opportunities where agency_id=v_agency and client_id=p_entity_id and archived_at is null and status='OPEN') then return jsonb_build_object('ok',false,'error','active_dependencies');end if;update public.recruitment_clients set archived_at=now(),archived_by_user_id=v_user,updated_at=now() where id=p_entity_id and agency_id=v_agency and archived_at is null;elsif v_type='CONTACT' then update public.recruitment_contacts set archived_at=now(),archived_by_user_id=v_user,updated_at=now() where id=p_entity_id and agency_id=v_agency and archived_at is null;elsif v_type='OPPORTUNITY' then update public.crm_opportunities set archived_at=now(),status='ARCHIVED',updated_at=now() where id=p_entity_id and agency_id=v_agency and archived_at is null;else return jsonb_build_object('ok',false,'error','invalid_entity_type');end if;if not found then return jsonb_build_object('ok',false,'error','not_found');end if;perform private.xzrecruiter_log_activity(v_agency,v_user,lower(v_type),p_entity_id,'crm.archived','CRM record archived');return jsonb_build_object('ok',true);end;$fn$;

grant execute on function public.xzrecruiter_crm_reference_context(text) to anon,authenticated;
grant execute on function public.xzrecruiter_crm_search(text,text,text,jsonb,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_save_client(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_contact(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_opportunity(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_move_opportunity_stage(text,uuid,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_crm_activity(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_crm_task(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_set_crm_task_status(text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_save_client_contract(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_crm_custom_values(text,text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_client_360(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_contact_360(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_opportunity_360(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_archive_crm_entity(text,text,uuid) to anon,authenticated;
