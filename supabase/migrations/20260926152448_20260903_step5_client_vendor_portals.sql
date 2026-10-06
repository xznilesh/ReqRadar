-- XZRecruiter Step 5: client/vendor collaboration portals.
-- Tokens are stored only as SHA-256 hashes. Portal snapshots remain tenant scoped.

create table if not exists public.client_portal_sessions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  client_id uuid not null references public.recruitment_clients(id) on delete cascade,
  contact_id uuid references public.recruitment_contacts(id) on delete set null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.client_portal_feedback (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  client_id uuid not null references public.recruitment_clients(id) on delete cascade,
  contact_id uuid references public.recruitment_contacts(id) on delete set null,
  submission_id uuid not null references public.candidate_submissions(id) on delete cascade,
  decision text not null check (decision in ('COMMENT','ADVANCE','REQUEST_INTERVIEW','HOLD','REJECT')),
  comment text,
  created_at timestamptz not null default now()
);

create table if not exists public.recruitment_vendors (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  vendor_type text not null default 'SOURCING_PARTNER' check (vendor_type in ('SOURCING_PARTNER','SUBCONTRACTOR','RPO_PARTNER','STAFFING_PARTNER','FREELANCE_RECRUITER','OTHER')),
  status text not null default 'ACTIVE' check (status in ('PROSPECT','ACTIVE','SUSPENDED','INACTIVE')),
  website text,
  email text,
  phone text,
  country_code text references public.global_country_profiles(country_code),
  timezone text,
  currency_code text check (currency_code is null or currency_code ~ '^[A-Z]{3}$'),
  specialties jsonb not null default '[]'::jsonb,
  owner_user_id uuid references public.users(id) on delete set null,
  tags jsonb not null default '[]'::jsonb,
  notes text,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique(agency_id,name),
  constraint recruitment_vendors_timezone_check check (timezone is null or public.xzrecruiter_valid_timezone(timezone))
);

