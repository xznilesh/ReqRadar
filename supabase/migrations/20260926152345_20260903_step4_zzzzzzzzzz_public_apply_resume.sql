-- XZ Recruiter Step 4 closeout: consent-safe public application resume upload.
-- Private files remain server-uploaded; public callers receive only a short-lived one-time token for their own new application.

create table if not exists public.public_application_resume_tokens (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  application_id uuid not null references public.applications(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  document_id uuid references public.candidate_documents(id) on delete set null,
  parse_run_id uuid references public.candidate_parse_runs(id) on delete set null,
  used_at timestamptz,
  created_at timestamptz not null default now(),
  unique(application_id)
);
create index if not exists idx_xzrecruiter_public_resume_token_active
  on public.public_application_resume_tokens(token_hash,expires_at)
  where used_at is null;
alter table public.public_application_resume_tokens enable row level security;
do $do$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='public_application_resume_tokens' and policyname='xzrecruiter_data_api_deny') then
    create policy xzrecruiter_data_api_deny on public.public_application_resume_tokens for all to anon,authenticated using(false) with check(false);
  end if;
end $do$;

create or replace function public.xzrecruiter_public_apply(p_slug text,p_application jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare
  v_job public.recruitment_jobs%rowtype;
  v_candidate uuid;
  v_app uuid;
  v_actor uuid;
  v_email text;
  v_phone text;
  v_name text;
  v_dedupe text;
  v_stage uuid;
  v_stage_name text;
  v_country text;
  v_timezone text;
  v_has_resume boolean:=coalesce((p_application->>'hasResumeFile')::boolean,false);
  v_resume_token text;
begin
  select * into v_job from public.recruitment_jobs
  where public_slug=p_slug and public_visibility='PUBLIC' and archived_at is null and status='OPEN' limit 1;
  if v_job.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if not coalesce((p_application->>'consent')::boolean,false) then
    return jsonb_build_object('ok',false,'error','consent_required');
  end if;

  v_name:=btrim(coalesce(p_application->>'fullName',''));
  v_email:=nullif(lower(btrim(coalesce(p_application->>'email',''))),'');
  v_phone:=nullif(regexp_replace(coalesce(p_application->>'phone',''),'[^0-9+]','','g'),'');
  if v_name='' or v_email is null then return jsonb_build_object('ok',false,'error','name_email_required'); end if;

  v_country:=coalesce(nullif(upper(btrim(p_application->>'countryCode')),''),v_job.country_code);
  v_timezone:=nullif(btrim(p_application->>'timezone'),'');
  if v_country is not null and not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then
    return jsonb_build_object('ok',false,'error','invalid_country');
  end if;
  if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then
    return jsonb_build_object('ok',false,'error','invalid_timezone');
  end if;

  v_actor:=v_job.created_by_user_id;
  v_dedupe:=encode(extensions.digest(lower(v_name)||'|'||v_email||'|'||coalesce(v_phone,''),'sha256'),'hex');
  select id into v_candidate from public.candidates
  where agency_id=v_job.agency_id and lower(email)=v_email and archived_at is null and merged_into_candidate_id is null limit 1;

  if v_candidate is null then
    v_candidate:=gen_random_uuid();
    insert into public.candidates(
      id,agency_id,full_name,email,phone,location,city,region,country_code,timezone,current_title,skills,resume_text,source,dedupe_key,
      created_by_user_id,owner_user_id,consent_status,consent_source,consent_at,updated_by_user_id
    ) values(
      v_candidate,v_job.agency_id,v_name,v_email,v_phone,coalesce(nullif(p_application->>'location',''),v_job.location),
      nullif(p_application->>'city',''),nullif(p_application->>'region',''),v_country,v_timezone,nullif(p_application->>'currentTitle',''),
      coalesce(p_application->'skills','[]'::jsonb),nullif(p_application->>'resumeText',''),'CAREER_SITE',v_dedupe,v_actor,v_job.owner_user_id,
      'GRANTED','PUBLIC_APPLICATION',now(),v_actor
    );
  else
    -- A fresh application checkbox is a new explicit consent event. Preserve recruiter-verified fields and only refresh consent metadata.
    update public.candidates
    set consent_status='GRANTED',consent_source='PUBLIC_APPLICATION',consent_at=now(),updated_at=now()
    where id=v_candidate and agency_id=v_job.agency_id;
  end if;

  if exists(select 1 from public.applications where agency_id=v_job.agency_id and candidate_id=v_candidate and job_id=v_job.id and archived_at is null) then
    return jsonb_build_object('ok',false,'error','already_applied');
  end if;

  select id,name into v_stage,v_stage_name from public.pipeline_stages
  where agency_id=v_job.agency_id and pipeline_id=v_job.pipeline_id and code in ('APPLIED','NEW')
  order by case code when 'APPLIED' then 0 else 1 end limit 1;

  v_app:=gen_random_uuid();
  insert into public.applications(
    id,agency_id,job_id,candidate_id,stage,status,match_evidence,owner_user_id,created_by_user_id,client_id,pipeline_id,stage_id,stage_entered_at,last_activity_at,metadata
  ) values(
    v_app,v_job.agency_id,v_job.id,v_candidate,coalesce(v_stage_name,'Applied'),'ACTIVE','{}'::jsonb,v_job.owner_user_id,v_actor,v_job.client_id,v_job.pipeline_id,
    v_stage,now(),now(),jsonb_build_object('source','CAREER_SITE','consent_at',now(),'resume_file_expected',v_has_resume)
  );
  insert into public.application_stage_history(agency_id,application_id,to_stage_id,to_stage,changed_by_user_id)
  values(v_job.agency_id,v_app,v_stage,coalesce(v_stage_name,'Applied'),v_actor);

  if v_has_resume then
    v_resume_token:=encode(extensions.gen_random_bytes(32),'hex');
    insert into public.public_application_resume_tokens(agency_id,application_id,candidate_id,token_hash,expires_at)
    values(v_job.agency_id,v_app,v_candidate,encode(extensions.digest(v_resume_token,'sha256'),'hex'),now()+interval '15 minutes');
  end if;

  return jsonb_build_object(
    'ok',true,
    'application_id',v_app,
    'resume_upload_token',case when v_has_resume then v_resume_token else null end
  );
end;$fn$;

create or replace function public.xzrecruiter_public_prepare_application_document(
  p_upload_token text,p_filename text,p_mime_type text,p_size_bytes bigint,p_checksum text
) returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare
  v_row public.public_application_resume_tokens%rowtype;
  v_document uuid;
  v_parse uuid;
  v_version integer;
  v_filename text;
  v_path text;
begin
  select * into v_row from public.public_application_resume_tokens
  where token_hash=encode(extensions.digest(coalesce(p_upload_token,''),'sha256'),'hex')
    and used_at is null and expires_at>now() limit 1;
  if v_row.id is null then return jsonb_build_object('ok',false,'error','invalid_or_expired_upload_token'); end if;

  if coalesce(p_size_bytes,0)<=0 or p_size_bytes>8388608 then return jsonb_build_object('ok',false,'error','invalid_file_size'); end if;
  if coalesce(p_mime_type,'') not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain') then
    return jsonb_build_object('ok',false,'error','unsupported_file_type');
  end if;

  if v_row.document_id is not null and v_row.parse_run_id is not null then
    select storage_path,filename into v_path,v_filename from public.candidate_documents
    where id=v_row.document_id and agency_id=v_row.agency_id and candidate_id=v_row.candidate_id;
    return jsonb_build_object('ok',true,'document_id',v_row.document_id,'parse_run_id',v_row.parse_run_id,'storage_path',v_path,'filename',v_filename,'idempotent',true);
  end if;

  v_document:=gen_random_uuid();v_parse:=gen_random_uuid();
  v_filename:=regexp_replace(coalesce(nullif(btrim(p_filename),''),'resume'),'[^A-Za-z0-9._-]+','-','g');
  select coalesce(max(version_number),0)+1 into v_version from public.candidate_documents
  where agency_id=v_row.agency_id and candidate_id=v_row.candidate_id and document_type='RESUME';
  v_path:=v_row.agency_id::text||'/'||v_row.candidate_id::text||'/resume/'||v_document::text||'-'||v_filename;

  update public.candidate_documents set is_primary=false
  where agency_id=v_row.agency_id and candidate_id=v_row.candidate_id and document_type='RESUME' and archived_at is null;

  insert into public.candidate_documents(
    id,agency_id,candidate_id,document_type,version_number,filename,storage_path,mime_type,size_bytes,checksum,is_primary,uploaded_by_user_id
  ) values(
    v_document,v_row.agency_id,v_row.candidate_id,'RESUME',v_version,v_filename,v_path,p_mime_type,p_size_bytes,p_checksum,true,null
  );
  insert into public.candidate_parse_runs(
    id,agency_id,candidate_id,document_id,provider,parser_version,status,review_state
  ) values(
    v_parse,v_row.agency_id,v_row.candidate_id,v_document,'XZ_LOCAL','xz-local-1','PENDING','NEEDS_REVIEW'
  );
  update public.public_application_resume_tokens set document_id=v_document,parse_run_id=v_parse
  where id=v_row.id;

  return jsonb_build_object('ok',true,'document_id',v_document,'parse_run_id',v_parse,'storage_path',v_path,'version_number',v_version);
end;$fn$;

create or replace function public.xzrecruiter_public_finalize_application_document(
  p_upload_token text,p_parse_run_id uuid,p_extracted_data jsonb,p_field_confidence jsonb,p_field_evidence jsonb,p_error text default null
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_row public.public_application_resume_tokens%rowtype;
  v_status text;
  v_actor uuid;
begin
  select * into v_row from public.public_application_resume_tokens
  where token_hash=encode(extensions.digest(coalesce(p_upload_token,''),'sha256'),'hex')
    and used_at is null and expires_at>now() limit 1;
  if v_row.id is null then return jsonb_build_object('ok',false,'error','invalid_or_expired_upload_token'); end if;
  if v_row.parse_run_id is null or v_row.parse_run_id<>p_parse_run_id then return jsonb_build_object('ok',false,'error','parse_run_mismatch'); end if;

  v_status:=case when nullif(p_error,'') is null then 'COMPLETED' else 'FAILED' end;
  update public.candidate_parse_runs
  set status=v_status,
      extracted_data=coalesce(p_extracted_data,'{}'::jsonb),
      field_confidence=coalesce(p_field_confidence,'{}'::jsonb),
      field_evidence=coalesce(p_field_evidence,'{}'::jsonb),
      error_message=nullif(p_error,''),
      review_state='NEEDS_REVIEW',
      updated_at=now()
  where id=p_parse_run_id and agency_id=v_row.agency_id and candidate_id=v_row.candidate_id;
  if not found then return jsonb_build_object('ok',false,'error','parse_run_not_found'); end if;

  update public.public_application_resume_tokens set used_at=now() where id=v_row.id;
  select owner_user_id into v_actor from public.applications where id=v_row.application_id and agency_id=v_row.agency_id;
  perform private.xzrecruiter_log_activity(
    v_row.agency_id,v_actor,'candidate',v_row.candidate_id,
    case when v_status='COMPLETED' then 'public_resume.parsed' else 'public_resume.parse_failed' end,
    'Public application resume received',jsonb_build_object('application_id',v_row.application_id,'document_id',v_row.document_id,'status',v_status)
  );
  return jsonb_build_object('ok',true,'status',v_status,'document_id',v_row.document_id,'application_id',v_row.application_id);
end;$fn$;

grant execute on function public.xzrecruiter_public_apply(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_public_prepare_application_document(text,text,text,bigint,text) to anon,authenticated;
grant execute on function public.xzrecruiter_public_finalize_application_document(text,uuid,jsonb,jsonb,jsonb,text) to anon,authenticated;
