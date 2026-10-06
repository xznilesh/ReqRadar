-- XZ Recruiter Step 3: safe CSV import foundation.
-- Imports are staged, validated and explicitly committed. No service-role browser writes.

create table if not exists public.agency_company_records (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  domain text,
  website text,
  country_code text references public.global_country_profiles(country_code),
  region text,
  city text,
  industry_taxonomy_id uuid references public.taxonomy_nodes(id) on delete set null,
  employee_size_taxonomy_id uuid references public.taxonomy_nodes(id) on delete set null,
  company_type_taxonomy_id uuid references public.taxonomy_nodes(id) on delete set null,
  funding_stage_taxonomy_id uuid references public.taxonomy_nodes(id) on delete set null,
  source text not null default 'MANUAL',
  dedupe_key text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,dedupe_key)
);
create index if not exists idx_xzrecruiter_agency_companies_lookup on public.agency_company_records(agency_id,country_code,updated_at desc);
alter table public.agency_company_records enable row level security;
do $do$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='agency_company_records' and policyname='xzrecruiter_data_api_deny') then
    create policy xzrecruiter_data_api_deny on public.agency_company_records for all to anon,authenticated using(false) with check(false);
  end if;
end $do$;

create or replace function public.xzrecruiter_stage_import(
  p_token text,p_entity_type text,p_filename text,p_idempotency_key text,p_headers jsonb,p_mapping jsonb,p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;v_user_id uuid;v_role text;v_batch uuid;v_entity text:=upper(btrim(coalesce(p_entity_type,'')));
  v_item jsonb;v_raw jsonb;v_mapped jsonb;v_hash text;v_status text;v_errors jsonb;v_existing uuid;
  v_row integer:=0;v_valid integer:=0;v_invalid integer:=0;v_duplicates integer:=0;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN','RECRUITER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if v_entity not in ('COMPANY','CLIENT','CONTACT','CANDIDATE') then return jsonb_build_object('ok',false,'error','invalid_entity'); end if;
  if nullif(btrim(p_filename),'') is null or nullif(btrim(p_idempotency_key),'') is null then return jsonb_build_object('ok',false,'error','invalid_import'); end if;
  select id into v_existing from public.import_batches where agency_id=v_agency_id and idempotency_key=p_idempotency_key limit 1;
  if v_existing is not null then return jsonb_build_object('ok',true,'batch_id',v_existing,'existing',true); end if;

  insert into public.import_batches(agency_id,created_by_user_id,entity_type,source_filename,idempotency_key,status,headers,mapping,row_count)
  values(v_agency_id,v_user_id,v_entity,btrim(p_filename),p_idempotency_key,'MAPPED',coalesce(p_headers,'[]'::jsonb),coalesce(p_mapping,'{}'::jsonb),jsonb_array_length(coalesce(p_rows,'[]'::jsonb))) returning id into v_batch;

  for v_item in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_row:=v_row+1;v_raw:=coalesce(v_item->'raw',v_item);v_mapped:=coalesce(v_item->'mapped',v_item);v_errors:='[]'::jsonb;v_status:='VALID';
    v_hash:=encode(extensions.digest(v_mapped::text,'sha256'),'hex');

    if v_entity='COMPANY' then
      if nullif(btrim(v_mapped->>'name'),'') is null then v_errors:=v_errors||jsonb_build_array('Company name is required'); end if;
      if jsonb_array_length(v_errors)=0 and exists(select 1 from public.agency_company_records c where c.agency_id=v_agency_id and ((nullif(lower(v_mapped->>'domain'),'') is not null and lower(c.domain)=lower(v_mapped->>'domain')) or (lower(c.name)=lower(v_mapped->>'name') and coalesce(c.country_code,'')=coalesce(upper(v_mapped->>'country_code'),'')))) then v_status:='DUPLICATE'; end if;
    elsif v_entity='CLIENT' then
      if nullif(btrim(v_mapped->>'name'),'') is null then v_errors:=v_errors||jsonb_build_array('Client name is required'); end if;
      if jsonb_array_length(v_errors)=0 and exists(select 1 from public.recruitment_clients c where c.agency_id=v_agency_id and lower(c.name)=lower(v_mapped->>'name')) then v_status:='DUPLICATE'; end if;
    elsif v_entity='CANDIDATE' then
      if nullif(btrim(v_mapped->>'full_name'),'') is null then v_errors:=v_errors||jsonb_build_array('Candidate name is required'); end if;
      if nullif(btrim(v_mapped->>'email'),'') is not null and lower(v_mapped->>'email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then v_errors:=v_errors||jsonb_build_array('Candidate email is invalid'); end if;
      if jsonb_array_length(v_errors)=0 and nullif(btrim(v_mapped->>'email'),'') is not null and exists(select 1 from public.candidates c where c.agency_id=v_agency_id and lower(c.email)=lower(v_mapped->>'email')) then v_status:='DUPLICATE'; end if;
    else
      if nullif(btrim(v_mapped->>'full_name'),'') is null then v_errors:=v_errors||jsonb_build_array('Contact name is required'); end if;
      if nullif(btrim(v_mapped->>'client_name'),'') is null then v_errors:=v_errors||jsonb_build_array('Contact client_name is required'); end if;
      if jsonb_array_length(v_errors)=0 and not exists(select 1 from public.recruitment_clients c where c.agency_id=v_agency_id and lower(c.name)=lower(v_mapped->>'client_name')) then v_errors:=v_errors||jsonb_build_array('Client not found in this workspace'); end if;
      if jsonb_array_length(v_errors)=0 and nullif(btrim(v_mapped->>'email'),'') is not null and exists(select 1 from public.recruitment_contacts rc join public.recruitment_clients c on c.id=rc.client_id and c.agency_id=rc.agency_id where rc.agency_id=v_agency_id and lower(rc.email)=lower(v_mapped->>'email') and lower(c.name)=lower(v_mapped->>'client_name')) then v_status:='DUPLICATE'; end if;
    end if;

    if jsonb_array_length(v_errors)>0 then v_status:='INVALID'; end if;
    begin
      insert into public.import_staging_rows(agency_id,batch_id,row_number,raw_data,mapped_data,row_hash,status,errors)
      values(v_agency_id,v_batch,v_row,v_raw,v_mapped,v_hash,v_status,v_errors);
      if v_status='VALID' then v_valid:=v_valid+1; elsif v_status='INVALID' then v_invalid:=v_invalid+1; else v_duplicates:=v_duplicates+1; end if;
    exception when unique_violation then
      v_duplicates:=v_duplicates+1;
    end;
  end loop;

  update public.import_batches set status='VALIDATED',valid_rows=v_valid,invalid_rows=v_invalid,duplicate_rows=v_duplicates,report=jsonb_build_object('valid',v_valid,'invalid',v_invalid,'duplicates',v_duplicates),updated_at=now() where id=v_batch;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'import.validated','import_batch',v_batch,jsonb_build_object('entity_type',v_entity,'rows',v_row,'valid',v_valid,'invalid',v_invalid,'duplicates',v_duplicates));
  return jsonb_build_object('ok',true,'batch_id',v_batch,'status','VALIDATED','row_count',v_row,'valid_rows',v_valid,'invalid_rows',v_invalid,'duplicate_rows',v_duplicates);
end;
$function$;

create or replace function public.xzrecruiter_commit_import(p_token text,p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path='public','private','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;v_user_id uuid;v_role text;v_entity text;v_row record;v_data jsonb;v_id uuid;v_client uuid;v_imported integer:=0;v_failed integer:=0;v_dedupe text;
begin
  select agency_id,user_id,role into v_agency_id,v_user_id,v_role from private.xzrecruiter_session_context(p_token);
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN','RECRUITER') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  select entity_type into v_entity from public.import_batches where id=p_batch_id and agency_id=v_agency_id and status in ('VALIDATED','PARTIAL') limit 1;
  if v_entity is null then return jsonb_build_object('ok',false,'error','batch_not_ready'); end if;

  for v_row in select id,mapped_data from public.import_staging_rows where batch_id=p_batch_id and agency_id=v_agency_id and status='VALID' order by row_number loop
    v_data:=v_row.mapped_data;v_id:=gen_random_uuid();
    begin
      if v_entity='COMPANY' then
        v_dedupe:=case when nullif(lower(btrim(v_data->>'domain')),'') is not null then 'domain:'||lower(btrim(v_data->>'domain')) else 'name:'||md5(lower(btrim(v_data->>'name'))||':'||coalesce(upper(v_data->>'country_code'),'')) end;
        insert into public.agency_company_records(id,agency_id,name,domain,website,country_code,region,city,source,dedupe_key,created_by_user_id)
        values(v_id,v_agency_id,btrim(v_data->>'name'),nullif(lower(btrim(v_data->>'domain')),''),nullif(btrim(v_data->>'website'),''),nullif(upper(btrim(v_data->>'country_code')),''),nullif(btrim(v_data->>'region'),''),nullif(btrim(v_data->>'city'),''),'CSV',v_dedupe,v_user_id);
      elsif v_entity='CLIENT' then
        insert into public.recruitment_clients(id,agency_id,name,website,industry,status,owner_user_id,created_by_user_id,country_code,locale,timezone,currency_code)
        values(v_id,v_agency_id,btrim(v_data->>'name'),nullif(btrim(v_data->>'website'),''),nullif(btrim(v_data->>'industry'),''),'ACTIVE',v_user_id,v_user_id,nullif(upper(btrim(v_data->>'country_code')),''),nullif(btrim(v_data->>'locale'),''),nullif(btrim(v_data->>'timezone'),''),nullif(upper(btrim(v_data->>'currency_code')),''));
      elsif v_entity='CANDIDATE' then
        v_dedupe:=case when nullif(lower(btrim(v_data->>'email')),'') is not null then 'email:'||lower(btrim(v_data->>'email')) else 'candidate:'||md5(lower(btrim(v_data->>'full_name'))||':'||coalesce(v_data->>'phone','')) end;
        insert into public.candidates(id,agency_id,full_name,email,phone,location,current_title,current_company,experience_years,salary_current,salary_expected,salary_currency,notice_period_days,skills,resume_text,source,dedupe_key,created_by_user_id,country_code,locale,timezone)
        values(v_id,v_agency_id,btrim(v_data->>'full_name'),nullif(lower(btrim(v_data->>'email')),''),nullif(btrim(v_data->>'phone'),''),nullif(btrim(v_data->>'location'),''),nullif(btrim(v_data->>'current_title'),''),nullif(btrim(v_data->>'current_company'),''),nullif(v_data->>'experience_years','')::numeric,nullif(v_data->>'salary_current','')::numeric,nullif(v_data->>'salary_expected','')::numeric,nullif(upper(btrim(v_data->>'salary_currency')),''),nullif(v_data->>'notice_period_days','')::integer,coalesce(v_data->'skills','[]'::jsonb),nullif(v_data->>'resume_text',''),'CSV',v_dedupe,v_user_id,nullif(upper(btrim(v_data->>'country_code')),''),nullif(btrim(v_data->>'locale'),''),nullif(btrim(v_data->>'timezone'),''));
      else
        select id into v_client from public.recruitment_clients where agency_id=v_agency_id and lower(name)=lower(v_data->>'client_name') limit 1;
        if v_client is null then raise exception 'client_missing'; end if;
        insert into public.recruitment_contacts(id,agency_id,client_id,full_name,title,email,phone)
        values(v_id,v_agency_id,v_client,btrim(v_data->>'full_name'),nullif(btrim(v_data->>'title'),''),nullif(lower(btrim(v_data->>'email')),''),nullif(btrim(v_data->>'phone'),''));
      end if;
      update public.import_staging_rows set status='IMPORTED',imported_entity_id=v_id,updated_at=now() where id=v_row.id and agency_id=v_agency_id;
      v_imported:=v_imported+1;
    exception when others then
      update public.import_staging_rows set status='FAILED',errors=errors||jsonb_build_array(sqlerrm),updated_at=now() where id=v_row.id and agency_id=v_agency_id;
      v_failed:=v_failed+1;
    end;
  end loop;

  update public.import_batches set status=case when v_failed=0 then 'IMPORTED' else 'PARTIAL' end,report=report||jsonb_build_object('imported',v_imported,'failed',v_failed),completed_at=case when v_failed=0 then now() else completed_at end,updated_at=now() where id=p_batch_id and agency_id=v_agency_id;
  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata) values(gen_random_uuid(),v_agency_id,v_user_id,'import.committed','import_batch',p_batch_id,jsonb_build_object('entity_type',v_entity,'imported',v_imported,'failed',v_failed));
  return jsonb_build_object('ok',true,'status',case when v_failed=0 then 'IMPORTED' else 'PARTIAL' end,'imported',v_imported,'failed',v_failed);
end;
$function$;

revoke all on function public.xzrecruiter_stage_import(text,text,text,text,jsonb,jsonb,jsonb) from public,authenticated;
grant execute on function public.xzrecruiter_stage_import(text,text,text,text,jsonb,jsonb,jsonb) to anon;
revoke all on function public.xzrecruiter_commit_import(text,uuid) from public,authenticated;
grant execute on function public.xzrecruiter_commit_import(text,uuid) to anon;
