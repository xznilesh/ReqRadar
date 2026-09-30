-- XZ Recruiter Step 3: advanced configuration foundations.
-- These models extend configuration without replacing Step-1 server-side RBAC.

create table if not exists public.custom_layouts (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  module text not null check (module in ('CANDIDATE','JOB','COMPANY','CLIENT','CONTACT','OPPORTUNITY')),
  name text not null,
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,module,name)
);

create table if not exists public.custom_layout_sections (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  layout_id uuid not null references public.custom_layouts(id) on delete cascade,
  name text not null,
  sort_order integer not null default 100,
  columns smallint not null default 2 check (columns between 1 and 4),
  collapsed_by_default boolean not null default false,
  visible boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (layout_id,name)
);

create table if not exists public.custom_layout_fields (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  section_id uuid not null references public.custom_layout_sections(id) on delete cascade,
  field_id uuid not null references public.custom_field_definitions(id) on delete cascade,
  sort_order integer not null default 100,
  width text not null default 'FULL' check (width in ('FULL','HALF','THIRD','QUARTER')),
  created_at timestamptz not null default now(),
  primary key (agency_id,section_id,field_id)
);

create table if not exists public.assignment_rules (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  module text not null check (module in ('COMPANY','CLIENT','CANDIDATE','JOB','OPPORTUNITY')),
  enabled boolean not null default false,
  priority integer not null default 100,
  match_logic text not null default 'AND' check (match_logic in ('AND','OR')),
  conditions jsonb not null default '[]'::jsonb,
  assignment_type text not null default 'TEAM' check (assignment_type in ('USER','TEAM','TERRITORY','ROUND_ROBIN')),
  assignee_user_id uuid references public.users(id) on delete set null,
  assignee_team_id uuid references public.workspace_teams(id) on delete set null,
  territory_id uuid references public.workspace_territories(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,module,name)
);

create table if not exists public.permission_profiles (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  description text,
  base_rbac_role text not null check (base_rbac_role in ('OWNER','ADMIN','RECRUITER','VIEWER','MEMBER')),
  permissions jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,name)
);

create table if not exists public.member_permission_profiles (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  permission_profile_id uuid not null references public.permission_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (agency_id,user_id,permission_profile_id)
);

-- Permission profiles are configuration metadata only. Step-1 agency_memberships.role remains authoritative
-- until a later security-reviewed authorization layer explicitly consumes these profiles.

create index if not exists idx_xzrecruiter_layouts_module on public.custom_layouts(agency_id,module,active,is_default);
create index if not exists idx_xzrecruiter_layout_sections_order on public.custom_layout_sections(agency_id,layout_id,sort_order);
create index if not exists idx_xzrecruiter_assignment_rules on public.assignment_rules(agency_id,module,enabled,priority);
create index if not exists idx_xzrecruiter_permission_profiles on public.permission_profiles(agency_id,active,name);

do $do$
declare t text;
begin
  foreach t in array array['custom_layouts','custom_layout_sections','custom_layout_fields','assignment_rules','permission_profiles','member_permission_profiles'] loop
    execute format('alter table public.%I enable row level security',t);
    if not exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname='xzrecruiter_data_api_deny') then
      execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using(false) with check(false)',t);
    end if;
  end loop;
end $do$;
