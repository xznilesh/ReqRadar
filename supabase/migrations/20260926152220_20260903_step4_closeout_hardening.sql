-- XZ Recruiter Step 4 full source closeout hardening.
-- Additive/compatibility-safe. Production activation remains a separate manual gate.

-- Search/filter indexes for large candidate/job workspaces.
create index if not exists idx_xzrecruiter_candidates_country_availability
  on public.candidates(agency_id,country_code,availability_status,updated_at desc)
  where archived_at is null and merged_into_candidate_id is null;
create index if not exists idx_xzrecruiter_candidates_workplace
  on public.candidates(agency_id,workplace_preference,updated_at desc)
  where archived_at is null and merged_into_candidate_id is null;
create index if not exists idx_xzrecruiter_jobs_country_status
  on public.recruitment_jobs(agency_id,country_code,status,priority,updated_at desc)
  where archived_at is null;
create index if not exists idx_xzrecruiter_jobs_pipeline
  on public.recruitment_jobs(agency_id,pipeline_id,status,updated_at desc)
  where archived_at is null;
create index if not exists idx_xzrecruiter_screening_application
  on public.application_screening_answers(agency_id,application_id,updated_at desc);
create index if not exists idx_xzrecruiter_scorecards_interview
  on public.interview_scorecards(agency_id,interview_id,status,updated_at desc);

-- Candidate-controlled portal profile fields are explicit and auditable.
alter table public.candidates add column if not exists portal_profile_updated_at timestamptz;
alter table public.candidates add column if not exists data_reviewed_at timestamptz;

-- Private Supabase Storage bucket. Dynamic SQL keeps this migration portable in non-Supabase CI.
do $do$
begin
  if exists(select 1 from pg_namespace where nspname='storage') then
    execute $sql$
      insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
      values(
        'xzrecruiter-private',
        'xzrecruiter-private',
        false,
        8388608,
        array['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain']::text[]
      )
      on conflict (id) do update set
        public=false,
        file_size_limit=excluded.file_size_limit,
        allowed_mime_types=excluded.allowed_mime_types
    $sql$;
  end if;
end $do$;

