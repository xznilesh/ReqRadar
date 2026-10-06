-- XZ Recruiter Step 4 full operational closeout.
-- Additive only; production activation remains a separate manual gate.

create or replace function public.xzrecruiter_create_talent_pool(
  p_token text,p_name text,p_description text default null
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_name text:=btrim(coalesce(p_name,''));
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_name='' or length(v_name)>120 then return jsonb_build_object('ok',false,'error','invalid_pool_name'); end if;
  insert into public.talent_pools(id,agency_id,name,description,visibility,owner_user_id,active)
  values(gen_random_uuid(),v_agency,v_name,nullif(btrim(coalesce(p_description,'')),''),'TEAM',v_user,true)
  on conflict(agency_id,name) do update set description=coalesce(excluded.description,public.talent_pools.description),active=true,updated_at=now()
  returning id into v_id;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'talent_pool',v_id,'talent_pool.saved','Talent pool saved');
  return jsonb_build_object('ok',true,'id',v_id,'name',v_name);
end;$fn$;

create or replace function public.xzrecruiter_application_closeout_context(
  p_token text,p_application_id uuid
) returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_candidate uuid;v_job uuid;v_application jsonb;v_screening jsonb;v_submission jsonb;v_activity jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select a.candidate_id,a.job_id,
    jsonb_build_object('id',a.id,'stage',a.stage,'stage_id',a.stage_id,'status',a.status,'candidate_id',a.candidate_id,'job_id',a.job_id,'client_id',a.client_id,
      'candidate_name',c.full_name,'candidate_title',c.current_title,'candidate_email',c.email,'candidate_phone',c.phone,'availability',c.availability_status,
      'notice_period_days',c.notice_period_days,'salary_expected',c.salary_expected,'salary_currency',c.salary_currency,'job_title',j.title,'job_currency',j.salary_currency,
      'job_salary_min',j.salary_min,'job_salary_max',j.salary_max)
  into v_candidate,v_job,v_application
  from public.applications a
  join public.candidates c on c.id=a.candidate_id and c.agency_id=v_agency
  join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency
  where a.id=p_application_id and a.agency_id=v_agency and a.archived_at is null;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb) into v_screening from (
    select id,question_key,question_text,answer,score,knockout,reviewed_at,created_at from public.application_screening_answers
    where agency_id=v_agency and application_id=p_application_id order by created_at
  ) x;
  select to_jsonb(x) into v_submission from (
    select id,summary,salary_expectation,salary_currency,availability,notice_period_days,document_ids,status,submitted_at,client_viewed_at,created_at,updated_at
    from public.candidate_submissions where agency_id=v_agency and application_id=p_application_id order by created_at desc limit 1
  ) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into v_activity from (
    select id,entity_type,entity_id,action,summary,metadata,actor_user_id,occurred_at from public.recruitment_activity_events
    where agency_id=v_agency and (
      (entity_type='application' and entity_id=p_application_id) or
      (entity_type='candidate' and entity_id=v_candidate) or
      (entity_type='job' and entity_id=v_job)
    ) order by occurred_at desc limit 60
  ) x;
  return jsonb_build_object('ok',true,'application',v_application,'screening',v_screening,'submission',v_submission,'activity',v_activity);
end;$fn$;

