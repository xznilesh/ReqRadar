-- XZRecruiter Step 5: Recruitment CRM + agency business operating system.
-- Additive-first schema. Existing Step 1-4 security, globalization and ATS data are preserved.

-- Existing account/client records become a unified prospect/client account model.
alter table public.recruitment_clients add column if not exists company_id uuid references public.companies(id) on delete set null;
alter table public.recruitment_clients add column if not exists legal_name text;
alter table public.recruitment_clients add column if not exists domain text;
alter table public.recruitment_clients add column if not exists email text;
alter table public.recruitment_clients add column if not exists phone text;
alter table public.recruitment_clients add column if not exists address_line1 text;
alter table public.recruitment_clients add column if not exists address_line2 text;
alter table public.recruitment_clients add column if not exists city text;
alter table public.recruitment_clients add column if not exists region text;
alter table public.recruitment_clients add column if not exists postal_code text;
alter table public.recruitment_clients add column if not exists employee_size_min integer;
alter table public.recruitment_clients add column if not exists employee_size_max integer;
alter table public.recruitment_clients add column if not exists company_type text;
alter table public.recruitment_clients add column if not exists lifecycle_stage text not null default 'PROSPECT';
alter table public.recruitment_clients add column if not exists health_status text not null default 'UNASSESSED';
alter table public.recruitment_clients add column if not exists source text;
alter table public.recruitment_clients add column if not exists source_detail text;
alter table public.recruitment_clients add column if not exists priority text not null default 'NORMAL';
alter table public.recruitment_clients add column if not exists tags jsonb not null default '[]'::jsonb;
alter table public.recruitment_clients add column if not exists team_id uuid references public.workspace_teams(id) on delete set null;
alter table public.recruitment_clients add column if not exists territory_id uuid references public.workspace_territories(id) on delete set null;
alter table public.recruitment_clients add column if not exists last_activity_at timestamptz;
alter table public.recruitment_clients add column if not exists next_action text;
alter table public.recruitment_clients add column if not exists next_action_at timestamptz;
alter table public.recruitment_clients add column if not exists client_since date;
alter table public.recruitment_clients add column if not exists archived_at timestamptz;
alter table public.recruitment_clients add column if not exists archived_by_user_id uuid references public.users(id) on delete set null;

alter table public.recruitment_clients drop constraint if exists recruitment_clients_status_check;
alter table public.recruitment_clients add constraint recruitment_clients_status_check
  check (status in ('PROSPECT','QUALIFIED','ACTIVE','NURTURE','INACTIVE','LOST'));
alter table public.recruitment_clients drop constraint if exists recruitment_clients_lifecycle_check;
alter table public.recruitment_clients add constraint recruitment_clients_lifecycle_check
  check (lifecycle_stage in ('TARGET','PROSPECT','QUALIFIED','CLIENT','FORMER_CLIENT','NURTURE','LOST'));
alter table public.recruitment_clients drop constraint if exists recruitment_clients_health_check;
alter table public.recruitment_clients add constraint recruitment_clients_health_check
  check (health_status in ('UNASSESSED','HEALTHY','WATCH','AT_RISK','INACTIVE'));
alter table public.recruitment_clients drop constraint if exists recruitment_clients_priority_check;
alter table public.recruitment_clients add constraint recruitment_clients_priority_check check (priority in ('LOW','NORMAL','HIGH','URGENT'));
alter table public.recruitment_clients drop constraint if exists recruitment_clients_employee_range_check;
alter table public.recruitment_clients add constraint recruitment_clients_employee_range_check check (
  (employee_size_min is null or employee_size_min >= 0) and
  (employee_size_max is null or employee_size_max >= 0) and
  (employee_size_min is null or employee_size_max is null or employee_size_min <= employee_size_max)
);