-- Advanced server-side candidate search with filters/facets and bounded pagination.
create or replace function public.xzrecruiter_candidate_search(
  p_token text,
  p_query text default '',
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid; v_user uuid; v_role text;
  v_query text:=lower(btrim(coalesce(p_query,'')));
  v_country text:=nullif(upper(coalesce(p_filters->>'countryCode','')),'');
  v_availability text:=nullif(upper(coalesce(p_filters->>'availability','')),'');
  v_workplace text:=nullif(upper(coalesce(p_filters->>'workplace','')),'');
  v_skill text:=nullif(lower(btrim(coalesce(p_filters->>'skill',''))),'');
  v_tag text:=nullif(lower(btrim(coalesce(p_filters->>'tag',''))),'');
  v_min_exp numeric:=nullif(p_filters->>'minExperience','')::numeric;
  v_max_notice integer:=nullif(p_filters->>'maxNoticeDays','')::integer;
  v_limit integer:=greatest(1,least(coalesce(p_limit,50),100));
  v_offset integer:=greatest(coalesce(p_offset,0),0);
  v_rows jsonb:='[]'::jsonb; v_total integer:=0; v_facets jsonb:='{}'::jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  with filtered as (
    select c.* from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and (v_query='' or lower(c.full_name) like '%'||v_query||'%' or lower(coalesce(c.email,'')) like '%'||v_query||'%' or lower(coalesce(c.current_title,'')) like '%'||v_query||'%' or lower(coalesce(c.current_company,'')) like '%'||v_query||'%')
      and (v_country is null or c.country_code=v_country)
      and (v_availability is null or c.availability_status=v_availability)
      and (v_workplace is null or upper(coalesce(c.workplace_preference,''))=v_workplace)
      and (v_min_exp is null or coalesce(c.experience_years,0)>=v_min_exp)
      and (v_max_notice is null or coalesce(c.notice_period_days,0)<=v_max_notice)
      and (v_skill is null or exists(select 1 from jsonb_array_elements_text(coalesce(c.skills,'[]'::jsonb)) s where lower(s)=v_skill))
      and (v_tag is null or exists(select 1 from jsonb_array_elements_text(coalesce(c.tags,'[]'::jsonb)) t where lower(t)=v_tag))
  )
  select count(*)::integer into v_total from filtered;

  with filtered as (
    select c.* from public.candidates c
    where c.agency_id=v_agency and c.archived_at is null and c.merged_into_candidate_id is null
      and (v_query='' or lower(c.full_name) like '%'||v_query||'%' or lower(coalesce(c.email,'')) like '%'||v_query||'%' or lower(coalesce(c.current_title,'')) like '%'||v_query||'%' or lower(coalesce(c.current_company,'')) like '%'||v_query||'%')
      and (v_country is null or c.country_code=v_country)
      and (v_availability is null or c.availability_status=v_availability)
      and (v_workplace is null or upper(coalesce(c.workplace_preference,''))=v_workplace)
      and (v_min_exp is null or coalesce(c.experience_years,0)>=v_min_exp)
      and (v_max_notice is null or coalesce(c.notice_period_days,0)<=v_max_notice)
      and (v_skill is null or exists(select 1 from jsonb_array_elements_text(coalesce(c.skills,'[]'::jsonb)) s where lower(s)=v_skill))
      and (v_tag is null or exists(select 1 from jsonb_array_elements_text(coalesce(c.tags,'[]'::jsonb)) t where lower(t)=v_tag))
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
    select id,full_name,preferred_name,headline,email,phone,city,region,country_code,timezone,current_title,current_company,
      experience_years,relevant_experience_years,salary_expected,salary_currency,notice_period_days,skills,languages,availability_status,
      workplace_preference,relocation_preference,owner_user_id,tags,consent_status,updated_at
    from filtered order by updated_at desc limit v_limit offset v_offset
  ) x;

  select jsonb_build_object(
    'countries',coalesce((select jsonb_object_agg(country_code,n) from (select coalesce(country_code,'UNSET') country_code,count(*) n from public.candidates where agency_id=v_agency and archived_at is null and merged_into_candidate_id is null group by 1) q),'{}'::jsonb),
    'availability',coalesce((select jsonb_object_agg(availability_status,n) from (select availability_status,count(*) n from public.candidates where agency_id=v_agency and archived_at is null and merged_into_candidate_id is null group by 1) q),'{}'::jsonb)
  ) into v_facets;

  return jsonb_build_object('ok',true,'rows',v_rows,'total',v_total,'limit',v_limit,'offset',v_offset,'facets',v_facets,'role',v_role);
end;$fn$;

-- Advanced server-side job search.
create or replace function public.xzrecruiter_job_search(
  p_token text,
  p_query text default '',
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_query text:=lower(btrim(coalesce(p_query,'')));
  v_country text:=nullif(upper(coalesce(p_filters->>'countryCode','')),'');
  v_status text:=nullif(upper(coalesce(p_filters->>'status','')),'');
  v_priority text:=nullif(upper(coalesce(p_filters->>'priority','')),'');
  v_workplace text:=nullif(upper(coalesce(p_filters->>'workplace','')),'');
  v_pipeline uuid:=nullif(p_filters->>'pipelineId','')::uuid;
  v_limit integer:=greatest(1,least(coalesce(p_limit,50),100));v_offset integer:=greatest(coalesce(p_offset,0),0);
  v_rows jsonb:='[]'::jsonb;v_total integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select count(*)::integer into v_total from public.recruitment_jobs j where j.agency_id=v_agency and j.archived_at is null
    and (v_query='' or lower(j.title) like '%'||v_query||'%' or lower(coalesce(j.location,'')) like '%'||v_query||'%' or lower(coalesce(j.internal_ref,'')) like '%'||v_query||'%')
    and (v_country is null or j.country_code=v_country) and (v_status is null or j.status=v_status)
    and (v_priority is null or j.priority=v_priority) and (v_workplace is null or upper(coalesce(j.workplace_type,''))=v_workplace)
    and (v_pipeline is null or j.pipeline_id=v_pipeline);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_rows from (
    select j.id,j.title,j.internal_ref,j.client_id,j.company_id,j.status,j.priority,j.location,j.city,j.region,j.country_code,j.timezone,j.workplace_type,j.employment_type,
      j.salary_min,j.salary_max,j.salary_currency,j.salary_period,j.openings,j.pipeline_id,j.public_visibility,j.public_slug,j.owner_user_id,j.updated_at,
      coalesce(rc.name,c.name) account_name
    from public.recruitment_jobs j
    left join public.recruitment_clients rc on rc.id=j.client_id and rc.agency_id=v_agency
    left join public.companies c on c.id=j.company_id
    where j.agency_id=v_agency and j.archived_at is null
      and (v_query='' or lower(j.title) like '%'||v_query||'%' or lower(coalesce(j.location,'')) like '%'||v_query||'%' or lower(coalesce(j.internal_ref,'')) like '%'||v_query||'%')
      and (v_country is null or j.country_code=v_country) and (v_status is null or j.status=v_status)
      and (v_priority is null or j.priority=v_priority) and (v_workplace is null or upper(coalesce(j.workplace_type,''))=v_workplace)
      and (v_pipeline is null or j.pipeline_id=v_pipeline)
    order by j.updated_at desc limit v_limit offset v_offset
  ) x;
  return jsonb_build_object('ok',true,'rows',v_rows,'total',v_total,'limit',v_limit,'offset',v_offset,'role',v_role);
end;$fn$;

-- Prepare a private resume/document object using session-derived tenant ownership.
create or replace function public.xzrecruiter_prepare_candidate_document(
  p_token text,p_candidate_id uuid,p_filename text,p_mime_type text,p_size_bytes bigint,p_checksum text
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare
  v_agency uuid;v_user uuid;v_role text;v_document uuid:=gen_random_uuid();v_parse uuid:=gen_random_uuid();v_version integer;v_path text;v_filename text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if not exists(select 1 from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null) then
    return jsonb_build_object('ok',false,'error','candidate_not_found');
  end if;
  if coalesce(p_size_bytes,0)<=0 or p_size_bytes>8388608 then return jsonb_build_object('ok',false,'error','invalid_file_size'); end if;
  if coalesce(p_mime_type,'') not in ('application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain') then
    return jsonb_build_object('ok',false,'error','unsupported_file_type');
  end if;
  v_filename:=regexp_replace(coalesce(nullif(btrim(p_filename),''),'resume'),'[^A-Za-z0-9._-]+','-','g');
  select coalesce(max(version_number),0)+1 into v_version from public.candidate_documents where agency_id=v_agency and candidate_id=p_candidate_id and document_type='RESUME';
  v_path:=v_agency::text||'/'||p_candidate_id::text||'/resume/'||v_document::text||'-'||v_filename;
  update public.candidate_documents set is_primary=false where agency_id=v_agency and candidate_id=p_candidate_id and document_type='RESUME' and archived_at is null;
  insert into public.candidate_documents(id,agency_id,candidate_id,document_type,version_number,filename,storage_path,mime_type,size_bytes,checksum,is_primary,uploaded_by_user_id)
    values(v_document,v_agency,p_candidate_id,'RESUME',v_version,v_filename,v_path,p_mime_type,p_size_bytes,p_checksum,true,v_user);
  insert into public.candidate_parse_runs(id,agency_id,candidate_id,document_id,provider,parser_version,status,review_state)
    values(v_parse,v_agency,p_candidate_id,v_document,'XZ_LOCAL','xz-local-1','PENDING','NEEDS_REVIEW');
  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',p_candidate_id,'resume.upload_prepared','Resume upload prepared',jsonb_build_object('document_id',v_document,'version',v_version));
  return jsonb_build_object('ok',true,'document_id',v_document,'parse_run_id',v_parse,'storage_path',v_path,'version_number',v_version);
end;$fn$;

create or replace function public.xzrecruiter_finalize_candidate_parse(
  p_token text,p_parse_run_id uuid,p_extracted_data jsonb,p_field_confidence jsonb,p_field_evidence jsonb,p_error text default null
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_candidate uuid;v_status text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select candidate_id into v_candidate from public.candidate_parse_runs where id=p_parse_run_id and agency_id=v_agency;
  if v_candidate is null then return jsonb_build_object('ok',false,'error','parse_run_not_found'); end if;
  v_status:=case when nullif(p_error,'') is null then 'COMPLETED' else 'FAILED' end;
  update public.candidate_parse_runs set status=v_status,extracted_data=coalesce(p_extracted_data,'{}'::jsonb),field_confidence=coalesce(p_field_confidence,'{}'::jsonb),field_evidence=coalesce(p_field_evidence,'{}'::jsonb),error_message=nullif(p_error,''),updated_at=now() where id=p_parse_run_id and agency_id=v_agency;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',v_candidate,case when v_status='COMPLETED' then 'resume.parsed' else 'resume.parse_failed' end,'Resume parsing finished',jsonb_build_object('parse_run_id',p_parse_run_id,'status',v_status));
  return jsonb_build_object('ok',true,'status',v_status,'candidate_id',v_candidate);
end;$fn$;

create or replace function public.xzrecruiter_apply_candidate_parse(
  p_token text,p_parse_run_id uuid,p_fields jsonb
) returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_candidate uuid;v_data jsonb;v_fields jsonb:=coalesce(p_fields,'{}'::jsonb);
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select candidate_id,extracted_data into v_candidate,v_data from public.candidate_parse_runs where id=p_parse_run_id and agency_id=v_agency and status='COMPLETED';
  if v_candidate is null then return jsonb_build_object('ok',false,'error','parse_run_not_found'); end if;
  update public.candidates set
    full_name=case when coalesce((v_fields->>'fullName')::boolean,false) then coalesce(nullif(v_data->>'fullName',''),full_name) else full_name end,
    email=case when coalesce((v_fields->>'email')::boolean,false) then coalesce(nullif(lower(v_data->>'email'),''),email) else email end,
    phone=case when coalesce((v_fields->>'phone')::boolean,false) then coalesce(nullif(v_data->>'phone',''),phone) else phone end,
    headline=case when coalesce((v_fields->>'headline')::boolean,false) then coalesce(nullif(v_data->>'headline',''),headline) else headline end,
    current_title=case when coalesce((v_fields->>'currentTitle')::boolean,false) then coalesce(nullif(v_data->>'currentTitle',''),current_title) else current_title end,
    experience_years=case when coalesce((v_fields->>'experienceYears')::boolean,false) and nullif(v_data->>'experienceYears','') is not null then (v_data->>'experienceYears')::numeric else experience_years end,
    skills=case when coalesce((v_fields->>'skills')::boolean,false) and jsonb_typeof(v_data->'skills')='array' then v_data->'skills' else skills end,
    education=case when coalesce((v_fields->>'education')::boolean,false) and jsonb_typeof(v_data->'education')='array' then v_data->'education' else education end,
    updated_by_user_id=v_user,updated_at=now(),data_reviewed_at=now()
  where id=v_candidate and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  update public.candidate_parse_runs set review_state='ACCEPTED',reviewed_by_user_id=v_user,reviewed_at=now(),updated_at=now() where id=p_parse_run_id and agency_id=v_agency;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',v_candidate,'resume.parse_applied','Reviewed resume fields applied',jsonb_build_object('parse_run_id',p_parse_run_id,'fields',v_fields));
  return jsonb_build_object('ok',true,'candidate_id',v_candidate);
end;$fn$;

-- Candidate closeout drawer data: documents, parse confidence, pools and likely duplicates.
create or replace function public.xzrecruiter_candidate_closeout_context(p_token text,p_candidate_id uuid)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_email text;v_phone text;v_name text;v_docs jsonb;v_runs jsonb;v_pools jsonb;v_dupes jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select lower(email),phone,lower(full_name) into v_email,v_phone,v_name from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  if not found then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.version_number desc),'[]'::jsonb) into v_docs from (select id,filename,mime_type,size_bytes,version_number,is_primary,created_at from public.candidate_documents where agency_id=v_agency and candidate_id=p_candidate_id and archived_at is null order by version_number desc limit 10) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_runs from (select id,document_id,status,parser_version,extracted_data,field_confidence,field_evidence,review_state,error_message,created_at from public.candidate_parse_runs where agency_id=v_agency and candidate_id=p_candidate_id order by created_at desc limit 5) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) into v_pools from (select p.id,p.name,(m.candidate_id is not null) member from public.talent_pools p left join public.talent_pool_members m on m.pool_id=p.id and m.candidate_id=p_candidate_id where p.agency_id=v_agency and p.active=true) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.score desc),'[]'::jsonb) into v_dupes from (
    select c.id,c.full_name,c.email,c.phone,c.current_title,c.current_company,c.updated_at,
      (case when v_email is not null and lower(c.email)=v_email then 60 else 0 end + case when v_phone is not null and c.phone=v_phone then 60 else 0 end + case when lower(c.full_name)=v_name then 35 else 0 end)::integer score
    from public.candidates c where c.agency_id=v_agency and c.id<>p_candidate_id and c.archived_at is null and c.merged_into_candidate_id is null
      and ((v_email is not null and lower(c.email)=v_email) or (v_phone is not null and c.phone=v_phone) or lower(c.full_name)=v_name)
    order by score desc,c.updated_at desc limit 10
  ) x;
  return jsonb_build_object('ok',true,'documents',v_docs,'parse_runs',v_runs,'talent_pools',v_pools,'duplicates',v_dupes);
