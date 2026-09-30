-- Step 5 defense-in-depth: tenant reference integrity for all CRM writes.
-- Direct browser access is already denied; these triggers also protect security-definer RPCs from cross-workspace UUID injection.

create or replace function private.xzrecruiter_validate_crm_scope()
returns trigger language plpgsql set search_path='public','pg_temp' as $fn$
begin
  if tg_table_name='recruitment_clients' then
    if new.owner_user_id is not null and not exists(select 1 from public.agency_memberships where agency_id=new.agency_id and user_id=new.owner_user_id) then raise exception 'crm_scope_invalid_owner' using errcode='23514'; end if;
    if new.team_id is not null and not exists(select 1 from public.workspace_teams where id=new.team_id and agency_id=new.agency_id and active=true) then raise exception 'crm_scope_invalid_team' using errcode='23514'; end if;
    if new.territory_id is not null and not exists(select 1 from public.workspace_territories where id=new.territory_id and agency_id=new.agency_id and active=true) then raise exception 'crm_scope_invalid_territory' using errcode='23514'; end if;
  elsif tg_table_name='recruitment_contacts' then
    if not exists(select 1 from public.recruitment_clients where id=new.client_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_client' using errcode='23514'; end if;
    if new.owner_user_id is not null and not exists(select 1 from public.agency_memberships where agency_id=new.agency_id and user_id=new.owner_user_id) then raise exception 'crm_scope_invalid_owner' using errcode='23514'; end if;
  elsif tg_table_name='crm_opportunities' then
    if not exists(select 1 from public.recruitment_clients where id=new.client_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_client' using errcode='23514'; end if;
    if new.primary_contact_id is not null and not exists(select 1 from public.recruitment_contacts where id=new.primary_contact_id and agency_id=new.agency_id and client_id=new.client_id and archived_at is null) then raise exception 'crm_scope_invalid_contact' using errcode='23514'; end if;
    if not exists(select 1 from public.recruitment_pipelines where id=new.pipeline_id and agency_id=new.agency_id and pipeline_kind='BUSINESS_DEVELOPMENT' and active=true) then raise exception 'crm_scope_invalid_pipeline' using errcode='23514'; end if;
    if not exists(select 1 from public.pipeline_stages where id=new.stage_id and agency_id=new.agency_id and pipeline_id=new.pipeline_id) then raise exception 'crm_scope_invalid_stage' using errcode='23514'; end if;
    if new.owner_user_id is not null and not exists(select 1 from public.agency_memberships where agency_id=new.agency_id and user_id=new.owner_user_id) then raise exception 'crm_scope_invalid_owner' using errcode='23514'; end if;
    if new.team_id is not null and not exists(select 1 from public.workspace_teams where id=new.team_id and agency_id=new.agency_id and active=true) then raise exception 'crm_scope_invalid_team' using errcode='23514'; end if;
    if new.territory_id is not null and not exists(select 1 from public.workspace_territories where id=new.territory_id and agency_id=new.agency_id and active=true) then raise exception 'crm_scope_invalid_territory' using errcode='23514'; end if;
  elsif tg_table_name='crm_activities' then
    if new.client_id is not null and not exists(select 1 from public.recruitment_clients where id=new.client_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_client' using errcode='23514'; end if;
    if new.contact_id is not null and not exists(select 1 from public.recruitment_contacts where id=new.contact_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_contact' using errcode='23514'; end if;
    if new.opportunity_id is not null and not exists(select 1 from public.crm_opportunities where id=new.opportunity_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_opportunity' using errcode='23514'; end if;
  elsif tg_table_name='crm_tasks' then
    if new.assigned_user_id is not null and not exists(select 1 from public.agency_memberships where agency_id=new.agency_id and user_id=new.assigned_user_id) then raise exception 'crm_scope_invalid_assignee' using errcode='23514'; end if;
    if new.client_id is not null and not exists(select 1 from public.recruitment_clients where id=new.client_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_client' using errcode='23514'; end if;
    if new.contact_id is not null and not exists(select 1 from public.recruitment_contacts where id=new.contact_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_contact' using errcode='23514'; end if;
    if new.opportunity_id is not null and not exists(select 1 from public.crm_opportunities where id=new.opportunity_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_opportunity' using errcode='23514'; end if;
  elsif tg_table_name='recruitment_client_contracts' then
    if not exists(select 1 from public.recruitment_clients where id=new.client_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_client' using errcode='23514'; end if;
  elsif tg_table_name='recruitment_vendors' then
    if new.owner_user_id is not null and not exists(select 1 from public.agency_memberships where agency_id=new.agency_id and user_id=new.owner_user_id) then raise exception 'crm_scope_invalid_owner' using errcode='23514'; end if;
  elsif tg_table_name='vendor_job_access' then
    if not exists(select 1 from public.recruitment_vendors where id=new.vendor_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_vendor' using errcode='23514'; end if;
    if not exists(select 1 from public.recruitment_jobs where id=new.job_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_job' using errcode='23514'; end if;
  elsif tg_table_name='vendor_candidate_submissions' then
    if not exists(select 1 from public.recruitment_vendors where id=new.vendor_id and agency_id=new.agency_id and archived_at is null) then raise exception 'crm_scope_invalid_vendor' using errcode='23514'; end if;
    if not exists(select 1 from public.vendor_job_access where agency_id=new.agency_id and vendor_id=new.vendor_id and job_id=new.job_id and active=true) then raise exception 'crm_scope_job_not_shared' using errcode='23514'; end if;
  end if;
  return new;
end;$fn$;
revoke all on function private.xzrecruiter_validate_crm_scope() from public,anon,authenticated;

do $do$
declare t text;
begin
 foreach t in array array['recruitment_clients','recruitment_contacts','crm_opportunities','crm_activities','crm_tasks','recruitment_client_contracts','recruitment_vendors','vendor_job_access','vendor_candidate_submissions'] loop
   execute format('drop trigger if exists xzrecruiter_crm_scope_guard on public.%I',t);
   execute format('create trigger xzrecruiter_crm_scope_guard before insert or update on public.%I for each row execute function private.xzrecruiter_validate_crm_scope()',t);
 end loop;
end $do$;

-- Validate opportunity owner early so the API returns a business error instead of a trigger exception.
create or replace function public.xzrecruiter_validate_opportunity_owner(p_token text,p_owner_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if p_owner_id is null or exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=p_owner_id) then return jsonb_build_object('ok',true); end if;
 return jsonb_build_object('ok',false,'error','invalid_owner');
end;$fn$;
grant execute on function public.xzrecruiter_validate_opportunity_owner(text,uuid) to anon,authenticated;
