-- XZ Recruiter Step 3: global agency onboarding + recruitment configuration.
-- Additive schema only. Existing recruitment rows and Step-1/Step-2 security/globalization remain unchanged.

create table if not exists public.onboarding_progress (
  agency_id uuid primary key references public.agencies(id) on delete cascade,
  setup_mode text not null default 'QUICK' check (setup_mode in ('QUICK','ADVANCED')),
  status text not null default 'NOT_STARTED' check (status in ('NOT_STARTED','IN_PROGRESS','COMPLETED')),
  current_step text not null default 'profile',
  completed_steps jsonb not null default '[]'::jsonb,
  skipped_steps jsonb not null default '[]'::jsonb,
  progress_percent smallint not null default 0 check (progress_percent between 0 and 100),
  started_at timestamptz,
  last_saved_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.onboarding_section_state (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  section_key text not null,
  payload jsonb not null default '{}'::jsonb,
  completed boolean not null default false,
  updated_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id, section_key)
);

create table if not exists public.agency_operating_profiles (
  agency_id uuid primary key references public.agencies(id) on delete cascade,
  business_name text,
  website text,
  primary_office_id uuid references public.recruitment_offices(id) on delete set null,
  team_size integer check (team_size is null or team_size >= 1),
  recruiter_count integer check (recruiter_count is null or recruiter_count >= 0),
  setup_mode text not null default 'QUICK' check (setup_mode in ('QUICK','ADVANCED')),
  terminology_mode text not null default 'AUTO' check (terminology_mode in ('AUTO','CV','RESUME')),
  quick_defaults_enabled boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.agency_business_models (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  model_code text not null check (model_code in (
    'RECRUITMENT_AGENCY','STAFFING_AGENCY','PERMANENT_RECRUITMENT','TEMPORARY_STAFFING',
    'CONTRACT_RECRUITMENT','EXECUTIVE_SEARCH','RPO','INTERNAL_TALENT_ACQUISITION',
    'HR_CONSULTANCY','SPECIALIST_AGENCY','MIXED_RECRUITMENT_BUSINESS'
  )),
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id, model_code)
);

create table if not exists public.agency_market_targets (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  country_code text not null references public.global_country_profiles(country_code),
  region text,
  city text,
  market_type text not null default 'ANY' check (market_type in ('ANY','ONSITE','REMOTE','HYBRID')),
  priority text not null default 'SECONDARY' check (priority in ('PRIMARY','SECONDARY')),
  target_kind text not null default 'RECRUITING' check (target_kind in ('RECRUITING','HEADQUARTERS','OFFICE','CANDIDATE')),
  timezone_id text,
  preferred boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agency_market_timezone_iana check (timezone_id is null or public.xzrecruiter_valid_timezone(timezone_id))
);
create index if not exists idx_xzrecruiter_market_targets_agency on public.agency_market_targets(agency_id,target_kind,priority,country_code,region,city);

create table if not exists public.agency_taxonomy_preferences (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  taxonomy_id uuid not null references public.taxonomy_nodes(id) on delete cascade,
  context text not null check (context in ('INDUSTRY','ICP','RECRUITMENT','CANDIDATE')),
  favourite boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id,taxonomy_id,context)
);
create index if not exists idx_xzrecruiter_taxonomy_preferences_context on public.agency_taxonomy_preferences(agency_id,context,taxonomy_id);

