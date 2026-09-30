-- Step 4 closeout compatibility: agency_memberships has no active flag in the Step-1 schema.
create or replace function public.xzrecruiter_bulk_job_action(
  p_token text,p_job_ids uuid[],p_action text,p_value jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_action text:=upper(coalesce(p_action,''));v_count integer:=0;v_tag text;v_owner uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if coalesce(array_length(p_job_ids,1),0)=0 or array_length(p_job_ids,1)>100 then return jsonb_build_object('ok',false,'error','invalid_batch_size'); end if;
  if v_action='SET_STATUS' then
    if upper(coalesce(p_value->>'status','')) not in ('DRAFT','PENDING_APPROVAL','OPEN','ON_HOLD','FILLED','CLOSED','CANCELLED','ARCHIVED') then return jsonb_build_object('ok',false,'error','invalid_status'); end if;
    update public.recruitment_jobs set status=upper(p_value->>'status'),updated_at=now() where agency_id=v_agency and id=any(p_job_ids) and archived_at is null; get diagnostics v_count=row_count;
  elsif v_action='SET_PRIORITY' then
    if upper(coalesce(p_value->>'priority','')) not in ('LOW','NORMAL','HIGH','URGENT') then return jsonb_build_object('ok',false,'error','invalid_priority'); end if;
    update public.recruitment_jobs set priority=upper(p_value->>'priority'),updated_at=now() where agency_id=v_agency and id=any(p_job_ids) and archived_at is null; get diagnostics v_count=row_count;
  elsif v_action='ADD_TAG' then
    v_tag:=nullif(btrim(p_value->>'tag'),''); if v_tag is null then return jsonb_build_object('ok',false,'error','tag_required'); end if;
    update public.recruitment_jobs j set tags=case when exists(select 1 from jsonb_array_elements_text(coalesce(j.tags,'[]'::jsonb)) t where lower(t)=lower(v_tag)) then j.tags else coalesce(j.tags,'[]'::jsonb)||to_jsonb(v_tag) end,updated_at=now()
      where j.agency_id=v_agency and j.id=any(p_job_ids) and j.archived_at is null; get diagnostics v_count=row_count;
  elsif v_action='ASSIGN_OWNER' then
    v_owner:=nullif(p_value->>'ownerUserId','')::uuid;
    if v_owner is not null and not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_owner) then return jsonb_build_object('ok',false,'error','invalid_owner'); end if;
    update public.recruitment_jobs set owner_user_id=v_owner,updated_at=now() where agency_id=v_agency and id=any(p_job_ids) and archived_at is null; get diagnostics v_count=row_count;
  elsif v_action='ARCHIVE' then
    update public.recruitment_jobs set archived_at=now(),archived_by_user_id=v_user,status='ARCHIVED',updated_at=now() where agency_id=v_agency and id=any(p_job_ids) and archived_at is null; get diagnostics v_count=row_count;
  else return jsonb_build_object('ok',false,'error','unsupported_bulk_action'); end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'job',p_job_ids[1],'job.bulk_action','Bulk job action',jsonb_build_object('action',v_action,'updated',v_count));
  return jsonb_build_object('ok',true,'updated',v_count,'action',v_action);
end;$fn$;

grant execute on function public.xzrecruiter_bulk_job_action(text,uuid[],text,jsonb) to anon,authenticated;
