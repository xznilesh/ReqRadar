-- Step 4 dashboard correction: recruitment metrics are workspace-owned, not global canonical-job counts.
-- Deliberately ordered after the Step-4 core/RPC migrations.
create or replace function public.xzrecruiter_dashboard(p_token text)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_jobs integer:=0;v_hot integer:=0;v_clients integer:=0;v_candidates integer:=0;v_signals jsonb:='[]'::jsonb;v_pipeline jsonb:='[]'::jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select count(*)::integer into v_jobs from public.recruitment_jobs where agency_id=v_agency and archived_at is null and status in ('OPEN','PENDING_APPROVAL','ON_HOLD');
  select count(*)::integer into v_hot from public.agency_company_hiring_heat where agency_id=v_agency and heat_score>=70;
  select count(*)::integer into v_clients from public.recruitment_clients where agency_id=v_agency and status='ACTIVE';
  select count(*)::integer into v_candidates from public.candidates where agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.heat_score desc),'[]'::jsonb) into v_signals from (
    select c.name,h.heat_score,h.recommendation,h.why_now_summary,f.fit_score from public.agency_company_hiring_heat h join public.companies c on c.id=h.company_id left join public.agency_company_fit_scores f on f.agency_id=h.agency_id and f.company_id=h.company_id where h.agency_id=v_agency order by h.heat_score desc,h.updated_at desc limit 8
  )x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order),'[]'::jsonb) into v_pipeline from (
    select coalesce(ps.name,a.stage) stage,coalesce(ps.sort_order,999) sort_order,count(*)::integer n from public.applications a left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency where a.agency_id=v_agency and a.status='ACTIVE' and a.archived_at is null group by coalesce(ps.name,a.stage),coalesce(ps.sort_order,999)
  )x;
  return jsonb_build_object('ok',true,'metrics',jsonb_build_object('companies',(select count(*) from public.agency_company_fit_scores where agency_id=v_agency),'jobs',v_jobs,'hot',v_hot,'clients',v_clients,'candidates',v_candidates),'signals',v_signals,'pipeline',v_pipeline);
end;$fn$;
grant execute on function public.xzrecruiter_dashboard(text) to anon,authenticated;