end;$fn$;

create or replace function public.xzrecruiter_add_candidate_to_pool(p_token text,p_candidate_id uuid,p_pool_id uuid,p_add boolean default true)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if not exists(select 1 from public.candidates where id=p_candidate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null) then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;
  if not exists(select 1 from public.talent_pools where id=p_pool_id and agency_id=v_agency and active=true) then return jsonb_build_object('ok',false,'error','pool_not_found'); end if;
  if p_add then
    insert into public.talent_pool_members(agency_id,pool_id,candidate_id,added_by_user_id,source) values(v_agency,p_pool_id,p_candidate_id,v_user,'MANUAL') on conflict(pool_id,candidate_id) do nothing;
  else
    delete from public.talent_pool_members where agency_id=v_agency and pool_id=p_pool_id and candidate_id=p_candidate_id;
  end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',p_candidate_id,case when p_add then 'talent_pool.added' else 'talent_pool.removed' end,'Talent pool membership changed',jsonb_build_object('pool_id',p_pool_id));
  return jsonb_build_object('ok',true);
end;$fn$;

-- Merge duplicate profiles without deleting historical rows. Duplicate applications are archived, not deleted.
create or replace function public.xzrecruiter_merge_candidates(p_token text,p_survivor_id uuid,p_duplicate_id uuid,p_resolution jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_dup record;v_surv record;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER','MEMBER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if p_survivor_id=p_duplicate_id then return jsonb_build_object('ok',false,'error','same_candidate'); end if;
  select * into v_surv from public.candidates where id=p_survivor_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  select * into v_dup from public.candidates where id=p_duplicate_id and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  if v_surv.id is null or v_dup.id is null then return jsonb_build_object('ok',false,'error','candidate_not_found'); end if;

  -- Preserve independent application history and avoid a duplicate candidate/job pair.
  update public.applications a set candidate_id=p_survivor_id,updated_at=now(),metadata=coalesce(a.metadata,'{}'::jsonb)||jsonb_build_object('merged_from_candidate_id',p_duplicate_id)
  where a.agency_id=v_agency and a.candidate_id=p_duplicate_id and a.archived_at is null
    and not exists(select 1 from public.applications s where s.agency_id=v_agency and s.candidate_id=p_survivor_id and s.job_id=a.job_id and s.archived_at is null);
  update public.applications a set archived_at=now(),metadata=coalesce(a.metadata,'{}'::jsonb)||jsonb_build_object('merged_duplicate_candidate_id',p_duplicate_id,'surviving_candidate_id',p_survivor_id)
  where a.agency_id=v_agency and a.candidate_id=p_duplicate_id and a.archived_at is null;

  update public.candidates set
    preferred_name=coalesce(nullif(p_resolution->>'preferredName',''),preferred_name,v_dup.preferred_name),
    headline=coalesce(nullif(p_resolution->>'headline',''),headline,v_dup.headline),
    secondary_email=coalesce(secondary_email,case when email is distinct from v_dup.email then v_dup.email else null end),
    secondary_phone=coalesce(secondary_phone,case when phone is distinct from v_dup.phone then v_dup.phone else null end),
    current_title=coalesce(nullif(p_resolution->>'currentTitle',''),current_title,v_dup.current_title),
    current_company=coalesce(nullif(p_resolution->>'currentCompany',''),current_company,v_dup.current_company),
    skills=(select coalesce(jsonb_agg(distinct val),'[]'::jsonb) from jsonb_array_elements(coalesce(skills,'[]'::jsonb)||coalesce(v_dup.skills,'[]'::jsonb)) val),
    tags=(select coalesce(jsonb_agg(distinct val),'[]'::jsonb) from jsonb_array_elements(coalesce(tags,'[]'::jsonb)||coalesce(v_dup.tags,'[]'::jsonb)) val),
    updated_by_user_id=v_user,updated_at=now()
  where id=p_survivor_id and agency_id=v_agency;

  update public.candidates set merged_into_candidate_id=p_survivor_id,archived_at=now(),archived_by_user_id=v_user,updated_by_user_id=v_user,updated_at=now() where id=p_duplicate_id and agency_id=v_agency;
  insert into public.candidate_merge_events(agency_id,surviving_candidate_id,merged_candidate_id,field_resolution,merged_by_user_id) values(v_agency,p_survivor_id,p_duplicate_id,coalesce(p_resolution,'{}'::jsonb),v_user);
  perform private.xzrecruiter_log_activity(v_agency,v_user,'candidate',p_survivor_id,'candidate.merged','Duplicate candidate merged',jsonb_build_object('merged_candidate_id',p_duplicate_id));
  return jsonb_build_object('ok',true,'surviving_candidate_id',p_survivor_id,'merged_candidate_id',p_duplicate_id);
end;$fn$;

-- Bounded bulk action surface. Every id is rechecked against the active workspace.
create or replace function public.xzrecruiter_bulk_candidate_action(p_token text,p_candidate_ids uuid[],p_action text,p_value jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_action text:=upper(coalesce(p_action,''));v_count integer:=0;v_tag text;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if coalesce(array_length(p_candidate_ids,1),0)=0 or array_length(p_candidate_ids,1)>100 then return jsonb_build_object('ok',false,'error','invalid_batch_size'); end if;
  if v_action='ARCHIVE' then
    update public.candidates set archived_at=now(),archived_by_user_id=v_user,updated_by_user_id=v_user,updated_at=now() where agency_id=v_agency and id=any(p_candidate_ids) and archived_at is null and merged_into_candidate_id is null;
    get diagnostics v_count=row_count;
  elsif v_action='SET_AVAILABILITY' then
    if upper(coalesce(p_value->>'availability','')) not in ('UNKNOWN','AVAILABLE_NOW','AVAILABLE_SOON','NOT_AVAILABLE','PASSIVE') then return jsonb_build_object('ok',false,'error','invalid_availability'); end if;
    update public.candidates set availability_status=upper(p_value->>'availability'),updated_by_user_id=v_user,updated_at=now() where agency_id=v_agency and id=any(p_candidate_ids) and archived_at is null and merged_into_candidate_id is null;
    get diagnostics v_count=row_count;
  elsif v_action='ADD_TAG' then
    v_tag:=nullif(btrim(p_value->>'tag'),''); if v_tag is null then return jsonb_build_object('ok',false,'error','tag_required'); end if;
    update public.candidates c set tags=case when exists(select 1 from jsonb_array_elements_text(coalesce(c.tags,'[]'::jsonb)) t where lower(t)=lower(v_tag)) then c.tags else coalesce(c.tags,'[]'::jsonb)||to_jsonb(v_tag) end,updated_by_user_id=v_user,updated_at=now() where c.agency_id=v_agency and c.id=any(p_candidate_ids) and c.archived_at is null and c.merged_into_candidate_id is null;
    get diagnostics v_count=row_count;
  else return jsonb_build_object('ok',false,'error','unsupported_bulk_action'); end if;
  return jsonb_build_object('ok',true,'updated',v_count,'action',v_action);
end;$fn$;

-- Screening answers and weighted scorecard studio.
create or replace function public.xzrecruiter_save_screening_answers(p_token text,p_application_id uuid,p_answers jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_item jsonb;v_count integer:=0;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if not exists(select 1 from public.applications where id=p_application_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','application_not_found'); end if;
  if jsonb_typeof(coalesce(p_answers,'[]'::jsonb))<>'array' then return jsonb_build_object('ok',false,'error','invalid_answers'); end if;
  for v_item in select value from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) loop
    if nullif(v_item->>'key','') is not null then
      insert into public.application_screening_answers(agency_id,application_id,question_key,question_text,answer,score,knockout,reviewed_by_user_id,reviewed_at)
      values(v_agency,p_application_id,v_item->>'key',coalesce(nullif(v_item->>'question',''),v_item->>'key'),v_item->'answer',nullif(v_item->>'score','')::numeric,coalesce((v_item->>'knockout')::boolean,false),v_user,now())
      on conflict(application_id,question_key) do update set question_text=excluded.question_text,answer=excluded.answer,score=excluded.score,knockout=excluded.knockout,reviewed_by_user_id=v_user,reviewed_at=now(),updated_at=now();
      v_count:=v_count+1;
    end if;
  end loop;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'application',p_application_id,'screening.saved','Screening answers saved',jsonb_build_object('count',v_count));
  return jsonb_build_object('ok',true,'saved',v_count);
end;$fn$;

create or replace function public.xzrecruiter_scorecard_context(p_token text,p_interview_id uuid default null,p_application_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_templates jsonb;v_screening jsonb;v_scorecards jsonb;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) into v_templates from (
    select t.id,t.name,t.module,t.rating_min,t.rating_max,t.hide_peer_feedback_until_submit,
      coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'label',c.label,'description',c.description,'weight',c.weight,'sort_order',c.sort_order) order by c.sort_order) from public.scorecard_criteria c where c.template_id=t.id and c.agency_id=v_agency and c.active=true),'[]'::jsonb) criteria
    from public.scorecard_templates t where t.agency_id=v_agency and t.active=true
  ) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at),'[]'::jsonb) into v_screening from (select question_key,question_text,answer,score,knockout,updated_at from public.application_screening_answers where agency_id=v_agency and application_id=p_application_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]'::jsonb) into v_scorecards from (
    select s.id,s.interview_id,s.template_id,s.author_user_id,s.recommendation,s.comments,s.status,s.submitted_at,s.updated_at,
      coalesce((select jsonb_agg(jsonb_build_object('criterion_id',r.criterion_id,'rating',r.rating,'comment',r.comment)) from public.interview_scorecard_ratings r where r.scorecard_id=s.id),'[]'::jsonb) ratings
    from public.interview_scorecards s where s.agency_id=v_agency and (p_interview_id is null or s.interview_id=p_interview_id)
      and (s.author_user_id=v_user or s.status='SUBMITTED')
  ) x;
  return jsonb_build_object('ok',true,'templates',v_templates,'screening',v_screening,'scorecards',v_scorecards,'current_user_id',v_user);