create table if not exists public.vendor_portal_sessions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  vendor_id uuid not null references public.recruitment_vendors(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_seen_at timestamptz,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.vendor_job_access (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  vendor_id uuid not null references public.recruitment_vendors(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  active boolean not null default true,
  shared_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(vendor_id,job_id)
);

create table if not exists public.vendor_candidate_submissions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  vendor_id uuid not null references public.recruitment_vendors(id) on delete cascade,
  job_id uuid not null references public.recruitment_jobs(id) on delete cascade,
  candidate_name text not null,
  candidate_email text,
  candidate_phone text,
  current_title text,
  location text,
  summary text,
  resume_storage_path text,
  status text not null default 'SUBMITTED' check (status in ('SUBMITTED','UNDER_REVIEW','ACCEPTED','DUPLICATE','REJECTED','CONVERTED')),
  converted_candidate_id uuid references public.candidates(id) on delete set null,
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_xzr_client_portal_sessions on public.client_portal_sessions(agency_id,client_id,expires_at desc);
create index if not exists idx_xzr_client_feedback_submission on public.client_portal_feedback(agency_id,submission_id,created_at desc);
create index if not exists idx_xzr_vendors_search on public.recruitment_vendors(agency_id,archived_at,status,updated_at desc);
create index if not exists idx_xzr_vendor_jobs on public.vendor_job_access(agency_id,vendor_id,active,created_at desc);
create index if not exists idx_xzr_vendor_submissions on public.vendor_candidate_submissions(agency_id,vendor_id,job_id,status,submitted_at desc);

do $do$
declare t text;
begin
 foreach t in array array['client_portal_sessions','client_portal_feedback','recruitment_vendors','vendor_portal_sessions','vendor_job_access','vendor_candidate_submissions'] loop
  execute format('alter table public.%I enable row level security',t);
  if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
   execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',t);
  end if;
 end loop;
end $do$;

-- Keep generic private attachment/note validation compatible with vendor records.
create or replace function private.xzrecruiter_entity_belongs_to_agency(p_agency uuid,p_entity_type text,p_entity_id uuid)
returns boolean language plpgsql stable security definer set search_path='public','pg_temp' as $fn$
declare v_type text:=upper(coalesce(p_entity_type,''));
begin
  if v_type='CANDIDATE' then return exists(select 1 from public.candidates where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='JOB' then return exists(select 1 from public.recruitment_jobs where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='APPLICATION' then return exists(select 1 from public.applications where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='INTERVIEW' then return exists(select 1 from public.interviews where id=p_entity_id and agency_id=p_agency);
  elsif v_type='OFFER' then return exists(select 1 from public.offers where id=p_entity_id and agency_id=p_agency);
  elsif v_type='PLACEMENT' then return exists(select 1 from public.placements where id=p_entity_id and agency_id=p_agency);
  elsif v_type in ('CLIENT','ACCOUNT') then return exists(select 1 from public.recruitment_clients where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='CONTACT' then return exists(select 1 from public.recruitment_contacts where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='OPPORTUNITY' then return exists(select 1 from public.crm_opportunities where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='CRM_TASK' then return exists(select 1 from public.crm_tasks where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='CONTRACT' then return exists(select 1 from public.recruitment_client_contracts where id=p_entity_id and agency_id=p_agency and archived_at is null);
  elsif v_type='VENDOR' then return exists(select 1 from public.recruitment_vendors where id=p_entity_id and agency_id=p_agency and archived_at is null);
  end if;
  return false;
end;$fn$;
revoke all on function private.xzrecruiter_entity_belongs_to_agency(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.xzrecruiter_issue_client_portal_access(p_token text,p_client_id uuid,p_contact_id uuid default null)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_raw text;v_id uuid:=gen_random_uuid();
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);
 if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
 if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden'); end if;
 if not exists(select 1 from public.recruitment_clients where id=p_client_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','client_not_found'); end if;
 if p_contact_id is not null and not exists(select 1 from public.recruitment_contacts where id=p_contact_id and agency_id=v_agency and client_id=p_client_id and archived_at is null) then return jsonb_build_object('ok',false,'error','contact_not_found'); end if;
 v_raw:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.client_portal_sessions(id,agency_id,client_id,contact_id,token_hash,expires_at,created_by_user_id) values(v_id,v_agency,p_client_id,p_contact_id,encode(extensions.digest(v_raw,'sha256'),'hex'),now()+interval '14 days',v_user);
 perform private.xzrecruiter_log_activity(v_agency,v_user,'client',p_client_id,'client.portal_issued','Client portal access issued',jsonb_build_object('contact_id',p_contact_id,'session_id',v_id));
 return jsonb_build_object('ok',true,'portal_token',v_raw,'expires_at',now()+interval '14 days');
end;$fn$;

create or replace function public.xzrecruiter_client_portal_snapshot(p_portal_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_client uuid;v_contact uuid;
begin
 select agency_id,client_id,contact_id into v_agency,v_client,v_contact from public.client_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
 if v_client is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 update public.client_portal_sessions set last_seen_at=now() where token_hash=encode(extensions.digest(p_portal_token,'sha256'),'hex');
 return jsonb_build_object('ok',true,
  'client',(select jsonb_build_object('id',c.id,'name',c.name,'website',c.website,'country_code',c.country_code,'timezone',c.timezone) from public.recruitment_clients c where c.id=v_client and c.agency_id=v_agency and c.archived_at is null),
  'contact',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'title',c.title,'email',c.email) from public.recruitment_contacts c where c.id=v_contact and c.agency_id=v_agency),
  'jobs',coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'title',j.title,'status',j.status,'location',j.location,'country_code',j.country_code,'workplace_type',j.workplace_type,'openings',j.openings) order by j.updated_at desc) from public.recruitment_jobs j where j.agency_id=v_agency and j.client_id=v_client and j.archived_at is null and j.status in ('OPEN','ON_HOLD')),'[]'::jsonb),
  'submissions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'status',s.status,'summary',s.summary,'salary_expectation',s.salary_expectation,'salary_currency',s.salary_currency,'availability',s.availability,'notice_period_days',s.notice_period_days,'submitted_at',s.submitted_at,'candidate_name',c.full_name,'candidate_title',c.current_title,'job_id',j.id,'job_title',j.title,'feedback',coalesce((select jsonb_agg(jsonb_build_object('decision',f.decision,'comment',f.comment,'created_at',f.created_at) order by f.created_at desc) from public.client_portal_feedback f where f.agency_id=v_agency and f.submission_id=s.id),'[]'::jsonb)) order by s.submitted_at desc) from public.candidate_submissions s join public.candidates c on c.id=s.candidate_id and c.agency_id=v_agency join public.recruitment_jobs j on j.id=s.job_id and j.agency_id=v_agency where s.agency_id=v_agency and s.client_id=v_client and s.status<>'DRAFT'),'[]'::jsonb),
  'interviews',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'candidate_name',c.full_name,'job_title',j.title,'interview_type',i.interview_type,'scheduled_at',i.scheduled_at,'timezone',i.timezone,'status',i.status) order by i.scheduled_at desc) from public.interviews i join public.applications a on a.id=i.application_id and a.agency_id=v_agency join public.candidates c on c.id=a.candidate_id join public.recruitment_jobs j on j.id=a.job_id where i.agency_id=v_agency and a.client_id=v_client),'[]'::jsonb)
 );
end;$fn$;

create or replace function public.xzrecruiter_client_portal_feedback(p_portal_token text,p_submission_id uuid,p_decision text,p_comment text default null)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_client uuid;v_contact uuid;v_decision text:=upper(coalesce(p_decision,''));
begin
 select agency_id,client_id,contact_id into v_agency,v_client,v_contact from public.client_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;
 if v_client is null then return jsonb_build_object('ok',false,'error','invalid_or_expired'); end if;
 if v_decision not in ('COMMENT','ADVANCE','REQUEST_INTERVIEW','HOLD','REJECT') then return jsonb_build_object('ok',false,'error','invalid_decision'); end if;
 if not exists(select 1 from public.candidate_submissions where id=p_submission_id and agency_id=v_agency and client_id=v_client and status<>'DRAFT') then return jsonb_build_object('ok',false,'error','submission_not_found'); end if;
 insert into public.client_portal_feedback(agency_id,client_id,contact_id,submission_id,decision,comment) values(v_agency,v_client,v_contact,p_submission_id,v_decision,nullif(btrim(coalesce(p_comment,'')),''));
 update public.candidate_submissions set status=case v_decision when 'REQUEST_INTERVIEW' then 'INTERVIEW_REQUESTED' when 'ADVANCE' then 'ADVANCED' when 'REJECT' then 'REJECTED' when 'HOLD' then 'ON_HOLD' else status end,client_viewed_at=coalesce(client_viewed_at,now()),updated_at=now() where id=p_submission_id and agency_id=v_agency;
 return jsonb_build_object('ok',true,'decision',v_decision);
end;$fn$;

create or replace function public.xzrecruiter_vendor_context(p_token text,p_query text default '',p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_q text:='%'||lower(btrim(coalesce(p_query,'')))||'%';v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);v_offset integer:=greatest(coalesce(p_offset,0),0);
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;
 return jsonb_build_object('ok',true,'total',(select count(*) from public.recruitment_vendors v where v.agency_id=v_agency and v.archived_at is null and (btrim(coalesce(p_query,''))='' or lower(v.name) like v_q or lower(coalesce(v.email,'')) like v_q)),
  'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from (select v.id,v.name,v.vendor_type,v.status,v.website,v.email,v.phone,v.country_code,v.timezone,v.currency_code,v.specialties,v.owner_user_id,v.tags,v.updated_at,u.display_name owner_name,(select count(*) from public.vendor_job_access a where a.agency_id=v_agency and a.vendor_id=v.id and a.active=true) shared_jobs,(select count(*) from public.vendor_candidate_submissions s where s.agency_id=v_agency and s.vendor_id=v.id) submissions from public.recruitment_vendors v left join public.users u on u.id=v.owner_user_id where v.agency_id=v_agency and v.archived_at is null and (btrim(coalesce(p_query,''))='' or lower(v.name) like v_q or lower(coalesce(v.email,'')) like v_q) order by v.updated_at desc limit v_limit offset v_offset)x),'[]'::jsonb),'limit',v_limit,'offset',v_offset);
end;$fn$;

create or replace function public.xzrecruiter_save_vendor(p_token text,p_vendor jsonb)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_id uuid;v_name text;v_timezone text;
begin
 select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;
 v_name:=btrim(coalesce(p_vendor->>'name',''));v_timezone:=nullif(p_vendor->>'timezone','');if v_name='' then return jsonb_build_object('ok',false,'error','name_required');end if;if v_timezone is not null and not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone');end if;
 if nullif(p_vendor->>'id','') is null then v_id:=gen_random_uuid();insert into public.recruitment_vendors(id,agency_id,name,vendor_type,status,website,email,phone,country_code,timezone,currency_code,specialties,owner_user_id,tags,notes,created_by_user_id) values(v_id,v_agency,v_name,coalesce(nullif(upper(p_vendor->>'vendorType'),''),'SOURCING_PARTNER'),coalesce(nullif(upper(p_vendor->>'status'),''),'ACTIVE'),nullif(p_vendor->>'website',''),nullif(lower(p_vendor->>'email'),''),nullif(p_vendor->>'phone',''),nullif(upper(p_vendor->>'countryCode'),''),v_timezone,nullif(upper(p_vendor->>'currencyCode'),''),coalesce(p_vendor->'specialties','[]'::jsonb),coalesce(nullif(p_vendor->>'ownerUserId','')::uuid,v_user),coalesce(p_vendor->'tags','[]'::jsonb),nullif(p_vendor->>'notes',''),v_user);else v_id:=(p_vendor->>'id')::uuid;update public.recruitment_vendors set name=v_name,vendor_type=coalesce(nullif(upper(p_vendor->>'vendorType'),''),vendor_type),status=coalesce(nullif(upper(p_vendor->>'status'),''),status),website=nullif(p_vendor->>'website',''),email=nullif(lower(p_vendor->>'email'),''),phone=nullif(p_vendor->>'phone',''),country_code=nullif(upper(p_vendor->>'countryCode'),''),timezone=v_timezone,currency_code=nullif(upper(p_vendor->>'currencyCode'),''),specialties=coalesce(p_vendor->'specialties',specialties),owner_user_id=coalesce(nullif(p_vendor->>'ownerUserId','')::uuid,owner_user_id),tags=coalesce(p_vendor->'tags',tags),notes=nullif(p_vendor->>'notes',''),updated_at=now() where id=v_id and agency_id=v_agency and archived_at is null;if not found then return jsonb_build_object('ok',false,'error','not_found');end if;end if;perform private.xzrecruiter_log_activity(v_agency,v_user,'vendor',v_id,'vendor.saved','Vendor profile saved');return jsonb_build_object('ok',true,'id',v_id);
exception when unique_violation then return jsonb_build_object('ok',false,'error','vendor_exists');end;$fn$;

create or replace function public.xzrecruiter_issue_vendor_portal_access(p_token text,p_vendor_id uuid)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;v_raw text;v_id uuid:=gen_random_uuid();
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;if not exists(select 1 from public.recruitment_vendors where id=p_vendor_id and agency_id=v_agency and archived_at is null and status='ACTIVE') then return jsonb_build_object('ok',false,'error','vendor_not_found');end if;v_raw:=encode(extensions.gen_random_bytes(32),'hex');insert into public.vendor_portal_sessions(id,agency_id,vendor_id,token_hash,expires_at,created_by_user_id) values(v_id,v_agency,p_vendor_id,encode(extensions.digest(v_raw,'sha256'),'hex'),now()+interval '14 days',v_user);return jsonb_build_object('ok',true,'portal_token',v_raw,'expires_at',now()+interval '14 days');end;$fn$;

create or replace function public.xzrecruiter_share_job_with_vendor(p_token text,p_vendor_id uuid,p_job_id uuid,p_active boolean default true)
returns jsonb language plpgsql security definer set search_path='public','private','extensions','pg_temp' as $fn$
declare v_agency uuid;v_user uuid;v_role text;
begin select agency_id,user_id,role into v_agency,v_user,v_role from private.xzrecruiter_session_context(p_token);if v_agency is null then return jsonb_build_object('ok',false,'error','unauthorized');end if;if not private.xzrecruiter_can_write(v_role) then return jsonb_build_object('ok',false,'error','forbidden');end if;if not exists(select 1 from public.recruitment_vendors where id=p_vendor_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','vendor_not_found');end if;if not exists(select 1 from public.recruitment_jobs where id=p_job_id and agency_id=v_agency and archived_at is null) then return jsonb_build_object('ok',false,'error','job_not_found');end if;insert into public.vendor_job_access(agency_id,vendor_id,job_id,active,shared_by_user_id) values(v_agency,p_vendor_id,p_job_id,p_active,v_user) on conflict(vendor_id,job_id) do update set active=excluded.active,shared_by_user_id=v_user;return jsonb_build_object('ok',true);end;$fn$;

create or replace function public.xzrecruiter_vendor_portal_snapshot(p_portal_token text)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_vendor uuid;
begin select agency_id,vendor_id into v_agency,v_vendor from public.vendor_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;if v_vendor is null then return jsonb_build_object('ok',false,'error','invalid_or_expired');end if;update public.vendor_portal_sessions set last_seen_at=now() where token_hash=encode(extensions.digest(p_portal_token,'sha256'),'hex');return jsonb_build_object('ok',true,'vendor',(select jsonb_build_object('id',v.id,'name',v.name,'country_code',v.country_code) from public.recruitment_vendors v where v.id=v_vendor and v.agency_id=v_agency),'jobs',coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'title',j.title,'location',j.location,'country_code',j.country_code,'employment_type',j.employment_type,'workplace_type',j.workplace_type,'skills_required',j.skills_required,'status',j.status) order by a.created_at desc) from public.vendor_job_access a join public.recruitment_jobs j on j.id=a.job_id and j.agency_id=v_agency where a.agency_id=v_agency and a.vendor_id=v_vendor and a.active=true and j.archived_at is null and j.status='OPEN'),'[]'::jsonb),'submissions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'job_id',s.job_id,'candidate_name',s.candidate_name,'current_title',s.current_title,'location',s.location,'status',s.status,'submitted_at',s.submitted_at) order by s.submitted_at desc) from public.vendor_candidate_submissions s where s.agency_id=v_agency and s.vendor_id=v_vendor),'[]'::jsonb));end;$fn$;

