-- Step 4 closeout: client submissions default to the candidate's current primary resume when no explicit document list is supplied.
create or replace function public.xzrecruiter_save_candidate_submission(
  p_token text,p_application_id uuid,p_submission jsonb,p_submit boolean default false
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_candidate uuid;v_job uuid;v_client uuid;v_id uuid;v_status text;v_documents jsonb;v_primary uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select candidate_id,job_id,client_id into v_candidate,v_job,v_client from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  v_documents:=coalesce(p_submission->'documentIds','[]'::jsonb);
  if jsonb_typeof(v_documents)<>'array' then return jsonb_build_object('ok',false,'error','invalid_document_ids'); end if;
  if jsonb_array_length(v_documents)=0 then
    select id into v_primary from public.candidate_documents where agency_id=v_agency and candidate_id=v_candidate and document_type='RESUME' and archived_at is null and is_primary=true order by version_number desc limit 1;
    if v_primary is not null then v_documents:=jsonb_build_array(v_primary); end if;
  end if;
  if exists(
    select 1 from jsonb_array_elements_text(v_documents) d
    where not exists(select 1 from public.candidate_documents cd where cd.id=d.value::uuid and cd.agency_id=v_agency and cd.candidate_id=v_candidate and cd.archived_at is null)
  ) then return jsonb_build_object('ok',false,'error','invalid_submission_document'); end if;
  select id into v_id from public.candidate_submissions where agency_id=v_agency and application_id=p_application_id and status='DRAFT' order by created_at desc limit 1;
  v_status:=case when p_submit then 'SUBMITTED' else 'DRAFT' end;
  if v_id is null then
    v_id:=gen_random_uuid();
    insert into public.candidate_submissions(id,agency_id,application_id,candidate_id,job_id,client_id,summary,salary_expectation,salary_currency,availability,notice_period_days,document_ids,status,created_by_user_id,submitted_at)
    values(v_id,v_agency,p_application_id,v_candidate,v_job,v_client,nullif(p_submission->>'summary',''),nullif(p_submission->>'salaryExpectation','')::numeric,
      nullif(upper(p_submission->>'salaryCurrency'),''),nullif(p_submission->>'availability',''),nullif(p_submission->>'noticePeriodDays','')::integer,
      v_documents,v_status,v_user,case when p_submit then now() else null end);
  else
    update public.candidate_submissions set summary=nullif(p_submission->>'summary',''),salary_expectation=nullif(p_submission->>'salaryExpectation','')::numeric,
      salary_currency=nullif(upper(p_submission->>'salaryCurrency'),''),availability=nullif(p_submission->>'availability',''),notice_period_days=nullif(p_submission->>'noticePeriodDays','')::integer,
      document_ids=v_documents,status=v_status,submitted_at=case when p_submit then coalesce(submitted_at,now()) else submitted_at end,updated_at=now()
    where id=v_id and agency_id=v_agency;
  end if;
  if p_submit then update public.applications set submitted_at=coalesce(submitted_at,now()),last_activity_at=now(),updated_at=now() where id=p_application_id and agency_id=v_agency; end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',p_application_id,case when p_submit then 'candidate.submitted' else 'candidate.submission_saved' end,
    case when p_submit then 'Candidate submitted to client' else 'Candidate submission draft saved' end,jsonb_build_object('submission_id',v_id,'document_count',jsonb_array_length(v_documents)));
  return jsonb_build_object('ok',true,'id',v_id,'status',v_status,'document_ids',v_documents);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'error','invalid_submission_document');
end;$fn$;

grant execute on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) to anon,authenticated;