create table if not exists public.agency_icp_profiles (
  agency_id uuid primary key references public.agencies(id) on delete cascade,
  employee_growth_preference text not null default 'ANY' check (employee_growth_preference in ('ANY','GROWING','FAST_GROWING','STABLE')),
  hiring_volume_preference text not null default 'ANY' check (hiring_volume_preference in ('ANY','LOW','MEDIUM','HIGH','VERY_HIGH')),
  remote_first_preference text not null default 'ANY' check (remote_first_preference in ('ANY','REMOTE_FIRST','HYBRID','OFFICE_FIRST')),
  company_scope text not null default 'ANY' check (company_scope in ('ANY','LOCAL','MULTINATIONAL')),
  revenue_bands jsonb not null default '[]'::jsonb,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.agency_specialization_items (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  context text not null check (context in ('RECRUITMENT','CANDIDATE')),
  item_type text not null check (item_type in ('ROLE','SKILL','LANGUAGE','COUNTRY','CITY','SALARY_BAND','WORK_AUTHORIZATION','NOTICE_PERIOD','WORKPLACE')),
  taxonomy_id uuid references public.taxonomy_nodes(id) on delete cascade,
  text_value text,
  country_code text references public.global_country_profiles(country_code),
  city text,
  currency_code text check (currency_code is null or currency_code ~ '^[A-Z]{3}$'),
  amount_min numeric check (amount_min is null or amount_min >= 0),
  amount_max numeric check (amount_max is null or amount_max >= 0),
  notice_days_min integer check (notice_days_min is null or notice_days_min >= 0),
  notice_days_max integer check (notice_days_max is null or notice_days_max >= 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agency_specialization_range_valid check (amount_min is null or amount_max is null or amount_min <= amount_max),
  constraint agency_notice_range_valid check (notice_days_min is null or notice_days_max is null or notice_days_min <= notice_days_max),
  constraint agency_specialization_has_value check (taxonomy_id is not null or text_value is not null or country_code is not null or city is not null or amount_min is not null or notice_days_min is not null)
);
create index if not exists idx_xzrecruiter_specialization_context on public.agency_specialization_items(agency_id,context,item_type);

create table if not exists public.recruitment_pipelines (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  pipeline_kind text not null check (pipeline_kind in ('RECRUITMENT','BUSINESS_DEVELOPMENT')),
  recruitment_type text,
  name text not null,
  is_default boolean not null default false,
  active boolean not null default true,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,pipeline_kind,name)
);
create index if not exists idx_xzrecruiter_pipelines_agency on public.recruitment_pipelines(agency_id,pipeline_kind,active,is_default);

create table if not exists public.pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  pipeline_id uuid not null references public.recruitment_pipelines(id) on delete cascade,
  code text not null,
  name text not null,
  stage_category text not null default 'ACTIVE' check (stage_category in ('ACTIVE','TERMINAL')),
  status_semantic text not null default 'NEUTRAL' check (status_semantic in ('NEUTRAL','INFO','WARNING','SUCCESS','DANGER')),
  sort_order integer not null default 100,
  required_fields jsonb not null default '[]'::jsonb,
  rejection_reasons jsonb not null default '[]'::jsonb,
  transition_rules jsonb not null default '{}'::jsonb,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pipeline_id,code)
);
create index if not exists idx_xzrecruiter_pipeline_stages_order on public.pipeline_stages(agency_id,pipeline_id,sort_order);

create table if not exists public.custom_field_groups (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  module text not null check (module in ('CANDIDATE','JOB','COMPANY','CLIENT','CONTACT','OPPORTUNITY')),
  name text not null,
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,module,name)
);

create table if not exists public.custom_field_definitions (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  module text not null check (module in ('CANDIDATE','JOB','COMPANY','CLIENT','CONTACT','OPPORTUNITY')),
  group_id uuid references public.custom_field_groups(id) on delete set null,
  field_key text not null,
  label text not null,
  field_type text not null check (field_type in ('TEXT','LONG_TEXT','NUMBER','DECIMAL','CURRENCY','PERCENTAGE','DATE','DATETIME','CHECKBOX','SINGLE_SELECT','MULTI_SELECT','EMAIL','PHONE','URL','COUNTRY','TIMEZONE','USER','COMPANY','CANDIDATE','JOB','TAG')),
  required boolean not null default false,
  help_text text,
  default_value jsonb,
  validation_rules jsonb not null default '{}'::jsonb,
  options jsonb not null default '[]'::jsonb,
  searchable boolean not null default false,
  filterable boolean not null default false,
  visibility text not null default 'ALL' check (visibility in ('ALL','INTERNAL','MANAGERS','ADMINS')),
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,module,field_key)
);
create index if not exists idx_xzrecruiter_custom_fields_module on public.custom_field_definitions(agency_id,module,active,sort_order);