create or replace function public.xzrecruiter_vendor_portal_submit(p_portal_token text,p_submission jsonb)
returns jsonb language plpgsql security definer set search_path='public','extensions','pg_temp' as $fn$
declare v_agency uuid;v_vendor uuid;v_job uuid;v_id uuid:=gen_random_uuid();v_name text;v_email text;
begin select agency_id,vendor_id into v_agency,v_vendor from public.vendor_portal_sessions where token_hash=encode(extensions.digest(coalesce(p_portal_token,''),'sha256'),'hex') and revoked_at is null and expires_at>now() limit 1;if v_vendor is null then return jsonb_build_object('ok',false,'error','invalid_or_expired');end if;v_job:=nullif(p_submission->>'jobId','')::uuid;v_name:=btrim(coalesce(p_submission->>'candidateName',''));v_email:=nullif(lower(btrim(coalesce(p_submission->>'candidateEmail',''))),'');if v_name='' then return jsonb_build_object('ok',false,'error','candidate_name_required');end if;if not exists(select 1 from public.vendor_job_access a join public.recruitment_jobs j on j.id=a.job_id where a.agency_id=v_agency and a.vendor_id=v_vendor and a.job_id=v_job and a.active=true and j.agency_id=v_agency and j.archived_at is null and j.status='OPEN') then return jsonb_build_object('ok',false,'error','job_not_shared');end if;if v_email is not null and exists(select 1 from public.candidates c join public.applications a on a.candidate_id=c.id and a.agency_id=v_agency where c.agency_id=v_agency and lower(c.email)=v_email and a.job_id=v_job and a.archived_at is null) then insert into public.vendor_candidate_submissions(id,agency_id,vendor_id,job_id,candidate_name,candidate_email,candidate_phone,current_title,location,summary,status) values(v_id,v_agency,v_vendor,v_job,v_name,v_email,nullif(p_submission->>'candidatePhone',''),nullif(p_submission->>'currentTitle',''),nullif(p_submission->>'location',''),nullif(p_submission->>'summary',''),'DUPLICATE');return jsonb_build_object('ok',true,'id',v_id,'status','DUPLICATE');end if;insert into public.vendor_candidate_submissions(id,agency_id,vendor_id,job_id,candidate_name,candidate_email,candidate_phone,current_title,location,summary,status) values(v_id,v_agency,v_vendor,v_job,v_name,v_email,nullif(p_submission->>'candidatePhone',''),nullif(p_submission->>'currentTitle',''),nullif(p_submission->>'location',''),nullif(p_submission->>'summary',''),'SUBMITTED');return jsonb_build_object('ok',true,'id',v_id,'status','SUBMITTED');end;$fn$;

grant execute on function public.xzrecruiter_issue_client_portal_access(text,uuid,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_client_portal_snapshot(text) to anon,authenticated;
grant execute on function public.xzrecruiter_client_portal_feedback(text,uuid,text,text) to anon,authenticated;
grant execute on function public.xzrecruiter_vendor_context(text,text,integer,integer) to anon,authenticated;
grant execute on function public.xzrecruiter_save_vendor(text,jsonb) to anon,authenticated;
grant execute on function public.xzrecruiter_issue_vendor_portal_access(text,uuid) to anon,authenticated;
grant execute on function public.xzrecruiter_share_job_with_vendor(text,uuid,uuid,boolean) to anon,authenticated;
grant execute on function public.xzrecruiter_vendor_portal_snapshot(text) to anon,authenticated;
grant execute on function public.xzrecruiter_vendor_portal_submit(text,jsonb) to anon,authenticated;