-- Contacts remain account-scoped but become useful decision-maker records.
alter table public.recruitment_contacts add column if not exists department text;
alter table public.recruitment_contacts add column if not exists role_type text not null default 'OTHER';
alter table public.recruitment_contacts add column if not exists status text not null default 'ACTIVE';
alter table public.recruitment_contacts add column if not exists influence_level text not null default 'UNKNOWN';
alter table public.recruitment_contacts add column if not exists decision_authority text not null default 'UNKNOWN';
alter table public.recruitment_contacts add column if not exists preferred_channel text;
alter table public.recruitment_contacts add column if not exists linkedin_url text;
alter table public.recruitment_contacts add column if not exists country_code text references public.global_country_profiles(country_code);
alter table public.recruitment_contacts add column if not exists timezone text;
alter table public.recruitment_contacts add column if not exists language_code text;
alter table public.recruitment_contacts add column if not exists owner_user_id uuid references public.users(id) on delete set null;
alter table public.recruitment_contacts add column if not exists tags jsonb not null default '[]'::jsonb;
alter table public.recruitment_contacts add column if not exists last_contacted_at timestamptz;
alter table public.recruitment_contacts add column if not exists next_followup_at timestamptz;
alter table public.recruitment_contacts add column if not exists archived_at timestamptz;
alter table public.recruitment_contacts add column if not exists archived_by_user_id uuid references public.users(id) on delete set null;
alter table public.recruitment_contacts drop constraint if exists recruitment_contacts_timezone_check;
alter table public.recruitment_contacts add constraint recruitment_contacts_timezone_check check (timezone is null or public.xzrecruiter_valid_timezone(timezone));
alter table public.recruitment_contacts drop constraint if exists recruitment_contacts_role_type_check;
alter table public.recruitment_contacts add constraint recruitment_contacts_role_type_check check (role_type in ('DECISION_MAKER','HIRING_MANAGER','TALENT','HR','PROCUREMENT','FINANCE','EXECUTIVE','TECHNICAL','OTHER'));
alter table public.recruitment_contacts drop constraint if exists recruitment_contacts_status_check;
alter table public.recruitment_contacts add constraint recruitment_contacts_status_check check (status in ('ACTIVE','INACTIVE','BOUNCED','LEFT_COMPANY'));
alter table public.recruitment_contacts drop constraint if exists recruitment_contacts_influence_check;
alter table public.recruitment_contacts add constraint recruitment_contacts_influence_check check (influence_level in ('UNKNOWN','LOW','MEDIUM','HIGH'));
alter table public.recruitment_contacts drop constraint if exists recruitment_contacts_authority_check;
alter table public.recruitment_contacts add constraint recruitment_contacts_authority_check check (decision_authority in ('UNKNOWN','INFLUENCER','RECOMMENDER','DECISION_MAKER','ECONOMIC_BUYER'));

