-- Additive extensions to existing CRM/ATS/intelligence/Step 6/Step 8.
-- Apply AFTER the reconciled Step 1–9 migrations. No historical rows are rewritten.
begin;
alter table public.recruitment_contacts add column if not exists full_name text;
alter table public.recruitment_contacts add column if not exists title text;
alter table public.recruitment_clients add column if not exists created_by_user_id uuid references public.users(id);
alter table public.recruitment_clients add column if not exists website text;
alter table public.recruitment_clients add column if not exists industry text;
alter table public.candidates add column if not exists current_title text;
alter table public.candidates add column if not exists current_company text;
alter table public.candidates add column if not exists skills jsonb not null default '[]'::jsonb;
alter table public.candidates add column if not exists experience_years numeric;
alter table public.candidates add column if not exists salary_expected numeric;
alter table public.candidates add column if not exists salary_currency text;
alter table public.candidates add column if not exists salary_period text;
alter table public.candidates add column if not exists notice_period_days integer;
alter table public.candidates add column if not exists linkedin_url text;
alter table public.recruitment_clients add column if not exists parent_client_id uuid references public.recruitment_clients(id);
alter table public.recruitment_jobs add column if not exists client_bill_rate numeric check (client_bill_rate >= 0);
alter table public.recruitment_jobs add column if not exists bill_currency text check (bill_currency ~ '^[A-Z]{3}$');
alter table public.recruitment_jobs add column if not exists bill_period text check (bill_period in ('HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL','FIXED'));
alter table public.recruitment_jobs add column if not exists submission_config jsonb not null default '{}'::jsonb;
alter table public.placements add column if not exists offer_id uuid;
alter table public.placements add column if not exists created_by_user_id uuid references public.users(id);
alter table public.placements add column if not exists placement_fee numeric check (placement_fee >= 0);
alter table public.crm_activities add column if not exists candidate_id uuid references public.candidates(id);
alter table public.crm_activities add column if not exists job_id uuid references public.recruitment_jobs(id);
create index if not exists idx_xzr_activity_candidate_job on public.crm_activities(agency_id,candidate_id,job_id,occurred_at desc);
create index if not exists idx_xzr_clients_parent on public.recruitment_clients(agency_id,parent_client_id);
-- Migration intentionally fails if historic conflicting releases exist: resolve explicitly.
create unique index if not exists uq_xzr_released_candidate_job_client
on public.candidate_submissions(agency_id,candidate_id,job_id,client_id) nulls not distinct
where workflow_status='CLIENT_SUBMITTED';


create or replace function public.xzrecruiter_client_portal_snapshot(p_portal_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_client uuid;v_contact uuid;
begin
 select agency_id,client_id,contact_id into v_agency,v_client,v_contact from public.client_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() and exists(select 1 from public.recruitment_clients active_client where active_client.id=client_portal_sessions.client_id and active_client.agency_id=client_portal_sessions.agency_id and active_client.archived_at is null) limit 1;
 if v_client is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 update public.client_portal_sessions set last_seen_at=now() where token_hash=encode(extensions.digest(p_portal_token,'sha256'),'hex');
 return jsonb_build_object('ok',true,
  'client',(select jsonb_build_object('id',c.id,'name',c.name,'website',c.website,'country_code',c.country_code,'timezone',c.timezone) from public.recruitment_clients c where c.id=v_client and c.agency_id=v_agency and c.archived_at is null),
  'contact',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'title',c.title,'email',c.email) from public.recruitment_contacts c where c.id=v_contact and c.agency_id=v_agency),
  'jobs',coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'title',j.title,'status',j.status,'location',j.location,'country_code',j.country_code,'workplace_type',j.workplace_type,'openings',j.openings) order by j.updated_at desc) from public.recruitment_jobs j where j.agency_id=v_agency and j.client_id=v_client and j.archived_at is null and j.status in ('OPEN','ON_HOLD')),'[]'::jsonb),
  'submissions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'status',s.status,'summary',s.client_submission_snapshot#>>'{pack,candidateSummary,narrative}','client_pack',s.client_submission_snapshot->'pack','presentation_format',s.client_submission_snapshot->>'presentationFormat','salary_expectation',s.client_submission_snapshot#>'{pack,compensation,value}','salary_currency',s.client_submission_snapshot#>>'{pack,compensation,currency}','availability',s.client_submission_snapshot#>>'{pack,availability,status,value}','notice_period_days',s.client_submission_snapshot#>'{pack,availability,noticePeriodDays,value}','submitted_at',s.submitted_at,'candidate_name',c.full_name,'candidate_title',c.current_title,'job_id',j.id,'job_title',j.title,'feedback',coalesce((select jsonb_agg(jsonb_build_object('decision',f.decision,'comment',f.comment,'created_at',f.created_at) order by f.created_at desc) from public.client_portal_feedback f where f.agency_id=v_agency and f.submission_id=s.id),'[]'::jsonb)) order by s.submitted_at desc) from public.candidate_submissions s join public.candidates c on c.id=s.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=s.job_id and j.agency_id=v_agency where s.agency_id=v_agency and s.client_id=v_client and s.workflow_status='CLIENT_SUBMITTED' and s.am_review_status='APPROVED' and s.client_submitted_at is not null and s.client_submission_snapshot is not null),'[]'::jsonb),
  'interviews',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'candidate_name',c.full_name,'job_title',j.title,'interview_type',i.interview_type,'scheduled_at',i.scheduled_at,'timezone',i.timezone,'status',i.status) order by i.scheduled_at desc) from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=v_agency join public.candidates c on c.id=a.candidate_id join public.recruitment_jobs j on j.id=a.job_id where i.agency_id=v_agency and a.client_id=v_client and exists(select 1 from public.candidate_submissions released where released.agency_id=v_agency and released.application_id=a.id and released.client_id=v_client and released.workflow_status='CLIENT_SUBMITTED' and released.am_review_status='APPROVED' and released.client_submitted_at is not null)),'[]'::jsonb)
 );
end;$fn$;

create or replace function public.xzrecruiter_client_portal_feedback(p_portal_token text,p_submission_id uuid,p_decision text,p_comment text default null)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_client uuid;v_contact uuid;v_decision text:=upper(coalesce(p_decision,''));
begin
 select agency_id,client_id,contact_id into v_agency,v_client,v_contact from public.client_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() and exists(select 1 from public.recruitment_clients active_client where active_client.id=client_portal_sessions.client_id and active_client.agency_id=client_portal_sessions.agency_id and active_client.archived_at is null) limit 1;
 if v_client is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 if v_decision not in ('COMMENT','ADVANCE','REQUEST_INTERVIEW','HOLD','REJECT') then return jsonb_build_object('ok',false,'error','invalid_decision'); end if;
 if not exists(select 1 from public.candidate_submissions where id=p_submission_id and agency_id=v_agency and client_id=v_client and workflow_status='CLIENT_SUBMITTED' and am_review_status='APPROVED' and client_submitted_at is not null and client_submission_snapshot is not null) then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
 insert into public.client_portal_feedback(agency_id,client_id,contact_id,submission_id,decision,comment) values(v_agency,v_client,v_contact,p_submission_id,v_decision,nullif(btrim(coalesce(p_comment,'')),''));
 update public.candidate_submissions set status=case v_decision when 'REQUEST_INTERVIEW' then 'INTERVIEW_REQUESTED' when 'ADVANCE' then 'ADVANCED' when 'REJECT' then 'REJECTED' when 'HOLD' then 'ON_HOLD' else status end,client_viewed_at=coalesce(client_viewed_at,now()),updated_at=now() where id=p_submission_id and agency_id=v_agency;
 perform private.xzrecruiter_log_recruitment_event(v_agency,null,'APPLICATION',
 (select application_id from public.candidate_submissions where id=p_submission_id and agency_id=v_agency),
 'client.feedback_received','Client portal feedback received',jsonb_build_object('submission_id',p_submission_id,'client_id',v_client,'contact_id',v_contact,'decision',v_decision));
 return jsonb_build_object('ok',true,'decision',v_decision,'status',(select status from public.candidate_submissions where id=p_submission_id and agency_id=v_agency));
end;$fn$;

