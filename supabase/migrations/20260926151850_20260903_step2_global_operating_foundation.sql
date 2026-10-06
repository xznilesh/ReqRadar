-- XZ Recruiter Step 2: global recruitment operating foundation.
-- Additive only. Existing recruitment records are preserved.

create or replace function public.xzrecruiter_valid_timezone(p_timezone text)
returns boolean
language sql
stable
set search_path = 'pg_catalog', 'public'
as $$
  select p_timezone is not null and exists (
    select 1 from pg_catalog.pg_timezone_names where name = p_timezone
  );
$$;

create table if not exists public.global_languages (
  language_code text primary key,
  english_name text not null,
  native_name text not null,
  default_locale text not null,
  direction text not null check (direction in ('LTR','RTL')),
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.global_country_profiles (
  country_code text primary key check (country_code ~ '^[A-Z]{2}$'),
  country_name text not null,
  default_locale text not null,
  default_currency text not null check (default_currency ~ '^[A-Z]{3}$'),
  default_timezone text not null,
  default_language_code text not null references public.global_languages(language_code),
  calling_code text not null,
  date_pattern text not null,
  time_pattern text not null default '24h',
  postal_label text not null,
  region_label text not null,
  resume_term text not null,
  salary_annual_term text not null,
  salary_monthly_term text not null,
  week_starts_on smallint not null default 1 check (week_starts_on between 0 and 6),
  working_days smallint[] not null default array[1,2,3,4,5]::smallint[],
  address_rules jsonb not null default '{}'::jsonb,
  supported_languages jsonb not null default '["en"]'::jsonb,
  certified boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint global_country_profile_timezone_valid check (public.xzrecruiter_valid_timezone(default_timezone))
);

create table if not exists public.global_timezones (
  timezone_id text primary key,
  country_code text not null references public.global_country_profiles(country_code) on delete cascade,
  display_name text not null,
  is_default boolean not null default false,
  observes_dst boolean not null default false,
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint global_timezone_valid check (public.xzrecruiter_valid_timezone(timezone_id))
);
create index if not exists idx_xzrecruiter_global_timezones_country on public.global_timezones(country_code, sort_order, timezone_id);

insert into public.global_languages(language_code, english_name, native_name, default_locale, direction) values
('en','English','English','en-GB','LTR'),
('hi','Hindi','हिन्दी','hi-IN','LTR'),
('de','German','Deutsch','de-DE','LTR'),
('fr','French','Français','fr-FR','LTR'),
('it','Italian','Italiano','it-IT','LTR'),
('nl','Dutch','Nederlands','nl-NL','LTR'),
('es','Spanish','Español','es-ES','LTR'),
('ar','Arabic','العربية','ar-AE','RTL')
on conflict (language_code) do update set
  english_name=excluded.english_name, native_name=excluded.native_name,
  default_locale=excluded.default_locale, direction=excluded.direction, enabled=true;

insert into public.global_country_profiles(
  country_code,country_name,default_locale,default_currency,default_timezone,default_language_code,calling_code,
  date_pattern,time_pattern,postal_label,region_label,resume_term,salary_annual_term,salary_monthly_term,
  week_starts_on,working_days,address_rules,supported_languages,certified
) values
('IN','India','en-IN','INR','Asia/Kolkata','en','+91','DD/MM/YYYY','12h','PIN Code','State','Resume','per year','per month',1,array[1,2,3,4,5,6],'{"fields":["address_line_1","address_line_2","locality","district","region","postal_code"],"required":["locality","region","postal_code"]}','["en","hi"]',true),
('US','United States','en-US','USD','America/New_York','en','+1','MM/DD/YYYY','12h','ZIP Code','State','Resume','per year','per month',0,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","region","postal_code"],"required":["locality","region","postal_code"]}','["en","es"]',true),
('CA','Canada','en-CA','CAD','America/Toronto','en','+1','YYYY-MM-DD','12h','Postal Code','Province','Resume','per year','per month',0,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","region","postal_code"],"required":["locality","region","postal_code"]}','["en","fr"]',true),
('GB','United Kingdom','en-GB','GBP','Europe/London','en','+44','DD/MM/YYYY','24h','Postcode','County / Region','CV','per annum','per month',1,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","district","postal_code"],"required":["locality","postal_code"]}','["en"]',true),
('DE','Germany','de-DE','EUR','Europe/Berlin','de','+49','DD.MM.YYYY','24h','Postleitzahl','Bundesland / Region','CV','pro Jahr','pro Monat',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["de","en"]',true),
('FR','France','fr-FR','EUR','Europe/Paris','fr','+33','DD/MM/YYYY','24h','Code postal','Région','CV','par an','par mois',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["fr","en"]',true),
('IT','Italy','it-IT','EUR','Europe/Rome','it','+39','DD/MM/YYYY','24h','CAP','Regione','CV','all’anno','al mese',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["it","en"]',true),
('NL','Netherlands','nl-NL','EUR','Europe/Amsterdam','nl','+31','DD-MM-YYYY','24h','Postcode','Provincie','CV','per jaar','per maand',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["nl","en"]',true),
('ES','Spain','es-ES','EUR','Europe/Madrid','es','+34','DD/MM/YYYY','24h','Código postal','Provincia / Región','CV','al año','al mes',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["es","en"]',true),
('IE','Ireland','en-IE','EUR','Europe/Dublin','en','+353','DD/MM/YYYY','24h','Eircode','County','CV','per annum','per month',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","district","postal_code"],"required":["locality"]}','["en"]',true),
('CH','Switzerland','de-CH','CHF','Europe/Zurich','de','+41','DD.MM.YYYY','24h','Postleitzahl / NPA','Canton','CV','pro Jahr','pro Monat',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["de","fr","it","en"]',true),
('SE','Sweden','sv-SE','SEK','Europe/Stockholm','en','+46','YYYY-MM-DD','24h','Postnummer','Län','CV','per år','per månad',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["en"]',true),
('DK','Denmark','da-DK','DKK','Europe/Copenhagen','en','+45','DD-MM-YYYY','24h','Postnummer','Region','CV','per år','per måned',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["en"]',true),
('NO','Norway','nb-NO','NOK','Europe/Oslo','en','+47','DD.MM.YYYY','24h','Postnummer','Fylke','CV','per år','per måned',1,array[1,2,3,4,5],'{"fields":["address_line_1","locality","region","postal_code"],"required":["locality","postal_code"]}','["en"]',true),
('AE','United Arab Emirates','en-AE','AED','Asia/Dubai','en','+971','DD/MM/YYYY','12h','Postal Code','Emirate','CV','per year','per month',1,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","district","region","postal_code"],"required":["locality","region"]}','["en","ar"]',true),
('SA','Saudi Arabia','ar-SA','SAR','Asia/Riyadh','ar','+966','DD/MM/YYYY','12h','Postal Code','Region','CV','سنوياً','شهرياً',0,array[0,1,2,3,4],'{"fields":["address_line_1","address_line_2","locality","district","region","postal_code"],"required":["locality","region","postal_code"]}','["ar","en"]',true),
('QA','Qatar','en-QA','QAR','Asia/Qatar','en','+974','DD/MM/YYYY','12h','Zone / Postal Code','Municipality','CV','per year','per month',0,array[0,1,2,3,4],'{"fields":["address_line_1","address_line_2","locality","district","region"],"required":["locality"]}','["en","ar"]',true),
('BH','Bahrain','en-BH','BHD','Asia/Bahrain','en','+973','DD/MM/YYYY','12h','Block / Postal Code','Governorate','CV','per year','per month',0,array[0,1,2,3,4],'{"fields":["address_line_1","address_line_2","locality","district","region","postal_code"],"required":["locality"]}','["en","ar"]',true),
('KW','Kuwait','en-KW','KWD','Asia/Kuwait','en','+965','DD/MM/YYYY','12h','Postal Code','Governorate','CV','per year','per month',0,array[0,1,2,3,4],'{"fields":["address_line_1","address_line_2","locality","district","region","postal_code"],"required":["locality"]}','["en","ar"]',true),
('OM','Oman','en-OM','OMR','Asia/Muscat','en','+968','DD/MM/YYYY','12h','Postal Code','Governorate','CV','per year','per month',0,array[0,1,2,3,4],'{"fields":["address_line_1","address_line_2","locality","region","postal_code"],"required":["locality","region"]}','["en","ar"]',true),
('SG','Singapore','en-SG','SGD','Asia/Singapore','en','+65','DD/MM/YYYY','12h','Postal Code','Region','Resume','per year','per month',1,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","postal_code"],"required":["postal_code"]}','["en"]',true),
('AU','Australia','en-AU','AUD','Australia/Sydney','en','+61','DD/MM/YYYY','12h','Postcode','State / Territory','Resume','per year','per month',1,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","region","postal_code"],"required":["locality","region","postal_code"]}','["en"]',true),
('NZ','New Zealand','en-NZ','NZD','Pacific/Auckland','en','+64','DD/MM/YYYY','12h','Postcode','Region','CV','per year','per month',1,array[1,2,3,4,5],'{"fields":["address_line_1","address_line_2","locality","region","postal_code"],"required":["locality","postal_code"]}','["en"]',true)
on conflict (country_code) do update set
  country_name=excluded.country_name, default_locale=excluded.default_locale, default_currency=excluded.default_currency,
  default_timezone=excluded.default_timezone, default_language_code=excluded.default_language_code, calling_code=excluded.calling_code,
  date_pattern=excluded.date_pattern, time_pattern=excluded.time_pattern, postal_label=excluded.postal_label,
  region_label=excluded.region_label, resume_term=excluded.resume_term, salary_annual_term=excluded.salary_annual_term,
  salary_monthly_term=excluded.salary_monthly_term, week_starts_on=excluded.week_starts_on, working_days=excluded.working_days,
  address_rules=excluded.address_rules, supported_languages=excluded.supported_languages, certified=excluded.certified, active=true, updated_at=now();

insert into public.global_timezones(timezone_id,country_code,display_name,is_default,observes_dst,sort_order) values
('Asia/Kolkata','IN','India Standard Time',true,false,1),
('America/New_York','US','Eastern Time — New York',true,true,1),('America/Chicago','US','Central Time — Chicago',false,true,2),('America/Denver','US','Mountain Time — Denver',false,true,3),('America/Los_Angeles','US','Pacific Time — Los Angeles',false,true,4),('America/Anchorage','US','Alaska Time',false,true,5),('Pacific/Honolulu','US','Hawaii Time',false,false,6),
('America/St_Johns','CA','Newfoundland Time',false,true,1),('America/Halifax','CA','Atlantic Time',false,true,2),('America/Toronto','CA','Eastern Time — Toronto',true,true,3),('America/Winnipeg','CA','Central Time — Winnipeg',false,true,4),('America/Regina','CA','Saskatchewan Time',false,false,5),('America/Edmonton','CA','Mountain Time — Edmonton',false,true,6),('America/Vancouver','CA','Pacific Time — Vancouver',false,true,7),
('Europe/London','GB','United Kingdom',true,true,1),('Europe/Berlin','DE','Germany',true,true,1),('Europe/Paris','FR','France',true,true,1),('Europe/Rome','IT','Italy',true,true,1),('Europe/Amsterdam','NL','Netherlands',true,true,1),('Europe/Madrid','ES','Spain',true,true,1),('Europe/Dublin','IE','Ireland',true,true,1),('Europe/Zurich','CH','Switzerland',true,true,1),('Europe/Stockholm','SE','Sweden',true,true,1),('Europe/Copenhagen','DK','Denmark',true,true,1),('Europe/Oslo','NO','Norway',true,true,1),
('Asia/Dubai','AE','Dubai / Abu Dhabi',true,false,1),('Asia/Riyadh','SA','Saudi Arabia',true,false,1),('Asia/Qatar','QA','Qatar',true,false,1),('Asia/Bahrain','BH','Bahrain',true,false,1),('Asia/Kuwait','KW','Kuwait',true,false,1),('Asia/Muscat','OM','Oman',true,false,1),('Asia/Singapore','SG','Singapore',true,false,1),
('Australia/Sydney','AU','Sydney / Canberra',true,true,1),('Australia/Melbourne','AU','Melbourne',false,true,2),('Australia/Brisbane','AU','Brisbane',false,false,3),('Australia/Adelaide','AU','Adelaide',false,true,4),('Australia/Perth','AU','Perth',false,false,5),('Australia/Darwin','AU','Darwin',false,false,6),('Australia/Hobart','AU','Hobart',false,true,7),
('Pacific/Auckland','NZ','Auckland / Wellington',true,true,1),('Pacific/Chatham','NZ','Chatham Islands',false,true,2)
on conflict (timezone_id) do update set country_code=excluded.country_code, display_name=excluded.display_name,
  is_default=excluded.is_default, observes_dst=excluded.observes_dst, sort_order=excluded.sort_order, active=true;

create table if not exists public.workspace_global_settings (
  agency_id uuid primary key references public.agencies(id) on delete cascade,
  country_code text not null references public.global_country_profiles(country_code),
  locale text not null,
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  timezone_id text not null,
  language_code text not null references public.global_languages(language_code),
  date_pattern_override text,
  time_format text not null default 'AUTO' check (time_format in ('AUTO','12h','24h')),
  viewer_currency_mode text not null default 'ORIGINAL' check (viewer_currency_mode in ('ORIGINAL','DISPLAY_ONLY')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workspace_global_timezone_valid check (public.xzrecruiter_valid_timezone(timezone_id))
);

create table if not exists public.workspace_markets (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  country_code text not null references public.global_country_profiles(country_code),
  locale_override text,
  currency_override text check (currency_override is null or currency_override ~ '^[A-Z]{3}$'),
  timezone_override text,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id,country_code),
  constraint workspace_market_timezone_valid check (timezone_override is null or public.xzrecruiter_valid_timezone(timezone_override))
);

create table if not exists public.recruitment_offices (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name text not null,
  country_code text not null references public.global_country_profiles(country_code),
  timezone_id text not null,
  locale text,
  currency_code text check (currency_code is null or currency_code ~ '^[A-Z]{3}$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recruitment_office_timezone_valid check (public.xzrecruiter_valid_timezone(timezone_id))
);
create index if not exists idx_xzrecruiter_offices_agency on public.recruitment_offices(agency_id,active,name);

create table if not exists public.user_global_preferences (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  locale text,
  timezone_id text,
  language_code text references public.global_languages(language_code),
  currency_code text check (currency_code is null or currency_code ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agency_id,user_id),
  constraint user_global_timezone_valid check (timezone_id is null or public.xzrecruiter_valid_timezone(timezone_id))
);

create table if not exists public.workspace_addresses (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  country_code text not null references public.global_country_profiles(country_code),
  address_line_1 text,
  address_line_2 text,
  locality text,
  district text,
  region text,
  postal_code text,
  formatted_label text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_xzrecruiter_addresses_entity on public.workspace_addresses(agency_id,entity_type,entity_id);

create table if not exists public.compensation_packages (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  period text not null check (period in ('HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL')),
  amount_min numeric,
  amount_max numeric,
  gross_net text not null default 'UNSPECIFIED' check (gross_net in ('GROSS','NET','UNSPECIFIED')),
  bonus_amount numeric,
  commission_amount numeric,
  ote_amount numeric,
  equity text,
  allowances jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint compensation_amounts_nonnegative check (
    coalesce(amount_min,0) >= 0 and coalesce(amount_max,0) >= 0 and
    coalesce(bonus_amount,0) >= 0 and coalesce(commission_amount,0) >= 0 and coalesce(ote_amount,0) >= 0
  ),
  constraint compensation_range_valid check (amount_min is null or amount_max is null or amount_min <= amount_max)
);
create index if not exists idx_xzrecruiter_compensation_entity on public.compensation_packages(agency_id,entity_type,entity_id);

create table if not exists public.work_authorizations (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid not null references public.agencies(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  country_code text not null references public.global_country_profiles(country_code),
  status_code text not null,
  visa_required boolean,
  sponsorship_required boolean,
  sponsorship_available boolean,
  valid_until date,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agency_id,candidate_id,country_code,status_code)
);
create index if not exists idx_xzrecruiter_work_auth_candidate on public.work_authorizations(agency_id,candidate_id,country_code);

create table if not exists public.taxonomy_nodes (
  id uuid primary key default gen_random_uuid(),
  agency_id uuid references public.agencies(id) on delete cascade,
  domain text not null,
  code text not null,
  label text not null,
  parent_id uuid references public.taxonomy_nodes(id) on delete cascade,
  level smallint not null default 0 check (level between 0 and 8),
  sort_order integer not null default 100,
  metadata jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists uq_xzrecruiter_global_taxonomy_code on public.taxonomy_nodes(domain,code) where agency_id is null;
create unique index if not exists uq_xzrecruiter_agency_taxonomy_code on public.taxonomy_nodes(agency_id,domain,code) where agency_id is not null;
create index if not exists idx_xzrecruiter_taxonomy_lookup on public.taxonomy_nodes(domain,agency_id,parent_id,sort_order) where active=true;

create table if not exists public.taxonomy_labels (
  taxonomy_id uuid not null references public.taxonomy_nodes(id) on delete cascade,
  locale text not null,
  label text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (taxonomy_id,locale)
);

-- Entity-level globalization. These are nullable to avoid rewriting legacy records.
alter table public.users add column if not exists locale text;
alter table public.users add column if not exists timezone text;
alter table public.users add column if not exists language_code text;
alter table public.companies add column if not exists locale text;
alter table public.companies add column if not exists timezone text;
alter table public.recruitment_clients add column if not exists country_code text;
alter table public.recruitment_clients add column if not exists locale text;
alter table public.recruitment_clients add column if not exists timezone text;
alter table public.recruitment_clients add column if not exists currency_code text;
alter table public.recruitment_jobs add column if not exists country_code text;
alter table public.recruitment_jobs add column if not exists locale text;
alter table public.recruitment_jobs add column if not exists timezone text;
alter table public.recruitment_jobs add column if not exists salary_period text;
alter table public.recruitment_jobs add column if not exists salary_gross_net text;
alter table public.candidates add column if not exists country_code text;
alter table public.candidates add column if not exists locale text;
alter table public.candidates add column if not exists timezone text;

-- Seed reusable taxonomies. Labels are data, not presentation logic.
insert into public.taxonomy_nodes(domain,code,label,sort_order) values
('COMPANY_SIZE','1_10','1–10',10),('COMPANY_SIZE','11_50','11–50',20),('COMPANY_SIZE','51_200','51–200',30),('COMPANY_SIZE','201_500','201–500',40),('COMPANY_SIZE','501_1000','501–1,000',50),('COMPANY_SIZE','1001_5000','1,001–5,000',60),('COMPANY_SIZE','5001_10000','5,001–10,000',70),('COMPANY_SIZE','10001_50000','10,001–50,000',80),('COMPANY_SIZE','50001_100000','50,001–100,000',90),('COMPANY_SIZE','100000_PLUS','100,000+',100),
('COMPANY_TYPE','PRIVATE','Private',10),('COMPANY_TYPE','PUBLIC','Public',20),('COMPANY_TYPE','STARTUP','Startup',30),('COMPANY_TYPE','GOVERNMENT','Government',40),('COMPANY_TYPE','NONPROFIT','Nonprofit',50),('COMPANY_TYPE','PARTNERSHIP','Partnership',60),('COMPANY_TYPE','SUBSIDIARY','Subsidiary',70),('COMPANY_TYPE','AGENCY','Agency',80),('COMPANY_TYPE','VC_BACKED','VC-backed',90),('COMPANY_TYPE','PE_BACKED','PE-backed',100),('COMPANY_TYPE','BOOTSTRAPPED','Bootstrapped',110),
('FUNDING_STAGE','PRE_SEED','Pre-seed',10),('FUNDING_STAGE','SEED','Seed',20),('FUNDING_STAGE','SERIES_A','Series A',30),('FUNDING_STAGE','SERIES_B','Series B',40),('FUNDING_STAGE','SERIES_C','Series C',50),('FUNDING_STAGE','SERIES_D_PLUS','Series D+',60),('FUNDING_STAGE','GROWTH','Growth',70),('FUNDING_STAGE','PRE_IPO','Pre-IPO',80),('FUNDING_STAGE','PUBLIC','Public',90),('FUNDING_STAGE','BOOTSTRAPPED','Bootstrapped',100),
('SENIORITY','INTERN','Intern',10),('SENIORITY','ENTRY','Entry',20),('SENIORITY','ASSOCIATE','Associate',30),('SENIORITY','MID','Mid',40),('SENIORITY','SENIOR','Senior',50),('SENIORITY','LEAD','Lead',60),('SENIORITY','MANAGER','Manager',70),('SENIORITY','SENIOR_MANAGER','Senior Manager',80),('SENIORITY','HEAD','Head',90),('SENIORITY','DIRECTOR','Director',100),('SENIORITY','SENIOR_DIRECTOR','Senior Director',110),('SENIORITY','VP','VP',120),('SENIORITY','SVP','SVP',130),('SENIORITY','EVP','EVP',140),('SENIORITY','C_LEVEL','C-Level',150),('SENIORITY','BOARD','Board',160),
('EMPLOYMENT_TYPE','PERMANENT','Permanent',10),('EMPLOYMENT_TYPE','FULL_TIME','Full-time',20),('EMPLOYMENT_TYPE','PART_TIME','Part-time',30),('EMPLOYMENT_TYPE','CONTRACT','Contract',40),('EMPLOYMENT_TYPE','TEMPORARY','Temporary',50),('EMPLOYMENT_TYPE','FREELANCE','Freelance',60),('EMPLOYMENT_TYPE','INTERNSHIP','Internship',70),
('WORK_AUTHORIZATION_STATUS','CITIZEN','Citizen',10),('WORK_AUTHORIZATION_STATUS','PERMANENT_RESIDENT','Permanent resident',20),('WORK_AUTHORIZATION_STATUS','WORK_PERMIT','Work permit',30),('WORK_AUTHORIZATION_STATUS','VISA_REQUIRED','Visa required',40),('WORK_AUTHORIZATION_STATUS','SPONSORSHIP_REQUIRED','Sponsorship required',50),('WORK_AUTHORIZATION_STATUS','SPONSORSHIP_AVAILABLE','Sponsorship available',60),('WORK_AUTHORIZATION_STATUS','UNRESTRICTED','Unrestricted',70),('WORK_AUTHORIZATION_STATUS','UNKNOWN','Unknown / not provided',80),
('JOB_FUNCTION','ENGINEERING','Engineering',10),('JOB_FUNCTION','IT','IT',20),('JOB_FUNCTION','DATA','Data',30),('JOB_FUNCTION','AI','AI',40),('JOB_FUNCTION','CYBERSECURITY','Cybersecurity',50),('JOB_FUNCTION','PRODUCT','Product',60),('JOB_FUNCTION','DESIGN','Design',70),('JOB_FUNCTION','SALES','Sales',80),('JOB_FUNCTION','MARKETING','Marketing',90),('JOB_FUNCTION','FINANCE','Finance',100),('JOB_FUNCTION','ACCOUNTING','Accounting',110),('JOB_FUNCTION','HR','HR',120),('JOB_FUNCTION','LEGAL','Legal',130),('JOB_FUNCTION','OPERATIONS','Operations',140),('JOB_FUNCTION','SUPPLY_CHAIN','Supply Chain',150),('JOB_FUNCTION','PROCUREMENT','Procurement',160),('JOB_FUNCTION','HEALTHCARE','Healthcare',170),('JOB_FUNCTION','MANUFACTURING','Manufacturing',180),('JOB_FUNCTION','CUSTOMER_SUCCESS','Customer Success',190),('JOB_FUNCTION','CUSTOMER_SUPPORT','Customer Support',200),('JOB_FUNCTION','EXECUTIVE','Executive',210),('JOB_FUNCTION','ADMINISTRATION','Administration',220),('JOB_FUNCTION','SKILLED_TRADES','Skilled Trades',230)
on conflict do nothing;

insert into public.taxonomy_nodes(domain,code,label,sort_order) values
('INDUSTRY','TECHNOLOGY','Technology',10),('INDUSTRY','SOFTWARE_SAAS','Software / SaaS',20),('INDUSTRY','AI_ML','AI / ML',30),('INDUSTRY','CYBERSECURITY','Cybersecurity',40),('INDUSTRY','IT_SERVICES','IT Services',50),('INDUSTRY','TELECOM','Telecom',60),('INDUSTRY','SEMICONDUCTORS','Semiconductors',70),('INDUSTRY','ELECTRONICS','Electronics',80),('INDUSTRY','BANKING','Banking',90),('INDUSTRY','FINTECH','FinTech',100),('INDUSTRY','INSURANCE','Insurance',110),('INDUSTRY','FINANCIAL_SERVICES','Financial Services',120),('INDUSTRY','ACCOUNTING','Accounting',130),('INDUSTRY','INVESTMENT','Investment',140),('INDUSTRY','HEALTHCARE','Healthcare',150),('INDUSTRY','HOSPITALS','Hospitals',160),('INDUSTRY','PHARMA','Pharma',170),('INDUSTRY','BIOTECH','Biotech',180),('INDUSTRY','MEDICAL_DEVICES','Medical Devices',190),('INDUSTRY','MANUFACTURING','Manufacturing',200),('INDUSTRY','AUTOMOTIVE','Automotive',210),('INDUSTRY','AEROSPACE','Aerospace',220),('INDUSTRY','DEFENCE','Defence',230),('INDUSTRY','CONSTRUCTION','Construction',240),('INDUSTRY','REAL_ESTATE','Real Estate',250),('INDUSTRY','ENERGY','Energy',260),('INDUSTRY','OIL_GAS','Oil & Gas',270),('INDUSTRY','RENEWABLES','Renewables',280),('INDUSTRY','UTILITIES','Utilities',290),('INDUSTRY','RETAIL','Retail',300),('INDUSTRY','ECOMMERCE','E-commerce',310),('INDUSTRY','FMCG','FMCG',320),('INDUSTRY','CONSUMER_GOODS','Consumer Goods',330),('INDUSTRY','HOSPITALITY','Hospitality',340),('INDUSTRY','TRAVEL','Travel',350),('INDUSTRY','AVIATION','Aviation',360),('INDUSTRY','LOGISTICS','Logistics',370),('INDUSTRY','TRANSPORTATION','Transportation',380),('INDUSTRY','SUPPLY_CHAIN','Supply Chain',390),('INDUSTRY','EDUCATION','Education',400),('INDUSTRY','EDTECH','EdTech',410),('INDUSTRY','MEDIA','Media',420),('INDUSTRY','ADVERTISING','Advertising',430),('INDUSTRY','MARKETING','Marketing',440),('INDUSTRY','ENTERTAINMENT','Entertainment',450),('INDUSTRY','GAMING','Gaming',460),('INDUSTRY','LEGAL','Legal',470),('INDUSTRY','CONSULTING','Consulting',480),('INDUSTRY','PROFESSIONAL_SERVICES','Professional Services',490),('INDUSTRY','STAFFING_RECRUITING','Staffing & Recruiting',500),('INDUSTRY','GOVERNMENT','Government',510),('INDUSTRY','NONPROFIT','Nonprofit',520),('INDUSTRY','AGRICULTURE','Agriculture',530),('INDUSTRY','MINING','Mining',540),('INDUSTRY','CHEMICALS','Chemicals',550),('INDUSTRY','TEXTILES','Textiles',560),('INDUSTRY','APPAREL','Apparel',570),('INDUSTRY','LUXURY','Luxury',580),('INDUSTRY','SPORTS','Sports',590)
on conflict do nothing;

-- Initialize existing workspaces from their current country/timezone values without rewriting them.
insert into public.workspace_global_settings(agency_id,country_code,locale,currency_code,timezone_id,language_code)
select a.id,
       case when c.country_code is null then 'GB' else a.country end,
       coalesce(c.default_locale,'en-GB'),
       coalesce(c.default_currency,'GBP'),
       case when public.xzrecruiter_valid_timezone(a.timezone) then a.timezone else coalesce(c.default_timezone,'Europe/London') end,
       coalesce(c.default_language_code,'en')
from public.agencies a
left join public.global_country_profiles c on c.country_code=a.country
on conflict (agency_id) do nothing;

insert into public.workspace_markets(agency_id,country_code,enabled)
select agency_id,country_code,true from public.workspace_global_settings
on conflict (agency_id,country_code) do nothing;

-- Tenant-owned tables are API-deny by default; session-aware SECURITY DEFINER RPCs mediate access.
do $do$
declare t text;
begin
  foreach t in array array['workspace_global_settings','workspace_markets','recruitment_offices','user_global_preferences','workspace_addresses','compensation_packages','work_authorizations','taxonomy_nodes','taxonomy_labels'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists xzrecruiter_data_api_deny on public.%I', t);
    execute format('create policy xzrecruiter_data_api_deny on public.%I for all to anon, authenticated using (false) with check (false)', t);
  end loop;
end $do$;

create or replace function public.xzrecruiter_global_context(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path='public','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;
  v_user_id uuid;
  v_settings jsonb;
  v_countries jsonb;
  v_timezones jsonb;
  v_languages jsonb;
begin
  select s.agency_id,s.user_id into v_agency_id,v_user_id
  from public.user_sessions s
  join public.agency_memberships am on am.agency_id=s.agency_id and am.user_id=s.user_id
  join public.users u on u.id=s.user_id and u.email_verified_at is not null
  where s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and s.revoked_at is null and s.expires_at>now() and s.agency_id is not null
  limit 1;
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;

  select to_jsonb(x) into v_settings from (
    select s.agency_id,s.country_code,s.locale,s.currency_code,s.timezone_id,s.language_code,s.time_format,s.viewer_currency_mode,
           c.country_name,c.calling_code,c.date_pattern,c.postal_label,c.region_label,c.resume_term,c.salary_annual_term,c.salary_monthly_term,
           c.week_starts_on,c.working_days,c.address_rules,l.direction
    from public.workspace_global_settings s
    join public.global_country_profiles c on c.country_code=s.country_code
    join public.global_languages l on l.language_code=s.language_code
    where s.agency_id=v_agency_id
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.country_name),'[]'::jsonb) into v_countries from (
    select country_code,country_name,default_locale,default_currency,default_timezone,default_language_code,calling_code,date_pattern,time_pattern,
           postal_label,region_label,resume_term,salary_annual_term,salary_monthly_term,week_starts_on,working_days,address_rules,supported_languages,certified
    from public.global_country_profiles where active=true
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.country_code,x.sort_order,x.display_name),'[]'::jsonb) into v_timezones from (
    select timezone_id,country_code,display_name,is_default,observes_dst,sort_order
    from public.global_timezones where active=true
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.english_name),'[]'::jsonb) into v_languages from (
    select language_code,english_name,native_name,default_locale,direction from public.global_languages where enabled=true
  ) x;

  return jsonb_build_object('ok',true,'workspace_id',v_agency_id,'user_id',v_user_id,'settings',v_settings,
    'countries',v_countries,'timezones',v_timezones,'languages',v_languages);
end;
$function$;

create or replace function public.xzrecruiter_update_global_settings(
  p_token text,p_country_code text,p_locale text,p_currency_code text,p_timezone_id text,p_language_code text,p_time_format text default 'AUTO'
)
returns jsonb
language plpgsql
security definer
set search_path='public','extensions','pg_temp'
as $function$
declare
  v_agency_id uuid;
  v_user_id uuid;
  v_role text;
  v_country text:=upper(btrim(coalesce(p_country_code,'')));
  v_currency text:=upper(btrim(coalesce(p_currency_code,'')));
  v_locale text:=btrim(coalesce(p_locale,''));
  v_timezone text:=btrim(coalesce(p_timezone_id,''));
  v_language text:=lower(btrim(coalesce(p_language_code,'')));
begin
  select s.agency_id,s.user_id,am.role into v_agency_id,v_user_id,v_role
  from public.user_sessions s
  join public.agency_memberships am on am.agency_id=s.agency_id and am.user_id=s.user_id
  join public.users u on u.id=s.user_id and u.email_verified_at is not null
  where s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and s.revoked_at is null and s.expires_at>now() and s.agency_id is not null
  limit 1;
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  if v_role not in ('OWNER','ADMIN') then return jsonb_build_object('ok',false,'error','forbidden'); end if;
  if not exists(select 1 from public.global_country_profiles where country_code=v_country and active=true) then
    return jsonb_build_object('ok',false,'error','invalid_country');
  end if;
  if v_locale !~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$' then return jsonb_build_object('ok',false,'error','invalid_locale'); end if;
  if v_currency !~ '^[A-Z]{3}$' then return jsonb_build_object('ok',false,'error','invalid_currency'); end if;
  if not public.xzrecruiter_valid_timezone(v_timezone) then return jsonb_build_object('ok',false,'error','invalid_timezone'); end if;
  if not exists(select 1 from public.global_languages where language_code=v_language and enabled=true) then
    return jsonb_build_object('ok',false,'error','invalid_language');
  end if;
  if coalesce(p_time_format,'AUTO') not in ('AUTO','12h','24h') then return jsonb_build_object('ok',false,'error','invalid_time_format'); end if;

  insert into public.workspace_global_settings(agency_id,country_code,locale,currency_code,timezone_id,language_code,time_format)
  values(v_agency_id,v_country,v_locale,v_currency,v_timezone,v_language,coalesce(p_time_format,'AUTO'))
  on conflict(agency_id) do update set country_code=excluded.country_code,locale=excluded.locale,currency_code=excluded.currency_code,
    timezone_id=excluded.timezone_id,language_code=excluded.language_code,time_format=excluded.time_format,updated_at=now();

  insert into public.workspace_markets(agency_id,country_code,enabled) values(v_agency_id,v_country,true)
  on conflict(agency_id,country_code) do update set enabled=true,updated_at=now();

  update public.agencies set country=v_country,timezone=v_timezone,updated_at=now() where id=v_agency_id;
  update public.users set locale=v_locale,timezone=v_timezone,language_code=v_language,updated_at=now() where id=v_user_id;

  insert into public.user_global_preferences(agency_id,user_id,locale,timezone_id,language_code,currency_code)
  values(v_agency_id,v_user_id,v_locale,v_timezone,v_language,v_currency)
  on conflict(agency_id,user_id) do update set locale=excluded.locale,timezone_id=excluded.timezone_id,
    language_code=excluded.language_code,currency_code=excluded.currency_code,updated_at=now();

  insert into public.audit_events(id,agency_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(gen_random_uuid(),v_agency_id,v_user_id,'settings.global_updated','agency',v_agency_id,
    jsonb_build_object('country_code',v_country,'locale',v_locale,'currency_code',v_currency,'timezone_id',v_timezone,'language_code',v_language));

  return jsonb_build_object('ok',true);
end;
$function$;

create or replace function public.xzrecruiter_taxonomy(p_token text,p_domain text)
returns jsonb
language plpgsql
stable
security definer
set search_path='public','extensions','pg_temp'
as $function$
declare v_agency_id uuid; v_domain text:=upper(btrim(coalesce(p_domain,''))); v_rows jsonb;
begin
  select s.agency_id into v_agency_id
  from public.user_sessions s
  join public.agency_memberships am on am.agency_id=s.agency_id and am.user_id=s.user_id
  join public.users u on u.id=s.user_id and u.email_verified_at is not null
  where s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') and s.revoked_at is null and s.expires_at>now()
  limit 1;
  if v_agency_id is null then return jsonb_build_object('ok',false,'error','unauthorized'); end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.level,x.sort_order,x.label),'[]'::jsonb) into v_rows from (
    select id,domain,code,label,parent_id,level,sort_order,metadata,agency_id is not null as custom
    from public.taxonomy_nodes where domain=v_domain and active=true and (agency_id is null or agency_id=v_agency_id)
  ) x;
  return jsonb_build_object('ok',true,'domain',v_domain,'items',v_rows);
end;
$function$;

revoke all on function public.xzrecruiter_global_context(text) from public,authenticated;
grant execute on function public.xzrecruiter_global_context(text) to anon;
revoke all on function public.xzrecruiter_update_global_settings(text,text,text,text,text,text,text) from public,authenticated;
grant execute on function public.xzrecruiter_update_global_settings(text,text,text,text,text,text,text) to anon;
revoke all on function public.xzrecruiter_taxonomy(text,text) from public,authenticated;
grant execute on function public.xzrecruiter_taxonomy(text,text) to anon;