create table if not exists public.crm_opportunities (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  client_id uuid not null references public.recruitment_clients(id) on delete cascade,
  primary_contact_id uuid references public.recruitment_contacts(id) on delete set null,
  pipeline_id uuid not null references public.recruitment_pipelines(id) on delete restrict,
  stage_id uuid not null references public.pipeline_stages(id) on delete restrict,
  name text not null,
  status text not null default 'OPEN' check (status in ('OPEN','WON','LOST','NURTURE','ARCHIVED')),
  opportunity_type text not null default 'NEW_BUSINESS' check (opportunity_type in ('NEW_BUSINESS','EXPANSION','RENEWAL','REACTIVATION','RPO','PROJECT','OTHER')),
  estimated_roles integer check (estimated_roles is null or estimated_roles >= 0),
  estimated_value numeric check (estimated_value is null or estimated_value >= 0),
  currency_code text check (currency_code is null or currency_code ~ '^[A-Z]{3}$'),
  probability numeric not null default 20 check (probability between 0 and 100),
  expected_close_date date,
  source text,
  source_company_id uuid references public.companies(id) on delete set null,
  source_signal_key text,
  owner_user_id uuid references public.users(id) on delete set null,
  team_id uuid references public.workspace_teams(id) on delete set null,
  territory_id uuid references public.workspace_territories(id) on delete set null,
  next_action text,
  next_action_at timestamptz,
  lost_reason text,
  won_at timestamptz,
  lost_at timestamptz,
  last_activity_at timestamptz,
  tags jsonb not null default '[]'::jsonb,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create table if not exists public.crm_opportunity_stage_history (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  opportunity_id uuid not null references public.crm_opportunities(id) on delete cascade,
  from_stage_id uuid references public.pipeline_stages(id) on delete set null,
  to_stage_id uuid not null references public.pipeline_stages(id) on delete restrict,
  from_stage text,
  to_stage text not null,
  reason text,
  changed_by_user_id uuid references public.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create table if not exists public.crm_activities (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  activity_type text not null check (activity_type in ('NOTE','CALL','EMAIL','MEETING','LINKEDIN','WHATSAPP','SMS','CLIENT_FEEDBACK','STATUS_CHANGE','OTHER')),
  client_id uuid references public.recruitment_clients(id) on delete cascade,
  contact_id uuid references public.recruitment_contacts(id) on delete set null,
  opportunity_id uuid references public.crm_opportunities(id) on delete cascade,
  subject text,
  body text,
  direction text check (direction is null or direction in ('INBOUND','OUTBOUND','INTERNAL')),
  outcome text,
  occurred_at timestamptz not null default now(),
  next_action text,
  next_action_at timestamptz,
  actor_user_id uuid references public.users(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint crm_activity_parent_required check (client_id is not null or contact_id is not null or opportunity_id is not null)
);

create table if not exists public.crm_tasks (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  title text not null,
  description text,
  status text not null default 'OPEN' check (status in ('OPEN','IN_PROGRESS','DONE','CANCELLED')),
  priority text not null default 'NORMAL' check (priority in ('LOW','NORMAL','HIGH','URGENT')),
  due_at timestamptz,
  assigned_user_id uuid references public.users(id) on delete set null,
  client_id uuid references public.recruitment_clients(id) on delete cascade,
  contact_id uuid references public.recruitment_contacts(id) on delete set null,
  opportunity_id uuid references public.crm_opportunities(id) on delete cascade,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  completed_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_task_parent_required check (client_id is not null or contact_id is not null or opportunity_id is not null)
);

create table if not exists public.recruitment_client_contracts (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  client_id uuid not null references public.recruitment_clients(id) on delete cascade,
  name text not null,
  contract_type text not null default 'CONTINGENCY' check (contract_type in ('CONTINGENCY','RETAINED','RPO','TEMP_STAFFING','CONTRACT_STAFFING','MASTER_SERVICE','PROJECT','OTHER')),
  status text not null default 'DRAFT' check (status in ('DRAFT','PENDING_SIGNATURE','ACTIVE','EXPIRED','TERMINATED','SUPERSEDED')),
  fee_type text check (fee_type is null or fee_type in ('PERCENTAGE','FIXED','HOURLY_MARKUP','MARGIN','CUSTOM')),
  fee_percent numeric check (fee_percent is null or (fee_percent >= 0 and fee_percent <= 100)),
  fee_amount numeric check (fee_amount is null or fee_amount >= 0),
  currency_code text check (currency_code is null or currency_code ~ '^[A-Z]{3}$'),
  payment_terms_days integer check (payment_terms_days is null or payment_terms_days >= 0),
  guarantee_days integer check (guarantee_days is null or guarantee_days >= 0),
  effective_from date,
  effective_to date,
  exclusivity boolean not null default false,
  notes text,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint client_contract_date_range check (effective_from is null or effective_to is null or effective_from <= effective_to)
);

create table if not exists public.crm_custom_field_values (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  entity_type text not null check (entity_type in ('CLIENT','CONTACT','OPPORTUNITY')),
  entity_id uuid not null,
  field_id uuid not null references public.custom_field_definitions(id) on delete cascade,
  value jsonb,
  updated_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(agency_id,entity_type,entity_id,field_id)
);

-- Operational indexes for bounded CRM screens.
create index if not exists idx_xzr_clients_search on public.recruitment_clients(agency_id,archived_at,status,updated_at desc);
create index if not exists idx_xzr_clients_owner on public.recruitment_clients(agency_id,owner_user_id,status,updated_at desc);
create index if not exists idx_xzr_clients_country on public.recruitment_clients(agency_id,country_code,status,updated_at desc);
create index if not exists idx_xzr_contacts_search on public.recruitment_contacts(agency_id,client_id,archived_at,updated_at desc);
create index if not exists idx_xzr_contacts_email on public.recruitment_contacts(agency_id,lower(email)) where email is not null;
create index if not exists idx_xzr_opportunities_stage on public.crm_opportunities(agency_id,pipeline_id,stage_id,status,updated_at desc);
create index if not exists idx_xzr_opportunities_owner on public.crm_opportunities(agency_id,owner_user_id,status,expected_close_date);
create index if not exists idx_xzr_activities_client on public.crm_activities(agency_id,client_id,occurred_at desc);
create index if not exists idx_xzr_activities_opportunity on public.crm_activities(agency_id,opportunity_id,occurred_at desc);
create index if not exists idx_xzr_tasks_due on public.crm_tasks(agency_id,status,due_at,priority);
create index if not exists idx_xzr_contracts_client on public.recruitment_client_contracts(agency_id,client_id,status,updated_at desc);
create index if not exists idx_xzr_crm_custom_values_entity on public.crm_custom_field_values(agency_id,entity_type,entity_id);

-- Direct browser access stays deny-by-default. Session-aware RPCs are the data boundary.
do $do$
declare t text;
begin
  foreach t in array array['recruitment_clients','recruitment_contacts','crm_opportunities','crm_opportunity_stage_history','crm_activities','crm_tasks','recruitment_client_contracts','crm_custom_field_values'] loop
    execute format('alter table public.%I enable row level security',t);
    if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)',t);
    end if;
  end loop;
end $do$;