create or replace function public.xzrecruiter_client_submit(
  p_token text,p_submission_id uuid,p_client_contact jsonb default '{}'::jsonb,p_expected_version integer default null,p_expected_lock bigint default null,p_idempotency_key text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_s record;v_sv record;v_elig jsonb;v_source text;v_resp jsonb;v_idem text;v_snapshot jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER') then return jsonb_build_object('ok',false,'error','client_submit_forbidden'); end if;
  v_idem:=left(coalesce(nullif(btrim(p_idempotency_key),''),'client:'||p_submission_id::text||':'||coalesce(p_expected_version::text,'')),180);
  perform pg_advisory_xact_lock(hashtext(v_agency::text||'|STEP6_CLIENT|'||p_submission_id::text));
  select response_json into v_resp from public.candidate_submission_idempotency where agency_id=v_agency and operation='CLIENT_SUBMIT' and idempotency_key=v_idem;
  if v_resp is not null then return v_resp; end if;
  select * into v_s from public.candidate_submissions where agency_id=v_agency and id=p_submission_id for update;
  if not found then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
  if v_s.client_id is null then return jsonb_build_object('ok',false,'error','client_required'); end if;
  perform pg_advisory_xact_lock(hashtextextended(v_agency::text||'|CLIENT_RELEASE|'||v_s.candidate_id::text||'|'||v_s.job_id::text||'|'||v_s.client_id::text,0));
  if v_s.workflow_status='CLIENT_SUBMITTED' then return jsonb_build_object('ok',true,'reused',true,'workflowStatus','CLIENT_SUBMITTED','submittedAt',v_s.client_submitted_at,'versionNumber',v_s.client_submission_version_number); end if;
  if v_s.workflow_status<>'AM_APPROVED' then return jsonb_build_object('ok',false,'error','submission_not_am_approved','workflow_status',v_s.workflow_status); end if;
  if p_expected_version is null or p_expected_lock is null or v_s.latest_version_number<>p_expected_version or v_s.version_lock<>p_expected_lock then return jsonb_build_object('ok',false,'error','stale_submission_version','currentVersion',v_s.latest_version_number,'currentLock',v_s.version_lock); end if;
  select * into v_sv from public.candidate_submission_versions where agency_id=v_agency and id=v_s.current_version_id and submission_id=v_s.id;
  if not found then return jsonb_build_object('ok',false,'error','submission_version_missing'); end if;
  v_elig:=private.xzrecruiter_step6_eligibility(v_agency,v_s.application_id);v_source:=v_elig->>'sourceFingerprint';
  if coalesce((v_elig->>'eligible')::boolean,false)=false or v_source is distinct from v_sv.source_fingerprint then return jsonb_build_object('ok',false,'error','stale_client_submission_blocked','regenerateRequired',true,'eligibility',v_elig); end if;
  if exists(select 1 from public.candidate_submissions d where d.agency_id=v_agency and d.id<>v_s.id and d.candidate_id=v_s.candidate_id and d.job_id=v_s.job_id and d.client_id is not distinct from v_s.client_id and d.workflow_status='CLIENT_SUBMITTED') then return jsonb_build_object('ok',false,'error','duplicate_client_submission'); end if;

  v_snapshot:=jsonb_build_object('presentationFormat',coalesce(private.xzrecruiter_step6_configuration(v_agency,v_s.job_id)#>>'{raw,presentationFormat}','SUMMARY'),'submissionId',v_s.id,'submissionVersionId',v_sv.id,'submissionVersionNumber',v_sv.version_number,'candidateId',v_s.candidate_id,'jobId',v_s.job_id,'clientId',v_s.client_id,'clientContact',coalesce(p_client_contact,'{}'::jsonb),'pack',v_sv.client_facing_pack,'resume',jsonb_build_object('documentId',v_sv.resume_document_id,'versionNumber',v_sv.resume_version_number,'checksum',v_sv.resume_checksum),'commercial',v_sv.client_commercial_snapshot,'requirementVersion',v_sv.requirement_version,'sourceFingerprint',v_sv.source_fingerprint,'submittedBy',v_user,'submittedAt',now());
  update public.candidate_submissions set workflow_status='CLIENT_SUBMITTED',status='SUBMITTED',submitted_at=coalesce(submitted_at,now()),client_submitted_at=now(),submitted_by_user_id=v_user,client_contact_snapshot=coalesce(p_client_contact,'{}'::jsonb),client_submission_snapshot=v_snapshot,client_submission_version_number=v_sv.version_number,client_resume_document_id=v_sv.resume_document_id,client_resume_version_number=v_sv.resume_version_number,client_commercial_snapshot=v_sv.client_commercial_snapshot,version_lock=version_lock+1,updated_at=now() where id=v_s.id and agency_id=v_agency;
  update public.applications set submitted_at=coalesce(submitted_at,now()),last_activity_at=now(),updated_at=now() where id=v_s.application_id and agency_id=v_agency;
  insert into public.candidate_submission_reviews(agency_id,submission_id,application_id,submission_version_id,submission_version_number,decision,note,requirement_version,candidate_version,resume_version_number,actor_user_id) values(v_agency,v_s.id,v_s.application_id,v_sv.id,v_sv.version_number,'CLIENT_SUBMITTED','Exact approved version released to client',v_sv.requirement_version,v_sv.source_fingerprint,v_sv.resume_version_number,v_user);
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',v_s.application_id,'submission.client_submitted','AM released exact approved Submission Pack to client',jsonb_build_object('submission_id',v_s.id,'version_number',v_sv.version_number,'resume_document_id',v_sv.resume_document_id,'resume_version_number',v_sv.resume_version_number));
  v_resp:=jsonb_build_object('ok',true,'reused',false,'workflowStatus','CLIENT_SUBMITTED','versionNumber',v_sv.version_number,'versionLock',v_s.version_lock+1,'submittedAt',now());
  insert into public.candidate_submission_idempotency(agency_id,submission_id,operation,idempotency_key,request_fingerprint,response_json,actor_user_id) values(v_agency,v_s.id,'CLIENT_SUBMIT',v_idem,v_sv.source_fingerprint,v_resp,v_user) on conflict(agency_id,operation,idempotency_key) do nothing;
  return v_resp;
end;
$fn$;

create or replace function public.xzrecruiter_submission_input(
  p_token text,p_application_id uuid
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_app record;
  v_candidate jsonb;v_job jsonb;v_client jsonb;v_requirement jsonb;v_criteria jsonb;v_match jsonb;v_profile jsonb;
  v_eligibility jsonb;v_screen jsonb;v_commercial jsonb;v_current jsonb;v_current_version jsonb;v_reviews jsonb;v_versions jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_step6_submission_access(v_agency,v_user,v_business_role,p_application_id,false) then
    return jsonb_build_object('ok',false,'error','submission_access_forbidden');
  end if;

  select a.*,ps.code stage_code into v_app
  from public.applications a left join public.pipeline_stages ps on ps.id=a.stage_id and ps.agency_id=v_agency
  where a.agency_id=v_agency and a.id=p_application_id and a.archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;

  select jsonb_build_object(
    'id',c.id,'fullName',c.full_name,'currentTitle',c.current_title,'currentCompany',c.current_company,
    'experienceYears',c.experience_years,'relevantExperienceYears',c.relevant_experience_years,
    'skills',coalesce(c.skills,'[]'::jsonb),'location',concat_ws(', ',nullif(c.city,''),nullif(c.region,''),nullif(c.country_code,'')),
    'workplacePreference',c.workplace_preference,'availabilityStatus',c.availability_status,'noticePeriodDays',c.notice_period_days,
    'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'workAuthorization',coalesce(c.work_authorization_summary,'[]'::jsonb),
    'consentStatus',c.consent_status,'updatedAt',c.updated_at
  ) into v_candidate from public.candidates c where c.agency_id=v_agency and c.id=v_app.candidate_id;

  select jsonb_build_object('id',j.id,'title',j.title,'clientId',j.client_id,'approvedHiringBriefId',j.approved_hiring_brief_id,'updatedAt',j.updated_at)
  into v_job from public.recruitment_jobs j where j.agency_id=v_agency and j.id=v_app.job_id;

  select to_jsonb(cl) into v_client from public.recruitment_clients cl where cl.agency_id=v_agency and cl.id=v_app.client_id;

  select jsonb_build_object('id',hb.id,'versionNumber',hb.version_number,'hiringBrief',hb.hiring_brief,'structuredData',hb.structured_data,'approvedAt',hb.approved_at,'sourceFingerprint',hb.source_fingerprint)
  into v_requirement
  from public.requirement_hiring_briefs hb where hb.agency_id=v_agency and hb.id=(v_job->>'approvedHiringBriefId')::uuid and hb.brief_status='APPROVED';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',rc.id,'criterion_kind',rc.criterion_kind,'label',rc.label,'field_key',rc.field_key,'value_text',rc.value_text,
    'enforcement',rc.enforcement,'am_confirmed',rc.am_confirmed,'evidence',rc.evidence
  ) order by rc.sort_order,rc.created_at),'[]'::jsonb) into v_criteria
  from public.requirement_criteria rc where rc.agency_id=v_agency and rc.brief_id=(v_requirement->>'id')::uuid;

  select to_jsonb(x) into v_match from (
    select m.id,m.profile_version_id,m.run_status,m.score,m.match_band,m.confidence,m.coverage,m.hard_rule_status,
      m.hard_rule_results,m.requirement_results,m.strengths,m.gaps,m.uncertainties,m.recommendation,m.brief_id,m.brief_version,
      m.scoring_version,m.model_name,m.prompt_version,m.schema_version,m.generated_at
    from public.candidate_match_runs m where m.agency_id=v_agency and m.id=v_app.current_candidate_match_id
  ) x;
  select pv.profile_json into v_profile from public.candidate_profile_versions pv
  where pv.agency_id=v_agency and pv.id=nullif(v_match->>'profile_version_id','')::uuid;

  v_eligibility:=private.xzrecruiter_step6_eligibility(v_agency,p_application_id);
  v_screen:=coalesce(v_eligibility->'screening',private.xzrecruiter_step6_screening_snapshot(v_agency,p_application_id));
  v_commercial:=private.xzrecruiter_step6_commercial_snapshot(v_agency,p_application_id,v_business_role);

  select to_jsonb(s) into v_current from public.candidate_submissions s
  where s.agency_id=v_agency and s.application_id=p_application_id order by s.created_at desc limit 1;

  if v_current is not null then
    select jsonb_build_object(
      'id',sv.id,'versionNumber',sv.version_number,'sourceFingerprint',sv.source_fingerprint,
      'submissionPack',case when v_business_role in ('OWNER','ADMIN','ACCOUNT_MANAGER') then sv.submission_pack else sv.submission_pack-'commercialInternal' end,
      'clientFacingPack',sv.client_facing_pack,
      'eligibility',sv.eligibility_snapshot,'resumeDocumentId',sv.resume_document_id,'resumeVersionNumber',sv.resume_version_number,
      'requirementVersion',sv.requirement_version,'screeningVersion',sv.screening_version,'createdAt',sv.created_at
    ) into v_current_version
    from public.candidate_submission_versions sv where sv.agency_id=v_agency and sv.id=nullif(v_current->>'current_version_id','')::uuid;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc),'[]'::jsonb) into v_reviews
    from (select id,submission_version_number,decision,reason_code,note,checklist_snapshot,actor_user_id,created_at from public.candidate_submission_reviews where agency_id=v_agency and submission_id=(v_current->>'id')::uuid order by created_at desc limit 30) r;
    select coalesce(jsonb_agg(to_jsonb(v) order by v.version_number desc),'[]'::jsonb) into v_versions
    from (select id,version_number,source_fingerprint,resume_document_id,resume_version_number,requirement_version,screening_version,change_summary,generated_by_user_id,created_at from public.candidate_submission_versions where agency_id=v_agency and submission_id=(v_current->>'id')::uuid order by version_number desc limit 20) v;
  else
    v_current_version:='{}'::jsonb;v_reviews:='[]'::jsonb;v_versions:='[]'::jsonb;
  end if;

  return jsonb_build_object(
    'ok',true,'businessRole',v_business_role,'currentUserId',v_user,
    'application',jsonb_build_object('id',v_app.id,'candidateId',v_app.candidate_id,'jobId',v_app.job_id,'clientId',v_app.client_id,'stage',v_app.stage_code,'candidacyState',coalesce(to_jsonb(v_app)->>'candidacy_state',private.xzrecruiter_canonical_candidacy_state(v_app.stage_code)),'updatedAt',v_app.updated_at),
    'candidate',v_candidate,'job',v_job,'client',coalesce(v_client,'{}'::jsonb),'requirement',coalesce(v_requirement,'{}'::jsonb),
    'criteria',v_criteria,'candidateIntelligence',coalesce(v_match,'{}'::jsonb),'candidateProfile',coalesce(v_profile,'{}'::jsonb),
    'screening',v_screen,'resume',coalesce(v_eligibility->'resume','{}'::jsonb),'commercial',v_commercial,
    'configuration',private.xzrecruiter_step6_configuration(v_agency,v_app.job_id),'compliance',coalesce(to_jsonb(v_app)->'metadata'->'compliance','{}'::jsonb),
    'conflicts',coalesce(v_screen->'conflicts','[]'::jsonb),'eligibility',v_eligibility,
    'submission',case when v_business_role in ('OWNER','ADMIN','ACCOUNT_MANAGER') then coalesce(v_current,'{}'::jsonb) else coalesce(v_current,'{}'::jsonb)-'internal_commercial_snapshot'-'client_submission_snapshot' end,
    'currentVersion',coalesce(v_current_version,'{}'::jsonb),'previousSubmissions',coalesce((select jsonb_agg(to_jsonb(h)) from (
 select s.id,s.job_id,s.client_id,s.workflow_status,s.am_review_status,s.client_submitted_at,j.title job_title,cl.name client_name
 from public.candidate_submissions s join public.recruitment_jobs j on j.id=s.job_id and j.agency_id=v_agency
 left join public.recruitment_clients cl on cl.id=s.client_id and cl.agency_id=v_agency
 where s.agency_id=v_agency and s.candidate_id=v_app.candidate_id and s.application_id<>v_app.id
 and (v_business_role<>'RECRUITER' or private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,s.job_id))
 order by s.created_at desc limit 30) h),'[]'::jsonb),'reviewHistory',v_reviews,'versionHistory',v_versions
  );
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','submission_context_invalid_data');
end;
$fn$;