end;$fn$;

create or replace function public.xzrecruiter_submit_scorecard(p_token text,p_interview_id uuid,p_template_id uuid,p_ratings jsonb,p_recommendation text,p_comments text,p_submit boolean default true)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_scorecard uuid;v_item jsonb;v_min integer;v_max integer;v_rating numeric;
begin
  select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if not exists(select 1 from public.interviews where id=p_interview_id and agency_id=v_agency) then return jsonb_build_object('ok',false,'error','interview_not_found'); end if;
  select rating_min,rating_max into v_min,v_max from public.scorecard_templates where id=p_template_id and agency_id=v_agency and active=true;
  if v_min is null then return jsonb_build_object('ok',false,'error','scorecard_template_not_found'); end if;
  insert into public.interview_scorecards(agency_id,interview_id,template_id,author_user_id,recommendation,comments,status,submitted_at)
    values(v_agency,p_interview_id,p_template_id,v_user,nullif(p_recommendation,''),nullif(p_comments,''),case when p_submit then 'SUBMITTED' else 'DRAFT' end,case when p_submit then now() else null end)
  on conflict(interview_id,author_user_id) do update set template_id=excluded.template_id,recommendation=excluded.recommendation,comments=excluded.comments,status=excluded.status,submitted_at=excluded.submitted_at,updated_at=now()
  returning id into v_scorecard;
  if jsonb_typeof(coalesce(p_ratings,'[]'::jsonb))='array' then
    for v_item in select value from jsonb_array_elements(coalesce(p_ratings,'[]'::jsonb)) loop
      v_rating:=nullif(v_item->>'rating','')::numeric;
      if v_rating is not null and (v_rating<v_min or v_rating>v_max) then return jsonb_build_object('ok',false,'error','rating_out_of_range'); end if;
      if exists(select 1 from public.scorecard_criteria where id=(v_item->>'criterionId')::uuid and template_id=p_template_id and agency_id=v_agency and active=true) then
        insert into public.interview_scorecard_ratings(scorecard_id,criterion_id,rating,comment) values(v_scorecard,(v_item->>'criterionId')::uuid,v_rating,nullif(v_item->>'comment',''))
        on conflict(scorecard_id,criterion_id) do update set rating=excluded.rating,comment=excluded.comment;
      end if;
    end loop;
  end if;
  perform private.xzrecruiter_log_activity(v_agency,v_user,'interview',p_interview_id,case when p_submit then 'scorecard.submitted' else 'scorecard.saved' end,'Interview scorecard updated',jsonb_build_object('scorecard_id',v_scorecard));
  return jsonb_build_object('ok',true,'scorecard_id',v_scorecard,'status',case when p_submit then 'SUBMITTED' else 'DRAFT' end);
