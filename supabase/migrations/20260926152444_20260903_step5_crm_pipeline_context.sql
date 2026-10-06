-- Step 5 business-development pipeline context. Bounded and session scoped.
create or replace function public.xzrecruiter_business_pipeline_context(p_token text,p_limit integer default 500)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_pipeline uuid;v_limit integer:=least(greatest(coalesce(p_limit,500),1),500);
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 perform private.xzrecruiter_ensure_default_pipelines(v_agency,v_user);
 select id into v_pipeline from public.recruitment_pipelines where agency_id=v_agency and pipeline_kind='BUSINESS_DEVELOPMENT' and is_default=true and active=true limit 1;
 return jsonb_build_object(
   'ok',true,'pipeline_id',v_pipeline,
   'stages',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'code',s.code,'name',s.name,'semantic',s.status_semantic,'category',s.stage_category,'sort_order',s.sort_order) order by s.sort_order) from public.pipeline_stages s where s.agency_id=v_agency and s.pipeline_id=v_pipeline),'[]'::jsonb),
   'opportunities',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (
      select o.id,o.client_id,o.primary_contact_id,o.stage_id,o.name,o.status,o.opportunity_type,o.estimated_roles,o.estimated_value,o.currency_code,o.probability,round(coalesce(o.estimated_value,0)*o.probability/100.0,2) weighted_value,o.expected_close_date,o.next_action,o.next_action_at,o.owner_user_id,o.updated_at,c.name client_name,rc.full_name contact_name,u.display_name owner_name
      from public.crm_opportunities o join public.recruitment_clients c on c.id=o.client_id and c.agency_id=v_agency left join public.recruitment_contacts rc on rc.id=o.primary_contact_id and rc.agency_id=v_agency left join public.users u on u.id=o.owner_user_id
      where o.agency_id=v_agency and o.pipeline_id=v_pipeline and o.archived_at is null and c.archived_at is null
      order by o.updated_at desc limit v_limit
   )x),'[]'::jsonb),
   'summary',jsonb_build_object(
     'total',(select count(*) from public.crm_opportunities where agency_id=v_agency and pipeline_id=v_pipeline and archived_at is null),
     'open_value',(select coalesce(sum(estimated_value),0) from public.crm_opportunities where agency_id=v_agency and pipeline_id=v_pipeline and archived_at is null and status='OPEN'),
     'weighted_value',(select coalesce(sum(estimated_value*probability/100.0),0) from public.crm_opportunities where agency_id=v_agency and pipeline_id=v_pipeline and archived_at is null and status='OPEN'),
     'won_value',(select coalesce(sum(estimated_value),0) from public.crm_opportunities where agency_id=v_agency and pipeline_id=v_pipeline and archived_at is null and status='WON')
   )
 );
end;$fn$;
grant execute on function public.xzrecruiter_business_pipeline_context(text,integer) to anon,authenticated;