create or replace function private.xzrecruiter_talent_match_candidates(p_agency uuid,p_job_id uuid,p_user uuid,p_role text,p_query text default '',p_limit integer default 30)
returns jsonb language plpgsql stable security invoker set search_path='public','private','pg_temp' as $fn$
declare v_agency uuid:=p_agency;v_user uuid:=p_user;v_business_role text:=p_role;v_brief uuid;v_q text:=lower(btrim(coalesce(p_query,'')));v_limit integer:=greatest(1,least(coalesce(p_limit,30),50));v_rows jsonb;
begin
  select approved_hiring_brief_id into v_brief from public.recruitment_jobs
  where id=p_job_id and agency_id=v_agency and recruiter_ready=true and approved_hiring_brief_id is not null;
  if v_brief is null then return jsonb_build_object('ok',false,'error','approved_brief_required'); end if;

  with required_skills as (
    select distinct private.xzrecruiter_normalize_candidate_skill(c.value_text) skill
    from public.requirement_criteria c
    where c.agency_id=v_agency and c.brief_id=v_brief and c.criterion_kind='MUST_HAVE'
      and lower(c.field_key) ~ '(skill|technology|tool)'
      and nullif(btrim(c.value_text),'') is not null
  ), ranked as (
    select c.id,c.full_name,c.current_title,c.current_company,c.city,c.region,c.country_code,c.updated_at,
      c.owner_user_id,
      (select jsonb_build_object('score',m.score,'band',m.match_band,'jobId',m.job_id,'generatedAt',m.generated_at,'historical',true,'requiresReassessment',m.job_id<>p_job_id or m.run_status<>'SUCCEEDED' or m.profile_version_id is distinct from c.current_intelligence_profile_id or m.brief_id<>v_brief)
       from public.candidate_match_runs m where m.agency_id=v_agency and m.candidate_id=c.id and m.run_status in ('SUCCEEDED','STALE') and m.match_band='Strong Match'
       and private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,m.job_id)
       order by m.generated_at desc limit 1) previous_strong_match,
      exists(select 1 from public.applications a where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=c.id and a.archived_at is null) already_on_requirement,
      (select count(*) from required_skills) required_skill_count,
      (
        select count(distinct rs.skill)
        from required_skills rs
        where exists(
          select 1 from public.candidate_profile_skills s
          where s.agency_id=v_agency and s.candidate_id=c.id and s.normalized_value=rs.skill
            and s.profile_version_id=c.current_intelligence_profile_id
        ) or exists(
          select 1 from jsonb_array_elements_text(coalesce(c.skills,'[]'::jsonb)) raw
          where private.xzrecruiter_normalize_candidate_skill(raw)=rs.skill
        )
      ) matched_skill_count,
      case when v_q='' then 0 else
        (case when lower(coalesce(c.full_name,'')) like '%'||v_q||'%' then 4 else 0 end)+
        (case when lower(coalesce(c.current_title,'')) like '%'||v_q||'%' then 3 else 0 end)+
        (case when lower(coalesce(c.current_company,'')) like '%'||v_q||'%' then 2 else 0 end)
      end lexical_score,
      (c.current_intelligence_profile_id is not null) intelligence_available
    from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and (
        v_q='' or lower(coalesce(c.full_name,'')) like '%'||v_q||'%'
        or lower(coalesce(c.current_title,'')) like '%'||v_q||'%'
        or lower(coalesce(c.current_company,'')) like '%'||v_q||'%'
        or lower(coalesce(c.city,'')) like '%'||v_q||'%'
        or exists(select 1 from jsonb_array_elements_text(coalesce(c.skills,'[]'::jsonb)) raw where lower(raw) like '%'||v_q||'%')
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'full_name',r.full_name,'current_title',r.current_title,'current_company',r.current_company,
    'city',r.city,'region',r.region,'country_code',r.country_code,'already_on_requirement',r.already_on_requirement,
    'required_skill_count',r.required_skill_count,'matched_skill_count',r.matched_skill_count,
    'skill_coverage',case when r.required_skill_count=0 then null else round(r.matched_skill_count*100.0/r.required_skill_count) end,
    'intelligence_available',r.intelligence_available,'previous_strong_match',r.previous_strong_match,
    'email',case when v_business_role<>'RECRUITER' or r.owner_user_id=v_user or r.already_on_requirement then c.email else null end,
    'phone',case when v_business_role<>'RECRUITER' or r.owner_user_id=v_user or r.already_on_requirement then c.phone else null end
  ) order by r.matched_skill_count desc,r.lexical_score desc,r.updated_at desc),'[]'::jsonb)
  into v_rows
  from (
    select * from ranked
    order by matched_skill_count desc,lexical_score desc,updated_at desc
    limit v_limit
  ) r
  join public.candidates c on c.id=r.id and c.agency_id=v_agency;

  return jsonb_build_object('ok',true,'rows',v_rows,'ranking','TENANT_SCOPE_THEN_STRUCTURED_SKILLS_THEN_LEXICAL','semantic_used',false);
end;
$fn$;
revoke all on function private.xzrecruiter_talent_match_candidates(uuid,uuid,uuid,text,text,integer) from public,anon,authenticated;

create or replace function public.xzrecruiter_talent_match_search(
  p_token text,p_job_id uuid,p_query text default '',p_limit integer default 30
) returns jsonb
language plpgsql stable security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_brief uuid;
  v_q text:=lower(btrim(coalesce(p_query,'')));v_limit integer:=greatest(1,least(coalesce(p_limit,30),50));v_rows jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  return private.xzrecruiter_talent_match_candidates(v_agency,p_job_id,v_user,v_business_role,p_query,p_limit);
end;
$fn$;