create or replace function public.xzrecruiter_save_candidate_submission(
  p_token text,p_application_id uuid,p_submission jsonb,p_submit boolean default false
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_candidate uuid;v_job uuid;v_client uuid;v_id uuid;v_status text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select candidate_id,job_id,client_id into v_candidate,v_job,v_client from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  select id into v_id from public.candidate_submissions where agency_id=v_agency and application_id=p_application_id and status='DRAFT' order by created_at desc limit 1;
  v_status:=case when p_submit then 'SUBMITTED' else 'DRAFT' end;
  if v_id is null then
    v_id:=gen_random_uuid();
    insert into public.candidate_submissions(id,agency_id,application_id,candidate_id,job_id,client_id,summary,salary_expectation,salary_currency,availability,notice_period_days,document_ids,status,created_by_user_id,submitted_at)
    values(v_id,v_agency,p_application_id,v_candidate,v_job,v_client,nullif(p_submission->>'summary',''),nullif(p_submission->>'salaryExpectation','')::numeric,
      nullif(upper(p_submission->>'salaryCurrency'),''),nullif(p_submission->>'availability',''),nullif(p_submission->>'noticePeriodDays','')::integer,
      coalesce(p_submission->'documentIds','[]'::jsonb),v_status,v_user,case when p_submit then now() else null end);
  else
    update public.candidate_submissions set summary=nullif(p_submission->>'summary',''),salary_expectation=nullif(p_submission->>'salaryExpectation','')::numeric,
      salary_currency=nullif(upper(p_submission->>'salaryCurrency'),''),availability=nullif(p_submission->>'availability',''),notice_period_days=nullif(p_submission->>'noticePeriodDays','')::integer,
      document_ids=coalesce(p_submission->'documentIds',document_ids),status=v_status,submitted_at=case when p_submit then coalesce(submitted_at,now()) else submitted_at end,updated_at=now()
    where id=v_id and agency_id=v_agency;
  end if;
  if p_submit then update public.applications set submitted_at=coalesce(submitted_at,now()),last_activity_at=now(),updated_at=now() where id=p_application_id and agency_id=v_agency; end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',p_application_id,case when p_submit then 'candidate.submitted' else 'candidate.submission_saved' end,
    case when p_submit then 'Candidate submitted to client' else 'Candidate submission draft saved' end,jsonb_build_object('submission_id',v_id));
  return jsonb_build_object('ok',true,'id',v_id,'status',v_status);
end;$fn$;

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
    if v_owner is not null and not exists(select 1 from public.agency_memberships where agency_id=v_agency and user_id=v_owner and active=true) then return jsonb_build_object('ok',false,'error','invalid_owner'); end if;
    update public.recruitment_jobs set owner_user_id=v_owner,updated_at=now() where agency_id=v_agency and id=any(p_job_ids) and archived_at is null; get diagnostics v_count=row_count;
  elsif v_action='ARCHIVE' then
    update public.recruitment_jobs set archived_at=now(),archived_by_user_id=v_user,status='ARCHIVED',updated_at=now() where agency_id=v_agency and id=any(p_job_ids) and archived_at is null; get diagnostics v_count=row_count;
  else return jsonb_build_object('ok',false,'error','unsupported_bulk_action'); end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'job',p_job_ids[1],'job.bulk_action','Bulk job action',jsonb_build_object('action',v_action,'updated',v_count));
  return jsonb_build_object('ok',true,'updated',v_count,'action',v_action);
end;$fn$;

create or replace function public.xzrecruiter_candidate_export(
  p_token text,p_candidate_ids uuid[]
) returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if coalesce(array_length(p_candidate_ids,1),0)=0 or array_length(p_candidate_ids,1)>500 then return jsonb_build_object('ok',false,'error','invalid_batch_size'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.full_name),'[]'::jsonb) into v_rows from (
    select full_name,email,phone,current_title,current_company,city,region,country_code,timezone,experience_years,availability_status,notice_period_days,salary_expected,salary_currency,workplace_preference,skills,tags,updated_at
    from public.candidates where agency_id=v_agency and id=any(p_candidate_ids) and archived_at is null and merged_into_candidate_id is null
  ) x;
  return jsonb_build_object('ok',true,'rows',v_rows);
end;$fn$;

create or replace function public.xzrecruiter_offer_closeout_context(
  p_token text,p_offer_id uuid
) returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_root uuid;v_offer jsonb;v_versions jsonb;v_approvals jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select coalesce(parent_offer_id,id),to_jsonb(o) into v_root,v_offer from public.offers o where id=p_offer_id and agency_id=v_agency;
  if v_root is null then return jsonb_build_object('ok',false,'error','offer_not_found'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.version_number desc),'[]'::jsonb) into v_versions from (
    select id,title,amount,currency,salary_period,bonus,commission,ote,equity,allowances,status,start_date,expires_at,employment_type,version_number,parent_offer_id,created_at
    from public.offers where agency_id=v_agency and (id=v_root or parent_offer_id=v_root) order by version_number desc
  ) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.step_order),'[]'::jsonb) into v_approvals from (
    select id,offer_id,step_order,approver_user_id,required_role,status,decision_note,decided_at,created_at from public.offer_approvals where agency_id=v_agency and offer_id=p_offer_id order by step_order
  ) x;
  return jsonb_build_object('ok',true,'offer',v_offer,'root_offer_id',v_root,'versions',v_versions,'approvals',v_approvals,'current_user_id',v_user,'role',v_role);