create table if not exists public.saved_views (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  owner_user_id uuid references public.users(id) on delete cascade,
  module text not null,
  name text not null,
  scope text not null default 'PERSONAL' check (scope in ('PERSONAL','TEAM')),
  filter_logic text not null default 'AND' check (filter_logic in ('AND','OR')),
  filters jsonb not null default '[]'::jsonb,
  sort_config jsonb not null default '[]'::jsonb,
  visible_columns jsonb not null default '[]'::jsonb,
  column_order jsonb not null default '[]'::jsonb,
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_xzrecruiter_saved_views_lookup on public.saved_views(agency_id,module,scope,owner_user_id,active);

create table if not exists public.workspace_departments (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,name)
);

create table if not exists public.workspace_teams (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  department_id uuid references public.workspace_departments(id) on delete set null,
  office_id uuid references public.recruitment_offices(id) on delete set null,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,name)
);

create table if not exists public.workspace_team_members (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  team_id uuid not null references public.workspace_teams(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (agency_id,team_id,user_id)
);

create table if not exists public.workspace_member_profiles (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  business_role text not null default 'RECRUITER' check (business_role in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER','SOURCER','BUSINESS_DEVELOPMENT','ACCOUNT_MANAGER','HIRING_MANAGER','INTERVIEWER','VIEWER_ANALYST')),
  department_id uuid references public.workspace_departments(id) on delete set null,
  office_id uuid references public.recruitment_offices(id) on delete set null,
  specialization jsonb not null default '{}'::jsonb,
  market_assignment jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id,user_id)
);

create table if not exists public.workspace_invitations (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  email text not null,
  rbac_role text not null default 'RECRUITER' check (rbac_role in ('ADMIN','RECRUITER','VIEWER','MEMBER')),
  business_role text not null default 'RECRUITER',
  team_id uuid references public.workspace_teams(id) on delete set null,
  status text not null default 'DRAFT' check (status in ('DRAFT','PENDING','ACCEPTED','EXPIRED','CANCELLED')),
  invited_by_user_id uuid not null references public.users(id) on delete cascade,
  invited_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,email)
);

create table if not exists public.workspace_territories (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  parent_id uuid references public.workspace_territories(id) on delete cascade,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,name,parent_id)
);