revoke all on function public.xzrecruiter_client_portal_snapshot(text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_client_portal_snapshot(text) to anon,authenticated;

revoke all on function public.xzrecruiter_client_portal_feedback(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_client_portal_feedback(text,uuid,text,text) to anon,authenticated;

revoke all on function public.xzrecruiter_client_submit(text,uuid,jsonb,integer,bigint,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_client_submit(text,uuid,jsonb,integer,bigint,text) to anon,authenticated;

revoke all on function public.xzrecruiter_submission_input(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_submission_input(text,uuid) to anon,authenticated;

revoke all on function public.xzrecruiter_talent_match_search(text,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.xzrecruiter_talent_match_search(text,uuid,text,integer) to anon,authenticated;

-- Two-level client/company -> operating account on the existing client table.
create or replace function private.xzrecruiter_account_parent_guard()
returns trigger language plpgsql security definer set search_path='public','private','pg_temp' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(new.agency_id::text||'|ACCOUNT_HIERARCHY',0));
  if new.parent_client_id is not null then
    if new.parent_client_id=new.id or not exists(select 1 from public.recruitment_clients p where p.id=new.parent_client_id and p.agency_id=new.agency_id and p.parent_client_id is null and p.archived_at is null)
      or exists(select 1 from public.recruitment_clients child where child.parent_client_id=new.id and child.agency_id=new.agency_id) then
      raise exception 'invalid_parent_client' using errcode='23514';
    end if;
  end if;
  return new;
end;$$;
revoke all on function private.xzrecruiter_account_parent_guard() from public,anon,authenticated;
create trigger xzr_account_parent_guard before insert or update of parent_client_id,agency_id on public.recruitment_clients for each row execute function private.xzrecruiter_account_parent_guard();

create or replace function private.xzrecruiter_requirement_client_guard()
returns trigger language plpgsql security definer set search_path='public','private','pg_temp' as $$
begin
  if new.client_id is null then
    if tg_op='INSERT' then raise exception 'client_required' using errcode='23514'; end if;
    if old.client_id is not null or new.requirement_state is distinct from old.requirement_state then raise exception 'client_required' using errcode='23514'; end if;
  elsif not exists(select 1 from public.recruitment_clients c where c.id=new.client_id and c.agency_id=new.agency_id and c.archived_at is null) then
    raise exception 'invalid_client' using errcode='23514';
  end if;
  if tg_op='UPDATE' and new.client_id is distinct from old.client_id and exists(select 1 from public.applications a where a.agency_id=new.agency_id and a.job_id=new.id) then
    raise exception 'requirement_client_locked_by_applications' using errcode='23514';
  end if;
  return new;
end;$$;
revoke all on function private.xzrecruiter_requirement_client_guard() from public,anon,authenticated;
create trigger xzr_requirement_client_guard before insert or update of client_id,agency_id,requirement_state on public.recruitment_jobs for each row execute function private.xzrecruiter_requirement_client_guard();

create or replace function public.xzrecruiter_set_account_parent(p_token text,p_client_id uuid,p_parent_client_id uuid,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_client record;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if not private.xzrecruiter_has_permission(v_role,'commercial:edit') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 select * into v_client from public.recruitment_clients where id=p_client_id and agency_id=ctx.agency_id and archived_at is null for update;
 if not found then return jsonb_build_object('ok',false,'error','client_not_found'); end if;
 if p_expected_updated_at is null or v_client.updated_at<>p_expected_updated_at then return jsonb_build_object('ok',false,'error','stale_account'); end if;
 update public.recruitment_clients set parent_client_id=p_parent_client_id,updated_at=now() where id=p_client_id and agency_id=ctx.agency_id;
 perform private.xzrecruiter_log_recruitment_event(ctx.agency_id,ctx.user_id,'CLIENT',p_client_id,'client.account_linked','Operating account parent updated',jsonb_build_object('previous_parent',v_client.parent_client_id,'parent_client_id',p_parent_client_id));
 return jsonb_build_object('ok',true);
end;$$;

create or replace function public.xzrecruiter_transfer_candidate_owner(p_token text,p_candidate_id uuid,p_owner_user_id uuid,p_expected_owner_user_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_old uuid;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if v_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if p_owner_user_id is null then
   if not exists(select 1 from public.candidates where agency_id=ctx.agency_id and id=p_candidate_id and archived_at is null) then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
   return jsonb_build_object('ok',true,'ownerUserId',(select owner_user_id from public.candidates where agency_id=ctx.agency_id and id=p_candidate_id),'members',(select coalesce(jsonb_agg(jsonb_build_object('id',m.user_id,'name',u.display_name)),'[]'::jsonb) from public.agency_memberships m join public.users u on u.id=m.user_id where m.agency_id=ctx.agency_id and private.xzrecruiter_business_role(ctx.agency_id,m.user_id,m.role) in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER')));
 end if;
 if length(btrim(coalesce(p_reason,'')))<5 then return jsonb_build_object('ok',false,'error','reason_required'); end if;
 if not exists(select 1 from public.agency_memberships m where m.agency_id=ctx.agency_id and m.user_id=p_owner_user_id and private.xzrecruiter_business_role(ctx.agency_id,m.user_id,m.role) in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER')) then return jsonb_build_object('ok',false,'error','invalid_owner'); end if;
 select owner_user_id into v_old from public.candidates where id=p_candidate_id and agency_id=ctx.agency_id and archived_at is null for update;
 if not found then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
 if v_old is distinct from p_expected_owner_user_id then return jsonb_build_object('ok',false,'error','stale_owner'); end if;
 if v_old=p_owner_user_id then return jsonb_build_object('ok',true,'reused',true); end if;
 update public.candidates set owner_user_id=p_owner_user_id,updated_at=now() where id=p_candidate_id and agency_id=ctx.agency_id;
 perform private.xzrecruiter_log_recruitment_event(ctx.agency_id,ctx.user_id,'CANDIDATE',p_candidate_id,'candidate.ownership_transferred','Candidate ownership transferred',jsonb_build_object('previous_owner',v_old,'owner',p_owner_user_id,'reason',left(p_reason,1000)));
 return jsonb_build_object('ok',true,'ownerUserId',p_owner_user_id);
end;$$;

create or replace function public.xzrecruiter_requirement_commercial(p_token text,p_job_id uuid,p_values jsonb default null)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; j record; v_rate numeric; v_currency text; v_period text; v_format text;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if not private.xzrecruiter_has_permission(v_role,case when p_values is null then 'commercial:view' else 'commercial:edit' end) or not private.xzrecruiter_recruiter_job_access(ctx.agency_id,ctx.user_id,v_role,p_job_id) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 select * into j from public.recruitment_jobs where id=p_job_id and agency_id=ctx.agency_id and archived_at is null for update;
 if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
 if p_values is not null then
   if nullif(p_values->>'expectedUpdatedAt','') is null or j.updated_at<>(p_values->>'expectedUpdatedAt')::timestamptz then return jsonb_build_object('ok',false,'error','stale_requirement'); end if;
   v_rate:=nullif(p_values->>'billRate','')::numeric;v_currency:=upper(nullif(p_values->>'currency',''));v_period:=upper(nullif(p_values->>'period',''));v_format:=coalesce(p_values->>'presentationFormat','SUMMARY');
   if v_rate<0 or (v_rate is not null and (v_currency is null or v_currency !~ '^[A-Z]{3}$' or v_period is null or v_period not in ('HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL','FIXED'))) or v_format not in ('SUMMARY','DETAILED') then return jsonb_build_object('ok',false,'error','invalid_commercial_terms'); end if;
   update public.recruitment_jobs set client_bill_rate=v_rate,bill_currency=v_currency,bill_period=v_period,submission_config=coalesce(private.xzrecruiter_step6_configuration(ctx.agency_id,p_job_id)->'raw','{}'::jsonb)||jsonb_build_object('presentationFormat',v_format,'includeCandidateCompensationForClient',coalesce((p_values->>'includeCompensation')::boolean,false)),updated_at=now() where id=p_job_id and agency_id=ctx.agency_id returning * into j;
   perform private.xzrecruiter_log_recruitment_event(ctx.agency_id,ctx.user_id,'JOB',p_job_id,'requirement.commercial_updated','Requirement commercial terms updated',jsonb_build_object('presentationFormat',v_format));
 end if;
 return jsonb_build_object('ok',true,'billRate',j.client_bill_rate,'currency',j.bill_currency,'period',j.bill_period,'presentationFormat',coalesce(j.submission_config->>'presentationFormat','SUMMARY'),'includeCompensation',coalesce((j.submission_config->>'includeCandidateCompensationForClient')::boolean,false),'updatedAt',j.updated_at);
end;$$;

-- A shared communication record lives in CRM activities, linked to existing entities.
create or replace function public.xzrecruiter_communication_timeline(p_token text,p_job_id uuid,p_candidate_id uuid default null,p_entry jsonb default null)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_client uuid; v_rows jsonb; v_id uuid; v_type text;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if v_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER','RECRUITER') or not private.xzrecruiter_recruiter_job_access(ctx.agency_id,ctx.user_id,v_role,p_job_id) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 select client_id into v_client from public.recruitment_jobs where id=p_job_id and agency_id=ctx.agency_id and archived_at is null;
 if v_client is null then return jsonb_build_object('ok',false,'error','client_required'); end if;
 if p_candidate_id is not null and not exists(select 1 from public.applications a where a.agency_id=ctx.agency_id and a.job_id=p_job_id and a.candidate_id=p_candidate_id and a.archived_at is null and (v_role<>'RECRUITER' or a.owner_user_id=ctx.user_id)) then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
 if p_entry is not null then
   v_type:=upper(coalesce(p_entry->>'type','NOTE'));
   if v_type not in ('NOTE','CALL','EMAIL','MEETING','LINKEDIN','WHATSAPP','SMS') or length(btrim(coalesce(p_entry->>'body','')))=0 or length(p_entry->>'body')>4000 then return jsonb_build_object('ok',false,'error','invalid_communication'); end if;
   v_id:=nullif(p_entry->>'id','')::uuid;
   if v_id is null then return jsonb_build_object('ok',false,'error','idempotency_key_required'); end if;
   perform pg_advisory_xact_lock(hashtextextended(v_id::text,0));
   if exists(select 1 from public.crm_activities where id=v_id and (agency_id<>ctx.agency_id or actor_user_id is distinct from ctx.user_id or job_id is distinct from p_job_id or candidate_id is distinct from p_candidate_id or body is distinct from p_entry->>'body' or activity_type<>v_type)) then return jsonb_build_object('ok',false,'error','communication_conflict'); end if;
   if not exists(select 1 from public.crm_activities where id=v_id) then
     insert into public.crm_activities(id,agency_id,client_id,job_id,candidate_id,activity_type,subject,body,direction,actor_user_id,metadata)
     values(v_id,ctx.agency_id,v_client,p_job_id,p_candidate_id,v_type,left(p_entry->>'subject',200),p_entry->>'body','INTERNAL',ctx.user_id,jsonb_build_object('capture','MANUAL','deliveryConfirmed',false));
     perform private.xzrecruiter_log_recruitment_event(ctx.agency_id,ctx.user_id,'JOB',p_job_id,'communication.recorded','Communication logged',jsonb_build_object('activity_id',v_id,'candidate_id',p_candidate_id,'client_id',v_client,'channel',v_type));
   end if;
 end if;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc),'[]'::jsonb) into v_rows from (
 select a.id,a.activity_type,a.subject,a.body,a.occurred_at,a.candidate_id,u.display_name actor_name
 from public.crm_activities a left join public.users u on u.id=a.actor_user_id
 where a.agency_id=ctx.agency_id and a.job_id=p_job_id and (p_candidate_id is null or a.candidate_id=p_candidate_id)
 and (v_role<>'RECRUITER' or a.actor_user_id=ctx.user_id or (a.candidate_id is not null and exists(select 1 from public.applications owned where owned.agency_id=ctx.agency_id and owned.job_id=p_job_id and owned.candidate_id=a.candidate_id and owned.owner_user_id=ctx.user_id and owned.archived_at is null)))
 order by a.occurred_at desc limit 100) t;
 return jsonb_build_object('ok',true,'rows',v_rows,'lastContactAt',(select max(a.occurred_at) from public.crm_activities a where a.agency_id=ctx.agency_id and a.job_id=p_job_id and a.candidate_id=p_candidate_id and a.activity_type<>'NOTE'));
end;$$;

create or replace function public.xzrecruiter_staffing_analytics(p_token text,p_from timestamptz default null,p_to timestamptz default null,p_client uuid default null,p_recruiter uuid default null,p_account_manager uuid default null)
returns jsonb language plpgsql stable security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_from timestamptz; v_to timestamptz; v_rows jsonb; v_timing jsonb;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if not private.xzrecruiter_has_permission(v_role,'commercial:view') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 v_to:=coalesce(p_to,now());v_from:=coalesce(p_from,v_to-interval '30 days');
 if v_from>=v_to or v_from<v_to-interval '366 days' then return jsonb_build_object('ok',false,'error','invalid_date_range'); end if;
 select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_rows from (
 select p.client_id,c.name client_name,p.recruiter_user_id,u.display_name recruiter_name,p.fee_currency currency,
 count(*) placement_count,count(*) filter(where p.placement_fee is null or p.fee_currency is null) unpriced_count,
 sum(p.placement_fee) filter(where p.status='PLANNED' and p.fee_currency is not null) expected_revenue,
 sum(p.placement_fee) filter(where p.status in ('STARTED','COMPLETED') and p.fee_currency is not null) achieved_revenue
 from public.placements p join public.recruitment_jobs j on j.id=p.job_id and j.agency_id=ctx.agency_id
 left join public.recruitment_clients c on c.id=p.client_id and c.agency_id=ctx.agency_id left join public.users u on u.id=p.recruiter_user_id
 where p.agency_id=ctx.agency_id and p.status<>'CANCELLED' and p.created_at>=v_from and p.created_at<v_to
 and (p_client is null or p.client_id=p_client) and (p_recruiter is null or p.recruiter_user_id=p_recruiter) and (p_account_manager is null or j.owner_user_id=p_account_manager)
 group by p.client_id,c.name,p.recruiter_user_id,u.display_name,p.fee_currency order by c.name,u.display_name,p.fee_currency limit 500) r;
 with cohort as (
 select j.id,j.created_at,(select min(s.client_submitted_at) from public.candidate_submissions s where s.agency_id=ctx.agency_id and s.job_id=j.id and s.workflow_status='CLIENT_SUBMITTED' and (p_recruiter is null or s.created_by_user_id=p_recruiter)) first_submission,
 (select min(p.start_date)::timestamptz from public.placements p where p.agency_id=ctx.agency_id and p.job_id=j.id and p.status in ('STARTED','COMPLETED') and (p_recruiter is null or p.recruiter_user_id=p_recruiter)) first_join
 from public.recruitment_jobs j where j.agency_id=ctx.agency_id and j.archived_at is null and j.created_at>=v_from and j.created_at<v_to and (p_client is null or j.client_id=p_client) and (p_account_manager is null or j.owner_user_id=p_account_manager)
 ) select jsonb_build_object('requirements',count(*),'submittedRequirements',count(first_submission),'filledRequirements',count(first_join),
 'averageTimeToSubmitHours',avg(extract(epoch from first_submission-created_at)/3600) filter(where first_submission>=created_at),
 'averageTimeToFillDays',avg(extract(epoch from first_join-created_at)/86400) filter(where first_join>=created_at)) into v_timing from cohort;
 return jsonb_build_object('ok',true,'revenue',v_rows,'timing',v_timing,'from',v_from,'to',v_to,'basis','Placement creation cohort; achieved means started/completed, not cash collected; currencies are never combined.','bounded',true);
end;$$;

revoke all on function public.xzrecruiter_set_account_parent(text,uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.xzrecruiter_set_account_parent(text,uuid,uuid,timestamptz) to anon,authenticated;
revoke all on function public.xzrecruiter_transfer_candidate_owner(text,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_transfer_candidate_owner(text,uuid,uuid,uuid,text) to anon,authenticated;
revoke all on function public.xzrecruiter_requirement_commercial(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.xzrecruiter_requirement_commercial(text,uuid,jsonb) to anon,authenticated;
revoke all on function public.xzrecruiter_communication_timeline(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.xzrecruiter_communication_timeline(text,uuid,uuid,jsonb) to anon,authenticated;
revoke all on function public.xzrecruiter_staffing_analytics(text,timestamptz,timestamptz,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_staffing_analytics(text,timestamptz,timestamptz,uuid,uuid,uuid) to anon,authenticated;

create or replace function public.xzrecruiter_client_staffing_context(p_token text,p_client_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_client record;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if v_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 select * into v_client from public.recruitment_clients where agency_id=ctx.agency_id and id=p_client_id and archived_at is null;
 if not found then return jsonb_build_object('ok',false,'error','client_not_found'); end if;
 return jsonb_build_object('ok',true,'parentClientId',v_client.parent_client_id,'updatedAt',v_client.updated_at,'canEditAccount',private.xzrecruiter_has_permission(v_role,'commercial:edit'),
 'parentChoices',(select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from (select id,name from public.recruitment_clients where agency_id=ctx.agency_id and id<>p_client_id and parent_client_id is null and archived_at is null order by name limit 200)c),
 'accounts',(select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from (select id,name from public.recruitment_clients where agency_id=ctx.agency_id and parent_client_id=p_client_id and archived_at is null order by name limit 200)c),
 'submissions',(select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from (select s.id,s.workflow_status,s.am_review_status,s.client_submitted_at,c.full_name candidate_name,j.title job_title from public.candidate_submissions s join public.candidates c on c.id=s.candidate_id and c.agency_id=ctx.agency_id join public.recruitment_jobs j on j.id=s.job_id and j.agency_id=ctx.agency_id where s.agency_id=ctx.agency_id and s.client_id=p_client_id order by s.created_at desc limit 100)s),
 'interviews',(select coalesce(jsonb_agg(to_jsonb(i)),'[]'::jsonb) from (select i.id,i.scheduled_at,i.status,c.full_name candidate_name,j.title job_title from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=ctx.agency_id join public.candidates c on c.id=a.candidate_id and c.agency_id=ctx.agency_id join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=ctx.agency_id where i.agency_id=ctx.agency_id and j.client_id=p_client_id order by i.scheduled_at desc limit 100)i));
end;$$;
revoke all on function public.xzrecruiter_client_staffing_context(text,uuid) from public,anon,authenticated;
grant execute on function public.xzrecruiter_client_staffing_context(text,uuid) to anon,authenticated;

-- Enrich the existing board with canonical facts; this adds no new transition endpoint.
create or replace function public.xzrecruiter_staffing_stage_facts(p_token text,p_application_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_rows jsonb;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if coalesce(cardinality(p_application_ids),0)>100 then return jsonb_build_object('ok',false,'error','too_many_applications'); end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_rows from (
 select a.id,coalesce(to_jsonb(a)->>'candidacy_state',a.stage) candidacy_state,s.workflow_status,s.am_review_status,s.client_viewed_at,s.status submission_status,
 (select p.status from public.placements p where p.agency_id=ctx.agency_id and p.application_id=a.id and p.status<>'CANCELLED' order by p.created_at desc nulls last limit 1) placement_status,
 (select max(ss.completed_at) from public.application_screening_sessions ss where ss.application_id=a.id and ss.agency_id=ctx.agency_id) screening_completed_at
 from public.applications a left join lateral(select * from public.candidate_submissions sub where sub.agency_id=ctx.agency_id and sub.application_id=a.id order by sub.created_at desc limit 1)s on true
 where a.id=any(p_application_ids) and a.agency_id=ctx.agency_id and a.archived_at is null
 and private.xzrecruiter_recruiter_job_access(ctx.agency_id,ctx.user_id,v_role,a.job_id)
 and (v_role<>'RECRUITER' or a.owner_user_id=ctx.user_id))x;
 return jsonb_build_object('ok',true,'rows',v_rows);
end;$$;
revoke all on function public.xzrecruiter_staffing_stage_facts(text,uuid[]) from public,anon,authenticated;
grant execute on function public.xzrecruiter_staffing_stage_facts(text,uuid[]) to anon,authenticated;


create or replace function public.xzrecruiter_candidate_profile_context_step3_legacy(
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
    'salaryPeriod',c.salary_period,'salaryExpected',c.salary_expected,'salaryCurrency',c.salary_currency,'noticePeriodDays',c.notice_period_days,
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
create or replace function public.xzrecruiter_update_candidate_profile_step3_legacy(
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

  if p_profile ? 'salaryPeriod' and coalesce(p_profile->>'salaryPeriod','') not in ('','HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL') then return jsonb_build_object('ok',false,'error','invalid_salary_period'); end if;
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
    salary_period=case when p_profile ? 'salaryPeriod' then nullif(p_profile->>'salaryPeriod','') else salary_period end,
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
revoke all on function public.xzrecruiter_candidate_profile_context_step3_legacy(text,uuid) from public,anon,authenticated;
revoke all on function public.xzrecruiter_update_candidate_profile_step3_legacy(text,uuid,jsonb) from public,anon,authenticated;

alter table public.recruitment_jobs add column if not exists rediscovery_result jsonb;
create or replace function private.xzrecruiter_requirement_rediscovery()
returns trigger language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare result jsonb;
begin
 if new.recruiter_ready=true and new.approved_hiring_brief_id is not null then
   result:=private.xzrecruiter_talent_match_candidates(new.agency_id,new.id,null,'RECRUITER','',30);
   update public.recruitment_jobs set rediscovery_result=jsonb_build_object('briefId',new.approved_hiring_brief_id,'searchedAt',now(),'candidateIds',(select coalesce(jsonb_agg(row->'id'),'[]'::jsonb) from jsonb_array_elements(coalesce(result->'rows','[]'::jsonb)) row),'automatic',true) where id=new.id and agency_id=new.agency_id;
 end if;
 return new;
end;$$;
revoke all on function private.xzrecruiter_requirement_rediscovery() from public,anon,authenticated;
create trigger xzr_requirement_rediscovery after insert or update of approved_hiring_brief_id,recruiter_ready on public.recruitment_jobs for each row execute function private.xzrecruiter_requirement_rediscovery();



create or replace function private.xzrecruiter_phone_identity(v text) returns text language sql immutable security invoker set search_path='pg_temp' as $$select regexp_replace(regexp_replace(coalesce(v,''),'[^0-9]','','g'),'^00','')$$;
create or replace function private.xzrecruiter_profile_identity(v text) returns text language sql immutable security invoker set search_path='pg_temp' as $$select regexp_replace(regexp_replace(regexp_replace(regexp_replace(lower(btrim(coalesce(v,''))),'^https?://',''),'^(www\.|[a-z]{2}\.)?linkedin\.com/','linkedin.com/'),'[?#].*$',''),'/+$','')$$;
revoke all on function private.xzrecruiter_phone_identity(text) from public,anon,authenticated;
revoke all on function private.xzrecruiter_profile_identity(text) from public,anon,authenticated;
create index if not exists idx_xzr_candidate_phone_identity on public.candidates(agency_id,private.xzrecruiter_phone_identity(phone));

create or replace function public.xzrecruiter_complete_candidate_intelligence(
  p_token text,p_run_id uuid,p_profile_json jsonb,p_profile_hash text,p_source_fingerprint text,
  p_match_json jsonb,p_ai_meta jsonb,p_latency_ms integer,p_error_code text default null,p_error_detail text default null
) returns jsonb
language plpgsql security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_run record;
  v_candidate_updated timestamptz;v_parse_updated timestamptz;v_current_brief uuid;v_current_fingerprint text;
  v_scoring jsonb;v_profile uuid;v_profile_version integer;v_doc uuid;v_match uuid;v_profile_status text;
  v_email text;v_phone text;v_name text;v_company text;v_location text;v_source_ref text;v_checksum text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);

  select * into v_run
  from public.candidate_intelligence_jobs
  where id=p_run_id and agency_id=v_agency
  for update;
  if v_run.id is null then return jsonb_build_object('ok',false,'error','intelligence_job_not_found'); end if;
  if not private.xzrecruiter_candidate_intelligence_access(v_agency,v_user,v_business_role,v_run.job_id,v_run.candidate_id) then
    return jsonb_build_object('ok',false,'error','candidate_intelligence_forbidden');
  end if;

  if nullif(coalesce(p_error_code,''),'') is not null then
    update public.candidate_intelligence_jobs
    set run_status='FAILED',model_resolved=nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
        provider_response_id=nullif(left(coalesce(p_ai_meta->>'providerResponseId',''),200),''),
        provider_usage=coalesce(p_ai_meta->'usage','{}'::jsonb),latency_ms=greatest(coalesce(p_latency_ms,0),0),
        error_code=left(p_error_code,120),error_detail=left(coalesce(p_error_detail,'AI execution failed; retry is safe.'),1000),
        completed_at=now()
    where id=p_run_id and agency_id=v_agency;
    return jsonb_build_object('ok',false,'error',left(p_error_code,120),'retry_safe',true);
  end if;

  select c.updated_at into v_candidate_updated
  from public.candidates c where c.id=v_run.candidate_id and c.agency_id=v_agency;

  if v_run.parse_run_id is not null then
    select pr.updated_at,d.id into v_parse_updated,v_doc
    from public.candidate_parse_runs pr
    left join public.candidate_documents d on d.id=pr.document_id and d.agency_id=v_agency
    where pr.id=v_run.parse_run_id and pr.agency_id=v_agency;
  end if;

  select j.approved_hiring_brief_id,hb.source_fingerprint
  into v_current_brief,v_current_fingerprint
  from public.recruitment_jobs j
  join public.requirement_hiring_briefs hb on hb.id=j.approved_hiring_brief_id and hb.agency_id=v_agency
  where j.id=v_run.job_id and j.agency_id=v_agency and j.recruiter_ready=true and hb.brief_status='APPROVED';

  v_scoring:=private.xzrecruiter_candidate_scoring_config(v_agency);

  if v_candidate_updated is distinct from v_run.candidate_updated_at_snapshot
     or v_current_brief is distinct from v_run.brief_id
     or coalesce(v_current_fingerprint,'') is distinct from coalesce(v_run.brief_source_fingerprint,'')
     or (v_run.parse_run_id is not null and v_parse_updated is distinct from v_run.parse_run_updated_at_snapshot)
     or coalesce(v_scoring->>'version','') is distinct from coalesce(v_run.scoring_version,'') then
    update public.candidate_intelligence_jobs
    set run_status='FAILED',error_code='stale_input_during_analysis',
        error_detail='Candidate, resume, approved requirement or scoring configuration changed during analysis. Recompute from fresh inputs.',
        latency_ms=greatest(coalesce(p_latency_ms,0),0),completed_at=now()
    where id=p_run_id and agency_id=v_agency;
    return jsonb_build_object('ok',false,'error','stale_input_during_analysis','recompute_required',true);
  end if;

  if nullif(btrim(coalesce(p_profile_hash,'')),'') is null then
    return jsonb_build_object('ok',false,'error','profile_hash_required');
  end if;

  select id,version_number into v_profile,v_profile_version
  from public.candidate_profile_versions
  where agency_id=v_agency and candidate_id=v_run.candidate_id and profile_hash=p_profile_hash
  limit 1;

  if v_profile is null then
    select coalesce(max(version_number),0)+1 into v_profile_version
    from public.candidate_profile_versions
    where agency_id=v_agency and candidate_id=v_run.candidate_id;

    update public.candidate_profile_versions
    set is_current=false,profile_status=case when profile_status='FAILED' then profile_status else 'SUPERSEDED' end
    where agency_id=v_agency and candidate_id=v_run.candidate_id and is_current=true;

    v_profile:=gen_random_uuid();
    v_profile_status:=case
      when jsonb_array_length(coalesce(p_profile_json#>'{signals,missingCriticalInformation}','[]'::jsonb))>0 then 'PARTIAL'
      else 'READY'
    end;

    insert into public.candidate_profile_versions(
      id,agency_id,candidate_id,document_id,parse_run_id,version_number,profile_status,profile_json,profile_hash,
      source_fingerprint,parser_version,model_name,prompt_version,schema_version,profile_schema_version,input_hash,is_current,created_by_user_id
    )
    select
      v_profile,v_agency,v_run.candidate_id,v_doc,v_run.parse_run_id,v_profile_version,v_profile_status,coalesce(p_profile_json,'{}'::jsonb),
      left(p_profile_hash,128),left(coalesce(p_source_fingerprint,v_run.input_hash),128),
      pr.parser_version,nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
      left(v_run.prompt_version,120),left(v_run.schema_version,120),'xz-candidate-profile-v2',left(v_run.input_hash,128),true,v_user
    from (select 1) one
    left join public.candidate_parse_runs pr on pr.id=v_run.parse_run_id and pr.agency_id=v_agency;

    insert into public.candidate_profile_skills(
      agency_id,candidate_id,profile_version_id,original_value,normalized_value,confidence,estimated_years,evidence
    )
    select v_agency,v_run.candidate_id,v_profile,s->>'original',s->>'normalized',
      greatest(0,least(1,coalesce(nullif(s->>'confidence','')::numeric,0))),
      nullif(s->>'estimatedYears','')::numeric,coalesce(s->'evidence','[]'::jsonb)
    from jsonb_array_elements(coalesce(p_profile_json->'skills','[]'::jsonb)) s
    where nullif(btrim(coalesce(s->>'normalized','')),'') is not null
    on conflict(profile_version_id,normalized_value) do nothing;

    update public.candidates
    set current_intelligence_profile_id=v_profile
    where id=v_run.candidate_id and agency_id=v_agency;
  else
    update public.candidate_profile_versions set is_current=(id=v_profile)
    where agency_id=v_agency and candidate_id=v_run.candidate_id;
    update public.candidates set current_intelligence_profile_id=v_profile
    where id=v_run.candidate_id and agency_id=v_agency;
  end if;

  update public.candidate_match_runs
  set run_status='STALE',stale_at=now(),stale_reason=case
    when brief_id<>v_run.brief_id then 'APPROVED_REQUIREMENT_CHANGED'
    when profile_version_id<>v_profile then 'CANDIDATE_PROFILE_CHANGED'
    when scoring_version<>v_run.scoring_version then 'SCORING_CONFIG_CHANGED'
    else 'RECOMPUTED'
  end
  where agency_id=v_agency and application_id=v_run.application_id and run_status='SUCCEEDED';

  v_match:=gen_random_uuid();
  insert into public.candidate_match_runs(
    id,agency_id,job_id,candidate_id,application_id,intelligence_job_id,brief_id,brief_version,profile_version_id,
    scoring_config_id,scoring_version,model_name,prompt_version,schema_version,match_schema_version,input_hash,run_status,score,match_band,
    confidence,coverage,hard_rule_status,component_scores,hard_rule_results,requirement_results,strengths,gaps,uncertainties,evidence_meta,
    recommendation
  )
  select
    v_match,v_agency,v_run.job_id,v_run.candidate_id,v_run.application_id,v_run.id,v_run.brief_id,hb.version_number,v_profile,
    nullif(v_scoring->>'id','')::uuid,v_run.scoring_version,nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
    v_run.prompt_version,v_run.schema_version,'xz-candidate-match-v2',v_run.input_hash,'SUCCEEDED',
    nullif(p_match_json->>'score','')::numeric,nullif(p_match_json->>'band',''),
    nullif(p_match_json->>'confidence','')::numeric,nullif(p_match_json->>'coverage','')::numeric,
    nullif(p_match_json->>'hardRuleStatus',''),coalesce(p_match_json->'components','{}'::jsonb),
    coalesce(p_match_json->'hardRules','[]'::jsonb),coalesce(p_match_json->'requirementResults','[]'::jsonb),coalesce(p_match_json->'strengths','[]'::jsonb),
    coalesce(p_match_json->'gaps','[]'::jsonb),coalesce(p_match_json->'uncertainties','[]'::jsonb),
    coalesce(p_match_json->'evidenceMeta','{}'::jsonb),nullif(p_match_json->>'recommendation','')
  from public.requirement_hiring_briefs hb
  where hb.id=v_run.brief_id and hb.agency_id=v_agency;

  update public.applications
  set current_candidate_match_id=v_match,intelligence_review_state='NOT_REVIEWED',intelligence_reviewed_at=null,updated_at=now()
  where id=v_run.application_id and agency_id=v_agency;

  -- Explainable duplicate scan. Same-tenant only. Never auto-merges.
  v_email:=lower(coalesce(p_profile_json#>>'{identity,email,normalized}',''));
  v_phone:=private.xzrecruiter_phone_identity(p_profile_json#>>'{identity,phone,normalized}');
  v_name:=lower(coalesce(p_profile_json#>>'{identity,name,normalized}',''));
  v_company:=lower(coalesce(p_profile_json#>>'{professional,currentCompany,normalized}',''));
  v_location:=lower(coalesce(p_profile_json#>>'{identity,location,normalized}',''));
  select private.xzrecruiter_profile_identity(a.source_reference) into v_source_ref
  from public.applications a where a.id=v_run.application_id and a.agency_id=v_agency;
  select d.checksum into v_checksum from public.candidate_documents d where d.id=v_doc and d.agency_id=v_agency;

  delete from public.candidate_duplicate_signals
  where agency_id=v_agency and profile_version_id=v_profile;

  insert into public.candidate_duplicate_signals(
    agency_id,candidate_id,compared_candidate_id,profile_version_id,duplicate_status,score,signals,algorithm_version
  )
  select v_agency,v_run.candidate_id,x.id,v_profile,
    case
      when x.exact_email or x.exact_phone or x.exact_resume or x.exact_source then 'exact_duplicate'
      when x.name_company and x.name_location then 'likely_duplicate'
      else 'possible_duplicate'
    end,
    case
      when x.exact_email or x.exact_phone or x.exact_resume or x.exact_source then 100
      when x.name_company and x.name_location then 80
      when x.name_company then 45 else 35
    end,
    jsonb_build_object(
      'exactEmail',x.exact_email,'exactPhone',x.exact_phone,'exactResume',x.exact_resume,'exactSourceReference',x.exact_source,
      'nameEmployer',x.name_company,'nameLocation',x.name_location
    ),
    'xz-duplicate-agency-v2'
  from (
    select c.id,
      (v_email<>'' and lower(btrim(coalesce(c.email,'')))=v_email) exact_email,
      (v_phone<>'' and private.xzrecruiter_phone_identity(c.phone)=v_phone) exact_phone,
      (v_name<>'' and lower(btrim(coalesce(c.full_name,'')))=v_name and v_company<>'' and lower(btrim(coalesce(c.current_company,'')))=v_company) name_company,
      (v_name<>'' and lower(coalesce(c.full_name,''))=v_name and v_location<>'' and lower(trim(concat_ws(', ',c.city,c.region,c.country_code)))=v_location) name_location,
      (v_checksum is not null and exists(
        select 1 from public.candidate_documents d2
        where d2.agency_id=v_agency and d2.candidate_id=c.id and d2.archived_at is null and d2.checksum=v_checksum
      )) exact_resume,
      (v_source_ref<>'' and exists(
        select 1 from public.applications a2
        where a2.agency_id=v_agency and a2.candidate_id=c.id and a2.archived_at is null
          and private.xzrecruiter_profile_identity(a2.source_reference)=v_source_ref
      )) exact_source
    from public.candidates c
    where c.agency_id=v_agency and c.id<>v_run.candidate_id and c.archived_at is null and c.merged_into_candidate_id is null
  ) x
  where x.exact_email or x.exact_phone or x.exact_resume or x.exact_source or x.name_company or x.name_location;

  update public.candidate_intelligence_jobs
  set run_status='SUCCEEDED',model_resolved=nullif(left(coalesce(p_ai_meta->>'model',''),120),''),
      provider_response_id=nullif(left(coalesce(p_ai_meta->>'providerResponseId',''),200),''),
      provider_usage=coalesce(p_ai_meta->'usage','{}'::jsonb),latency_ms=greatest(coalesce(p_latency_ms,0),0),
      error_code=null,error_detail=null,completed_at=now()
  where id=p_run_id and agency_id=v_agency;

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_run.application_id,'candidate.intelligence_generated','Candidate intelligence generated',
    jsonb_build_object('candidate_id',v_run.candidate_id,'job_id',v_run.job_id,'match_id',v_match,'profile_version_id',v_profile,
      'brief_id',v_run.brief_id,'score',p_match_json->'score','band',p_match_json->'band','hard_rule_status',p_match_json->'hardRuleStatus')
  );
  return jsonb_build_object('ok',true,'match_id',v_match,'profile_version_id',v_profile,'profile_version',v_profile_version,'run_id',p_run_id);
exception when unique_violation then
  return jsonb_build_object('ok',false,'error','candidate_intelligence_concurrent_conflict','retry_safe',true);
end;
$fn$;
create or replace function public.xzrecruiter_recruiter_intake_candidate(
  p_token text,p_job_id uuid,p_candidate jsonb,p_source_type text,p_source_reference text default null,
  p_sourcing_notes text default null,p_idempotency_key text default null
) returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;v_source text:=upper(coalesce(p_source_type,''));
  v_candidate uuid;v_existing uuid;v_app uuid;v_name text;v_email text;v_phone text;v_pipeline uuid;v_stage uuid;v_stage_name text;v_client uuid;
  v_reused boolean:=false;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER') then
    return jsonb_build_object('ok',false,'error','recruiter_intake_forbidden');
  end if;
  if not private.xzrecruiter_recruiter_job_access(v_agency,v_user,v_business_role,p_job_id) then
    return jsonb_build_object('ok',false,'error','requirement_access_forbidden');
  end if;
  if not exists(
    select 1 from public.recruitment_jobs
    where id=p_job_id and agency_id=v_agency and archived_at is null
      and recruiter_ready=true and approved_hiring_brief_id is not null and status<>'CANCELLED'
  ) then return jsonb_build_object('ok',false,'error','approved_requirement_required'); end if;
  if v_source not in ('LINKEDIN','MONSTER','DICE','INDEED','NAUKRI','INTERNAL_DATABASE','REFERRAL','APPLICANT','CSV','OTHER') then
    return jsonb_build_object('ok',false,'error','invalid_source_type');
  end if;

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is not null then
    select a.id,a.candidate_id into v_app,v_candidate
    from public.applications a
    where a.agency_id=v_agency and a.intake_idempotency_key=p_idempotency_key
    limit 1;
    if v_app is not null then
      return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',true,'idempotent',true);
    end if;
  end if;

  if nullif(p_candidate->>'id','') is not null then
    v_candidate:=(p_candidate->>'id')::uuid;
    if not exists(
      select 1 from public.candidates c
      where c.id=v_candidate and c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
        and (
          v_business_role<>'RECRUITER'
          or c.owner_user_id=v_user
          or exists(
            select 1 from public.applications a
            join public.requirement_recruiter_assignments ra on ra.job_id=a.job_id and ra.agency_id=v_agency
            where a.agency_id=v_agency and a.candidate_id=c.id and a.archived_at is null
              and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
          )
        )
    ) then return jsonb_build_object('ok',false,'error','candidate_access_forbidden'); end if;
    v_reused:=true;
  else
    v_name:=btrim(coalesce(p_candidate->>'fullName',''));
    v_email:=nullif(lower(btrim(coalesce(p_candidate->>'email',''))),'');
    v_phone:=nullif(regexp_replace(coalesce(p_candidate->>'phone',''),'[^0-9+]','','g'),'');
    if v_name='' or (v_email is null and v_phone is null) then
      return jsonb_build_object('ok',false,'error','name_and_contact_required');
    end if;

    -- Serialize identity checks; concurrent intakes cannot create parallel contact records.
    perform pg_advisory_xact_lock(hashtextextended(v_agency::text||'|CANDIDATE_INTAKE',0));
    select c.id into v_existing
    from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and ((v_email is not null and lower(c.email)=v_email) or (v_phone is not null and private.xzrecruiter_phone_identity(c.phone)=private.xzrecruiter_phone_identity(v_phone)) or (nullif(p_source_reference,'') is not null and exists(select 1 from public.applications old where old.agency_id=v_agency and old.candidate_id=c.id and private.xzrecruiter_profile_identity(old.source_reference)=private.xzrecruiter_profile_identity(p_source_reference))))
    order by c.updated_at desc limit 1;

    if v_existing is not null then
      if v_business_role='RECRUITER' and not exists(
        select 1 from public.candidates c
        where c.id=v_existing and c.agency_id=v_agency
          and (
            c.owner_user_id=v_user
            or exists(
              select 1 from public.applications a
              join public.requirement_recruiter_assignments ra on ra.job_id=a.job_id and ra.agency_id=v_agency
              where a.agency_id=v_agency and a.candidate_id=c.id and a.archived_at is null
                and ra.recruiter_user_id=v_user and ra.assignment_status='ACTIVE'
            )
          )
      ) then return jsonb_build_object('ok',false,'error','duplicate_requires_manager'); end if;
      v_candidate:=v_existing;v_reused:=true;
    else
      v_candidate:=gen_random_uuid();
      insert into public.candidates(
        id,agency_id,full_name,email,phone,current_title,current_company,source,dedupe_key,
        created_by_user_id,owner_user_id,consent_status,updated_by_user_id
      ) values(
        v_candidate,v_agency,v_name,v_email,v_phone,nullif(p_candidate->>'currentTitle',''),
        nullif(p_candidate->>'currentCompany',''),v_source,
        encode(extensions.digest(lower(v_name)||'|'||coalesce(v_email,'')||'|'||coalesce(v_phone,''),'sha256'),'hex'),
        v_user,v_user,'UNKNOWN',v_user
      );
      perform private.xzrecruiter_log_activity(
        v_agency,v_user,'candidate',v_candidate,'candidate.sourced','Candidate sourced',
        jsonb_build_object('source_type',v_source,'source_reference',left(coalesce(p_source_reference,''),500),'job_id',p_job_id)
      );
    end if;
  end if;

  select a.id into v_app
  from public.applications a
  where a.agency_id=v_agency and a.job_id=p_job_id and a.candidate_id=v_candidate and a.archived_at is null
  limit 1;
  if v_app is not null then
    return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',true,'already_associated',true);
  end if;

  select pipeline_id,client_id into v_pipeline,v_client
  from public.recruitment_jobs
  where id=p_job_id and agency_id=v_agency and archived_at is null;
  if v_pipeline is null then
    select id into v_pipeline
    from public.recruitment_pipelines
    where agency_id=v_agency and pipeline_kind='RECRUITMENT' and is_default=true and active=true
    limit 1;
  end if;
  select id,name into v_stage,v_stage_name
  from public.pipeline_stages
  where agency_id=v_agency and pipeline_id=v_pipeline and code in ('SOURCED','APPLIED','NEW')
  order by case code when 'SOURCED' then 0 when 'APPLIED' then 1 else 2 end
  limit 1;

  v_app:=gen_random_uuid();
  insert into public.applications(
    id,agency_id,job_id,candidate_id,stage,status,match_evidence,owner_user_id,created_by_user_id,
    client_id,pipeline_id,stage_id,stage_entered_at,last_activity_at,source_type,source_reference,
    sourcing_notes,sourced_by_user_id,sourced_at,intake_idempotency_key
  ) values(
    v_app,v_agency,p_job_id,v_candidate,coalesce(v_stage_name,'Sourced'),'ACTIVE','{}'::jsonb,v_user,v_user,
    v_client,v_pipeline,v_stage,now(),now(),v_source,nullif(left(coalesce(p_source_reference,''),1000),''),
    nullif(left(coalesce(p_sourcing_notes,''),2000),''),v_user,now(),
    nullif(left(coalesce(p_idempotency_key,''),160),'')
  );
  insert into public.application_stage_history(
    agency_id,application_id,to_stage_id,to_stage,changed_by_user_id
  ) values(v_agency,v_app,v_stage,coalesce(v_stage_name,'Sourced'),v_user);

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'application',v_app,'candidate.associated_with_requirement','Sourced candidate associated with requirement',
    jsonb_build_object(
      'candidate_id',v_candidate,'job_id',p_job_id,'source_type',v_source,
      'source_reference',left(coalesce(p_source_reference,''),500),'candidate_reused',v_reused
    )
  );
  return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',v_reused,'already_associated',false);
exception
  when unique_violation then
    select a.id,a.candidate_id into v_app,v_candidate
    from public.applications a
    where a.agency_id=v_agency
      and (
        a.intake_idempotency_key=p_idempotency_key
        or (a.job_id=p_job_id and a.candidate_id=v_candidate and a.archived_at is null)
      )
    order by a.created_at desc limit 1;
    if v_app is not null then return jsonb_build_object('ok',true,'application_id',v_app,'candidate_id',v_candidate,'reused',true,'idempotent',true); end if;
    return jsonb_build_object('ok',false,'error','candidate_intake_conflict');
end;
$fn$;
revoke all on function public.xzrecruiter_complete_candidate_intelligence(text,uuid,jsonb,text,text,jsonb,jsonb,integer,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_complete_candidate_intelligence(text,uuid,jsonb,text,text,jsonb,jsonb,integer,text,text) to anon,authenticated;
revoke all on function public.xzrecruiter_recruiter_intake_candidate(text,uuid,jsonb,text,text,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_recruiter_intake_candidate(text,uuid,jsonb,text,text,text,text) to anon,authenticated;

create or replace function private.xzrecruiter_step6_configuration(
  p_agency uuid,p_job uuid
) returns jsonb
language plpgsql stable security invoker
set search_path='public','private','pg_temp'
as $fn$
declare v_job jsonb;v_meta jsonb;v_cfg jsonb;
begin
  select to_jsonb(j) into v_job from public.recruitment_jobs j where j.agency_id=p_agency and j.id=p_job;
  v_meta:=coalesce(v_job->'metadata','{}'::jsonb);
  v_cfg:=coalesce(nullif(nullif(v_job->'submission_config','null'::jsonb),'{}'::jsonb),v_meta->'submissionConfig',v_meta->'submission_requirements','{}'::jsonb);
  return jsonb_build_object(
    'requiredFields',coalesce(v_cfg->'requiredFields',v_cfg->'required_fields','[]'::jsonb),
    'requireLatestResume',coalesce((v_cfg->>'requireLatestResume')::boolean,(v_cfg->>'require_latest_resume')::boolean,true),
    'requireCompliance',coalesce((v_cfg->>'requireCompliance')::boolean,(v_cfg->>'require_compliance')::boolean,false),
    'includeCandidateCompensationForClient',coalesce((v_cfg->>'includeCandidateCompensationForClient')::boolean,false),
    'raw',v_cfg
  );
exception when invalid_text_representation then
  return jsonb_build_object('requiredFields','[]'::jsonb,'requireLatestResume',true,'requireCompliance',false,'includeCandidateCompensationForClient',false,'raw','{}'::jsonb);
end;
$fn$;

revoke all on function private.xzrecruiter_step6_configuration(uuid,uuid) from public,anon,authenticated;
-- Extend the existing placement record; accepted-offer gate and creation audit remain intact.
create or replace function public.xzrecruiter_create_placement(p_token text,p_placement jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $fn$
declare
  v_agency uuid;v_user uuid;v_membership_role text;v_business_role text;
  v_recruiter uuid;v_id uuid;v_app uuid;v_candidate uuid;v_job uuid;v_client uuid;v_offer uuid;
begin
  select agency_id,user_id,role into v_agency,v_user,v_membership_role
  from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  v_business_role:=private.xzrecruiter_business_role(v_agency,v_user,v_membership_role);
  if v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER') then
    return jsonb_build_object('ok',false,'error','joining_role_forbidden');
  end if;

  v_app:=nullif(p_placement->>'applicationId','')::uuid;
  select candidate_id,job_id,client_id,owner_user_id into v_candidate,v_job,v_client,v_recruiter
  from public.applications
  where id=v_app and agency_id=v_agency and archived_at is null;
  if not found then return jsonb_build_object('ok',false,'error','application_not_found'); end if;

  begin v_offer:=nullif(p_placement->>'offerId','')::uuid; exception when invalid_text_representation then v_offer:=null; end;
  if v_offer is null then
    select id into v_offer
    from public.offers
    where agency_id=v_agency and application_id=v_app and status='ACCEPTED'
    order by accepted_at desc nulls last,created_at desc limit 1;
  end if;
  if v_offer is null or not exists(
    select 1 from public.offers
    where id=v_offer and agency_id=v_agency and application_id=v_app and status='ACCEPTED'
  ) then
    return jsonb_build_object('ok',false,'error','accepted_offer_required');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_agency::text||':placement:'||v_app::text,0));
  if exists(
    select 1 from public.placements
    where agency_id=v_agency and application_id=v_app and status not in ('CANCELLED')
  ) then
    return jsonb_build_object('ok',false,'error','placement_exists');
  end if;

  v_id:=gen_random_uuid();
  insert into public.placements(
    id,agency_id,application_id,offer_id,placement_fee,fee_currency,start_date,
    created_by_user_id,candidate_id,job_id,client_id,recruiter_user_id,salary,
    salary_currency,status,fee_type,fee_percent,guarantee_end_date,commission_amount
  ) values(
    v_id,v_agency,v_app,v_offer,nullif(p_placement->>'placementFee','')::numeric,
    nullif(upper(p_placement->>'feeCurrency'),''),nullif(p_placement->>'startDate','')::date,
    v_user,v_candidate,v_job,v_client,v_recruiter,nullif(p_placement->>'salary','')::numeric,
    nullif(upper(p_placement->>'salaryCurrency'),''),'PLANNED',
    nullif(p_placement->>'feeType',''),nullif(p_placement->>'feePercent','')::numeric,
    nullif(p_placement->>'guaranteeEndDate','')::date,
    nullif(p_placement->>'commissionAmount','')::numeric
  );

  perform private.xzrecruiter_log_activity(
    v_agency,v_user,'placement',v_id,'joining.started','Pre-joining record created',
    jsonb_build_object('application_id',v_app,'offer_id',v_offer,'business_role',v_business_role)
  );
  return jsonb_build_object('ok',true,'id',v_id);
end;
$fn$;


revoke all on function public.xzrecruiter_create_placement(text,jsonb) from public,anon,authenticated;
grant execute on function public.xzrecruiter_create_placement(text,jsonb) to anon,authenticated;
create or replace function public.xzrecruiter_placement_status(p_token text,p_id uuid,p_expected_status text,p_status text,p_reason text)
returns jsonb language plpgsql security definer set search_path='public','private','pg_temp' as $$
declare ctx record; v_role text; v_row public.placements%rowtype;
begin
 select * into ctx from private.xzrecruiter_session_context(p_token);
 if ctx.agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 v_role:=private.xzrecruiter_business_role(ctx.agency_id,ctx.user_id,ctx.role);
 if v_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER','RECRUITMENT_MANAGER') then return jsonb_build_object('ok',false,'error','joining_role_forbidden'); end if;
 select * into v_row from public.placements where id=p_id and agency_id=ctx.agency_id for update;
 if not found then return jsonb_build_object('ok',false,'error','placement_not_found'); end if;
 if not private.xzrecruiter_recruiter_job_access(ctx.agency_id,ctx.user_id,v_role,v_row.job_id) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if v_row.status is distinct from p_expected_status then return jsonb_build_object('ok',false,'error','stale_placement'); end if;
 if not ((v_row.status='PLANNED' and p_status in ('STARTED','CANCELLED')) or (v_row.status='STARTED' and p_status in ('COMPLETED','CANCELLED'))) then return jsonb_build_object('ok',false,'error','invalid_placement_transition'); end if;
 if length(trim(coalesce(p_reason,'')))<5 or length(p_reason)>1500 then return jsonb_build_object('ok',false,'error','reason_required'); end if;
 if p_status='STARTED' then
  if v_row.start_date is null or v_row.start_date>current_date then return jsonb_build_object('ok',false,'error','joining_date_not_reached'); end if;
  if not exists(select 1 from public.offers o where o.id=v_row.offer_id and o.agency_id=ctx.agency_id and o.application_id=v_row.application_id and o.status='ACCEPTED') then return jsonb_build_object('ok',false,'error','accepted_offer_required'); end if;
  if not exists(select 1 from public.candidate_submissions s where s.agency_id=ctx.agency_id and s.application_id=v_row.application_id and s.workflow_status='CLIENT_SUBMITTED' and s.am_review_status='APPROVED' and s.client_submitted_at is not null and s.client_submission_snapshot is not null) then return jsonb_build_object('ok',false,'error','am_quality_gate_required'); end if;
 end if;
 update public.placements set status=p_status,updated_at=now(),completed_at=case when p_status='COMPLETED' then now() else completed_at end,cancelled_at=case when p_status='CANCELLED' then now() else cancelled_at end where id=p_id;
 perform private.xzrecruiter_log_recruitment_event(ctx.agency_id,ctx.user_id,'placement',p_id,case when p_status='STARTED' then 'joining.confirmed' else 'placement.status_changed' end,'Placement status updated',jsonb_build_object('from',v_row.status,'to',p_status,'reason',p_reason,'application_id',v_row.application_id));
 return jsonb_build_object('ok',true,'status',p_status);
end;$$;
revoke all on function public.xzrecruiter_placement_status(text,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.xzrecruiter_placement_status(text,uuid,text,text,text) to anon,authenticated;

commit;