end;$fn$;

create or replace function public.xzrecruiter_offer_approval_action(
  p_token text,p_offer_id uuid,p_action text,p_note text default null
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_action text:=upper(coalesce(p_action,''));v_status text;v_approval uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select status into v_status from public.offers where id=p_offer_id and agency_id=v_agency;
  if v_status is null then return jsonb_build_object('ok',false,'error','offer_not_found'); end if;
  if v_action='REQUEST' then
    if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
    if v_status not in ('DRAFT','PENDING_APPROVAL') then return jsonb_build_object('ok',false,'error','invalid_offer_state'); end if;
    select id into v_approval from public.offer_approvals where agency_id=v_agency and offer_id=p_offer_id and step_order=1;
    if v_approval is null then
      v_approval:=gen_random_uuid(); insert into public.offer_approvals(id,agency_id,offer_id,step_order,required_role,status) values(v_approval,v_agency,p_offer_id,1,'ADMIN','PENDING');
    else update public.offer_approvals set status='PENDING',decision_note=null,decided_at=null where id=v_approval and agency_id=v_agency; end if;
    update public.offers set status='PENDING_APPROVAL' where id=p_offer_id and agency_id=v_agency;
  elsif v_action in ('APPROVE','REJECT') then
    if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','approval_forbidden'); end if;
    select id into v_approval from public.offer_approvals where agency_id=v_agency and offer_id=p_offer_id and status='PENDING' order by step_order limit 1;
    if v_approval is null then return jsonb_build_object('ok',false,'error','approval_not_pending'); end if;
    update public.offer_approvals set status=case when v_action='APPROVE' then 'APPROVED' else 'REJECTED' end,approver_user_id=v_user,decision_note=nullif(btrim(coalesce(p_note,'')),''),decided_at=now() where id=v_approval and agency_id=v_agency;
    update public.offers set status=case when v_action='APPROVE' then 'APPROVED' else 'DRAFT' end,metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('last_approval_action',v_action,'last_approval_note',p_note) where id=p_offer_id and agency_id=v_agency;
  else return jsonb_build_object('ok',false,'error','invalid_approval_action'); end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'offer',p_offer_id,'offer.approval_'||lower(v_action),'Offer approval action',jsonb_build_object('action',v_action,'note',p_note));
  return jsonb_build_object('ok',true,'action',v_action);
end;$fn$;

create or replace function public.xzrecruiter_offer_set_status(
  p_token text,p_offer_id uuid,p_status text
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_current text;v_new text:=upper(coalesce(p_status,''));
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_new not in ('DRAFT','PENDING_APPROVAL','APPROVED','SENT','VIEWED','ACCEPTED','DECLINED','EXPIRED','WITHDRAWN') then return jsonb_build_object('ok',false,'error','invalid_status'); end if;
  select status into v_current from public.offers where id=p_offer_id and agency_id=v_agency;
  if v_current is null then return jsonb_build_object('ok',false,'error','offer_not_found'); end if;
  if v_new='SENT' and v_current<>'APPROVED' then return jsonb_build_object('ok',false,'error','offer_must_be_approved'); end if;
  update public.offers set status=v_new,
    sent_at=case when v_new='SENT' then coalesce(sent_at,now()) else sent_at end,
    viewed_at=case when v_new='VIEWED' then coalesce(viewed_at,now()) else viewed_at end,
    accepted_at=case when v_new='ACCEPTED' then coalesce(accepted_at,now()) else accepted_at end,
    declined_at=case when v_new='DECLINED' then coalesce(declined_at,now()) else declined_at end,
    withdrawn_at=case when v_new='WITHDRAWN' then coalesce(withdrawn_at,now()) else withdrawn_at end
  where id=p_offer_id and agency_id=v_agency;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'offer',p_offer_id,'offer.status_changed',v_current||' → '||v_new);
  return jsonb_build_object('ok',true,'status',v_new);
end;$fn$;