create table if not exists public.territory_rules (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  territory_id uuid not null references public.workspace_territories(id) on delete cascade,
  dimension text not null check (dimension in ('COUNTRY','REGION','CITY','INDUSTRY','JOB_FUNCTION','ACCOUNT_SEGMENT')),
  operator text not null default 'IN' check (operator in ('IN','NOT_IN','EQUALS')),
  values_json jsonb not null default '[]'::jsonb,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_xzrecruiter_territory_rules on public.territory_rules(agency_id,territory_id,sort_order);

create table if not exists public.agency_presets (
  preset_code text primary key,
  name text not null,
  description text not null,
  category text not null,
  payload jsonb not null,
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.import_batches (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  created_by_user_id uuid not null references public.users(id) on delete cascade,
  entity_type text not null check (entity_type in ('COMPANY','CLIENT','CONTACT','CANDIDATE')),
  source_filename text not null,
  idempotency_key text not null,
  status text not null default 'UPLOADED' check (status in ('UPLOADED','MAPPED','VALIDATED','IMPORTED','PARTIAL','FAILED')),
  headers jsonb not null default '[]'::jsonb,
  mapping jsonb not null default '{}'::jsonb,
  row_count integer not null default 0,
  valid_rows integer not null default 0,
  invalid_rows integer not null default 0,
  duplicate_rows integer not null default 0,
  report jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (agency_id,idempotency_key)
);

create table if not exists public.import_staging_rows (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  batch_id uuid not null references public.import_batches(id) on delete cascade,
  row_number integer not null,
  raw_data jsonb not null,
  mapped_data jsonb not null default '{}'::jsonb,
  row_hash text not null,
  status text not null default 'PENDING' check (status in ('PENDING','VALID','INVALID','DUPLICATE','IMPORTED','FAILED')),
  errors jsonb not null default '[]'::jsonb,
  imported_entity_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id,row_number),
  unique (batch_id,row_hash)
);
create index if not exists idx_xzrecruiter_import_rows_status on public.import_staging_rows(agency_id,batch_id,status,row_number);

-- Expand the existing Step-2 taxonomy engine with hierarchy; existing Step-2 nodes remain valid.
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_SOFTWARE','Software',p.id,1,10 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECHNOLOGY' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_AI','AI / ML',p.id,1,20 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECHNOLOGY' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_CYBER','Cybersecurity',p.id,1,30 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECHNOLOGY' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_IT_SERVICES','IT Services',p.id,1,40 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECHNOLOGY' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_SAAS','SaaS',p.id,2,10 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECH_SOFTWARE' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_ENTERPRISE_SOFTWARE','Enterprise Software',p.id,2,20 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECH_SOFTWARE' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','TECH_DEVTOOLS','Developer Tools',p.id,2,30 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='TECH_SOFTWARE' and p.agency_id is null
on conflict do nothing;

insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','HEALTH_HOSPITALS','Hospitals',p.id,1,10 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='HEALTHCARE' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','HEALTH_PHARMA','Pharmaceuticals',p.id,1,20 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='HEALTHCARE' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','HEALTH_BIOTECH','Biotechnology',p.id,1,30 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='HEALTHCARE' and p.agency_id is null
on conflict do nothing;
insert into public.taxonomy_nodes(domain,code,label,parent_id,level,sort_order)
select 'INDUSTRY','HEALTH_MEDICAL_DEVICES','Medical Devices',p.id,1,40 from public.taxonomy_nodes p
where p.domain='INDUSTRY' and p.code='HEALTHCARE' and p.agency_id is null
on conflict do nothing;

-- Professionally designed editable starter presets. Presets propose settings; they never lock configuration.
insert into public.agency_presets(preset_code,name,description,category,payload,sort_order) values
('TECH_AGENCY','Technology Recruitment Agency','Software, AI, cybersecurity and product hiring across growth companies.','INDUSTRY',
 $json${"businessModels":["RECRUITMENT_AGENCY","SPECIALIST_AGENCY"],"industries":["TECHNOLOGY","TECH_SOFTWARE","TECH_AI","TECH_CYBER"],"companySizes":["51_200","201_500","501_1000"],"jobFunctions":["ENGINEERING","DATA","AI","CYBERSECURITY","PRODUCT"],"recruitmentType":"PERMANENT_RECRUITMENT"}$json$::jsonb,10),
('HEALTHCARE_STAFFING','Healthcare Staffing','Hospitals, pharma, biotechnology and medical-device staffing.','INDUSTRY',
 $json${"businessModels":["STAFFING_AGENCY","TEMPORARY_STAFFING"],"industries":["HEALTHCARE","HEALTH_HOSPITALS","HEALTH_PHARMA","HEALTH_BIOTECH","HEALTH_MEDICAL_DEVICES"],"jobFunctions":["HEALTHCARE"],"recruitmentType":"TEMPORARY_STAFFING"}$json$::jsonb,20),
('EXEC_SEARCH','Executive Search','Leadership and board search for senior mandates.','MODEL',
 $json${"businessModels":["EXECUTIVE_SEARCH"],"seniority":["HEAD","DIRECTOR","SENIOR_DIRECTOR","VP","SVP","EVP","C_LEVEL","BOARD"],"recruitmentType":"EXECUTIVE_SEARCH"}$json$::jsonb,30),
('FINANCE_ACCOUNTING','Finance & Accounting Recruitment','Finance, accounting and financial-services recruitment.','INDUSTRY',
 $json${"businessModels":["RECRUITMENT_AGENCY"],"industries":["FINANCIAL_SERVICES","BANKING","FINTECH","ACCOUNTING"],"jobFunctions":["FINANCE","ACCOUNTING"]}$json$::jsonb,40),
('ENGINEERING_AGENCY','Engineering Recruitment','Engineering and skilled technical hiring.','INDUSTRY',
 $json${"businessModels":["RECRUITMENT_AGENCY","SPECIALIST_AGENCY"],"industries":["MANUFACTURING","AUTOMOTIVE","AEROSPACE","CONSTRUCTION"],"jobFunctions":["ENGINEERING","MANUFACTURING","SKILLED_TRADES"]}$json$::jsonb,50),
('GENERAL_STAFFING','General Staffing','Multi-industry permanent, contract and temporary staffing.','MODEL',
 $json${"businessModels":["STAFFING_AGENCY","MIXED_RECRUITMENT_BUSINESS"],"recruitmentType":"MIXED_RECRUITMENT_BUSINESS"}$json$::jsonb,60),
('US_STAFFING','US Staffing Agency','US multi-market staffing with timezone-aware operations.','MARKET',
 $json${"businessModels":["STAFFING_AGENCY","CONTRACT_RECRUITMENT"],"markets":["US"],"recruitmentType":"CONTRACT_RECRUITMENT"}$json$::jsonb,70),
('UK_RECRUITMENT','UK Recruitment Agency','UK recruitment using CV terminology and UK market defaults.','MARKET',
 $json${"businessModels":["RECRUITMENT_AGENCY"],"markets":["GB"],"recruitmentType":"PERMANENT_RECRUITMENT"}$json$::jsonb,80),
('GCC_RECRUITMENT','GCC Recruitment Agency','UAE, Saudi Arabia and wider GCC recruitment.','MARKET',
 $json${"businessModels":["RECRUITMENT_AGENCY","STAFFING_AGENCY"],"markets":["AE","SA","QA","BH","KW","OM"],"languages":["en","ar"]}$json$::jsonb,90),
('AU_NZ_RECRUITMENT','Australia / NZ Recruitment','Australia and New Zealand multi-timezone recruitment.','MARKET',
 $json${"businessModels":["RECRUITMENT_AGENCY"],"markets":["AU","NZ"],"recruitmentType":"PERMANENT_RECRUITMENT"}$json$::jsonb,100),
('INDIA_RECRUITMENT','India Recruitment Agency','India-first recruitment with INR and India locale defaults.','MARKET',
 $json${"businessModels":["RECRUITMENT_AGENCY"],"markets":["IN"],"languages":["en","hi"],"recruitmentType":"PERMANENT_RECRUITMENT"}$json$::jsonb,110)
on conflict (preset_code) do update set name=excluded.name,description=excluded.description,category=excluded.category,payload=excluded.payload,active=true,sort_order=excluded.sort_order,updated_at=now();

-- RLS defense in depth. Browser roles get no direct row access; session-aware RPCs mediate writes/reads.
do $do$
declare t text;
begin
  foreach t in array array[
    'onboarding_progress','onboarding_section_state','agency_operating_profiles','agency_business_models',
    'agency_market_targets','agency_taxonomy_preferences','agency_icp_profiles','agency_specialization_items',
    'recruitment_pipelines','pipeline_stages','custom_field_groups','custom_field_definitions','saved_views',
    'workspace_departments','workspace_teams','workspace_team_members','workspace_member_profiles','workspace_invitations',
    'workspace_territories','territory_rules','agency_presets','import_batches','import_staging_rows'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)', t);
    end if;
  end loop;
end $do$;

-- Retrieval indexes for common configuration center and onboarding queries.
create index if not exists idx_xzrecruiter_onboarding_sections on public.onboarding_section_state(agency_id,updated_at desc);
create index if not exists idx_xzrecruiter_business_models on public.agency_business_models(agency_id,is_primary desc,model_code);
create index if not exists idx_xzrecruiter_departments on public.workspace_departments(agency_id,active,name);
create index if not exists idx_xzrecruiter_teams on public.workspace_teams(agency_id,active,name);
create index if not exists idx_xzrecruiter_invitations on public.workspace_invitations(agency_id,status,created_at desc);
create index if not exists idx_xzrecruiter_territories on public.workspace_territories(agency_id,parent_id,active,name);