end;$fn$;

-- Candidate portal self-service patch. The portal token never exposes agency ids.
create or replace function public.xzrecruiter_candidate_portal_update(p_portal_token text,p_patch jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_hash text;v_agency uuid;v_candidate uuid;v_session uuid;v_email text;v_phone text;
begin
  if length(coalesce(p_portal_token,''))<24 then return jsonb_build_object('ok',false,'error','invalid_token'); end if;
  v_hash:=encode(extensions.digest(p_portal_token,'sha256'),'hex');
  select id,agency_id,candidate_id into v_session,v_agency,v_candidate from public.candidate_portal_sessions where token_hash=v_hash and revoked_at is null and expires_at>now();
  if v_candidate is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
  v_email:=nullif(lower(btrim(coalesce(p_patch->>'email',''))),'');
  v_phone:=nullif(regexp_replace(coalesce(p_patch->>'phone',''),'[^0-9+]','','g'),'');
  update public.candidates set
    preferred_name=case when p_patch ? 'preferredName' then nullif(btrim(p_patch->>'preferredName'),'') else preferred_name end,
    email=case when p_patch ? 'email' and v_email is not null then v_email else email end,
    phone=case when p_patch ? 'phone' and v_phone is not null then v_phone else phone end,
    city=case when p_patch ? 'city' then nullif(btrim(p_patch->>'city'),'') else city end,
    region=case when p_patch ? 'region' then nullif(btrim(p_patch->>'region'),'') else region end,
    workplace_preference=case when p_patch ? 'workplacePreference' then nullif(upper(p_patch->>'workplacePreference'),'') else workplace_preference end,
    availability_status=case when upper(coalesce(p_patch->>'availabilityStatus','')) in ('UNKNOWN','AVAILABLE_NOW','AVAILABLE_SOON','NOT_AVAILABLE','PASSIVE') then upper(p_patch->>'availabilityStatus') else availability_status end,
    consent_status=case when upper(coalesce(p_patch->>'consentStatus','')) in ('GRANTED','WITHDRAWN') then upper(p_patch->>'consentStatus') else consent_status end,
    consent_source=case when p_patch ? 'consentStatus' then 'CANDIDATE_PORTAL' else consent_source end,
    consent_at=case when p_patch ? 'consentStatus' then now() else consent_at end,
    portal_profile_updated_at=now(),updated_at=now()
  where id=v_candidate and agency_id=v_agency and archived_at is null and merged_into_candidate_id is null;
  update public.candidate_portal_sessions set last_seen_at=now() where id=v_session;
  insert into public.recruitment_activity_events(agency_id,actor_user_id,entity_type,entity_id,action,summary,metadata) values(v_agency,null,'candidate',v_candidate,'candidate.portal_updated','Candidate updated profile through secure portal','{}'::jsonb);
  return jsonb_build_object('ok',true,'candidate_id',v_candidate);
end;$fn$;

-- Explicit grants for closeout RPC surfaces.
grant execute on function public.xzrecruiter_candidate_search(text,text,jsonb,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_job_search(text,text,jsonb,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_prepare_candidate_document(text,uuid,text,text,bigint,text) to anon,authenticated;
grant execute on function public.xzrecruiter_finalize_candidate_parse(text,uuid,jsonb,jsonb,jsonb,text) to anon,authenticated;
grant execute on function public.xzrecruiter_apply_candidate_parse(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_closeout_context(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_add_candidate_to_pool(text,uuid,uuid,boolean) to anon,authenticated;
grant execute on function public.xzrecruiter_merge_candidates(text,uuid,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_bulk_candidate_action(text,uuid[],text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_save_screening_answers(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_scorecard_context(text,uuid,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_submit_scorecard(text,uuid,uuid,jsonb,text,text,boolean) to anon,authenticated;
grant execute on function public.xzrecruiter_candidate_portal_update(text,jsonb) to anon,authenticated;