-- Candidate portal can upload a new resume without obtaining workspace credentials.
create or replace function public.xzrecruiter_candidate_portal_prepare_document(
  p_portal_token text,p_filename text,p_mime_type text,p_size_bytes bigint,p_checksum text
) returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_candidate uuid;v_document uuid:=gen_random_uuid();v_parse uuid:=gen_random_uuid();v_version integer;v_path text;v_filename text;
begin
  select agency_id,candidate_id into v_agency,v_candidate from public.candidate_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
  if coalesce(p_size_bytes,0)<=0 or p_size_bytes>8388608 then return jsonb_build_object('ok',false,'error','invalid_file_size'); end if;
  if coalesce(p_mime_type,'') not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain') then return jsonb_build_object('ok',false,'error','unsupported_file_type'); end if;
  v_filename:=regexp_replace(coalesce(nullif(btrim(p_filename),''),'resume'),'[^A-Za-z0-9._-]+','-','g');
  select coalesce(max(version_number),0)+1 into v_version from public.candidate_documents where agency_id=v_agency and candidate_id=v_candidate and document_type='RESUME';
  v_path:=v_agency::text||'/'||v_candidate::text||'/resume/'||v_document::text||'-'||v_filename;
  update public.candidate_documents set is_primary=false where agency_id=v_agency and candidate_id=v_candidate and document_type='RESUME' and archived_at is null;
  insert into public.candidate_documents(id,agency_id,candidate_id,document_type,version_number,filename,storage_path,mime_type,size_bytes,checksum,is_primary)
    values(v_document,v_agency,v_candidate,'RESUME',v_version,v_filename,v_path,p_mime_type,p_size_bytes,p_checksum,true);
  insert into public.candidate_parse_runs(id,agency_id,candidate_id,document_id,provider,parser_version,status,review_state)
    values(v_parse,v_agency,v_candidate,v_document,'XZ_PORTAL','xz-local-1','PENDING','NEEDS_REVIEW');
  insert into public.recruitment_activity_events(agency_id,entity_type,entity_id,action,summary,metadata) values(v_agency,'candidate',v_candidate,'resume.portal_uploaded','Candidate uploaded a new resume',jsonb_build_object('document_id',v_document,'version',v_version));
  return jsonb_build_object('ok',true,'agency_id',v_agency,'candidate_id',v_candidate,'document_id',v_document,'parse_run_id',v_parse,'storage_path',v_path,'version_number',v_version);
end;$fn$;

create or replace function public.xzrecruiter_candidate_portal_finalize_parse(
  p_portal_token text,p_parse_run_id uuid,p_extracted_data jsonb,p_field_confidence jsonb,p_field_evidence jsonb,p_error text default null
) returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_candidate uuid;v_status text;
begin
  select agency_id,candidate_id into v_agency,v_candidate from public.candidate_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
  if not exists(select 1 from public.candidate_parse_runs where id=p_parse_run_id and agency_id=v_agency and candidate_id=v_candidate) then return jsonb_build_object('ok',false,'error','parse_run_not_found'); end if;
  v_status:=case when nullif(p_error,'') is null then 'COMPLETED' else 'FAILED' end;
  update public.candidate_parse_runs set status=v_status,extracted_data=coalesce(p_extracted_data,'{}'::jsonb),field_confidence=coalesce(p_field_confidence,'{}'::jsonb),field_evidence=coalesce(p_field_evidence,'{}'::jsonb),error_message=nullif(p_error,''),updated_at=now() where id=p_parse_run_id and agency_id=v_agency and candidate_id=v_candidate;
  return jsonb_build_object('ok',true,'status',v_status);
end;$fn$;

grant execute on function public.xzrecruiter_create_talent_pool(text,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_application_closeout_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean) to anon,authenticated;
grant execute on function public.xzrecruiter_bulk_job_action(text,uuid[],text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_export(text,uuid[]) to anon,authenticated;
grant execute on function public.xzrecruiter_offer_closeout_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_offer_approval_action(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_offer_set_status(text,uuid,text) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_portal_prepare_document(text,text,text,bigint,text) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_portal_finalize_parse(text,uuid,jsonb,jsonb,jsonb,text) to anon,authenticated;
