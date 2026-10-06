import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');
const importSource=async(p)=>import(`data:text/javascript;base64,${Buffer.from(read(p)).toString('base64')}`);
const csv=await importSource('lib/csv.js');
const fixtures=JSON.parse(read('tests/fixtures/step3-agencies.json'));
const core=read('supabase/migrations/20260926151909_20260903_step3_agency_onboarding_core.sql');
const rpcs=read('supabase/migrations/20260926151915_20260903_step3_agency_onboarding_rpcs.sql');
const imports=read('supabase/migrations/20260926151920_20260903_step3_safe_import_foundation.sql');
const advanced=read('supabase/migrations/20260926151927_20260903_step3_advanced_configuration_foundations.sql');
const wizard=read('app/components/OnboardingWizard.js');
const settings=read('app/components/SettingsCenter.js');
const dashboard=read('app/dashboard/page.js');
const shell=read('app/components/AppShell.js');
const commands=read('app/components/CommandPalette.js');
const table=read('app/components/EnterpriseTable.js');
const css=read('app/step3.css');
const onboardingApi=read('app/api/onboarding/route.js');
const configApi=read('app/api/config/route.js');
const importApi=read('app/api/import/route.js');
const auth=read('lib/auth.js');
const signup=read('app/api/auth/signup/route.js');
const logo=read('public/xzrecruiter-logo.svg');
const step2=read('supabase/migrations/20260926151850_20260903_step2_global_operating_foundation.sql');

for(const p of [
  'supabase/migrations/20260926151841_20260903_step1_foundation_security_branding.sql',
  'supabase/migrations/20260926151845_20260903_step1_workspace_session_binding.sql',
  'supabase/migrations/20260926151850_20260903_step2_global_operating_foundation.sql',
  'supabase/migrations/20260926151859_20260903_step2_global_integrity_hardening.sql',
  'app/components/AppShell.js','app/components/EnterpriseTable.js','app/components/FormControls.js','lib/globalization.js'
]) assert.ok(fs.existsSync(path.join(root,p)),`Missing inherited source: ${p}`);

assert.ok(auth.includes("'__Host-xz_session'"));
assert.ok(auth.includes('httpOnly: true'));
assert.ok(auth.includes("sameSite: 'lax'"));
assert.ok(/requiresEmailVerification\s*:\s*true/.test(signup));
assert.ok(fs.existsSync(path.join(root,'app/api/auth/verify-email/route.js')));
assert.ok(fs.existsSync(path.join(root,'app/api/auth/password-reset/complete/route.js')));
assert.ok(!logo.includes('>XZ</text>'));
assert.ok(logo.includes('>Recruiter</text>'));

for(const code of ['IN','US','CA','GB','DE','FR','IT','NL','ES','IE','CH','SE','DK','NO','AE','SA','QA','BH','KW','OM','SG','AU','NZ']) assert.ok(step2.includes(`('${code}',`),`Step2 market missing ${code}`);
assert.ok(core.includes('references public.global_country_profiles(country_code)'));
assert.ok(rpcs.includes('public.xzrecruiter_valid_timezone'));
assert.ok(!/country_usa|timezone_india|currency_uk/i.test(`${core}\n${rpcs}\n${imports}\n${advanced}`));

assert.equal(fixtures.length,8);
const ids=new Set(fixtures.map((x)=>x.id));
for(const id of ['india-it','us-multi','uk-agency','germany','gcc-bilingual','singapore','australia-multi','new-zealand']) assert.ok(ids.has(id));
assert.ok(fixtures.find((x)=>x.id==='us-multi').timezones.length>=4);
assert.ok(fixtures.find((x)=>x.id==='australia-multi').timezones.includes('Australia/Perth'));
assert.ok(fixtures.find((x)=>x.id==='gcc-bilingual').languages.includes('ar'));
assert.ok(fixtures.find((x)=>x.id==='new-zealand').timezones.includes('Pacific/Chatham'));

const ownedTables=[
  'onboarding_progress','onboarding_section_state','agency_operating_profiles','agency_business_models','agency_market_targets',
  'agency_taxonomy_preferences','agency_icp_profiles','agency_specialization_items','recruitment_pipelines','pipeline_stages',
  'custom_field_groups','custom_field_definitions','saved_views','workspace_departments','workspace_teams','workspace_team_members',
  'workspace_member_profiles','workspace_invitations','workspace_territories','territory_rules','import_batches','import_staging_rows',
  'agency_company_records','custom_layouts','custom_layout_sections','custom_layout_fields','assignment_rules','permission_profiles','member_permission_profiles'
];
const allMigrations=`${core}\n${rpcs}\n${imports}\n${advanced}`;
for(const tableName of ownedTables){
  const source=tableName==='agency_company_records'?imports:allMigrations;
  const at=source.indexOf(`create table if not exists public.${tableName}`);
  assert.ok(at>=0,`Missing ${tableName}`);
  assert.ok(source.slice(at,at+900).includes('agency_id'),`${tableName} is not tenant scoped`);
}
assert.ok(!/\bdrop\s+table\b|\btruncate\b|alter\s+table\s+[^;]+\s+drop\s+column/i.test(allMigrations));
assert.ok(!/delete\s+from\s+public\.(candidates|recruitment_clients|recruitment_contacts|recruitment_jobs|companies|applications)\b/i.test(allMigrations));
for(const tableName of ownedTables) assert.ok(allMigrations.includes(`'${tableName}'`) || allMigrations.includes(`public.${tableName}`));
assert.ok(allMigrations.includes('enable row level security'));
assert.ok(allMigrations.includes('xzrecruiter_data_api_deny'));

assert.ok(rpcs.includes('private.xzrecruiter_session_context'));
assert.ok(rpcs.includes('u.email_verified_at is not null'));
assert.ok(rpcs.includes('s.agency_id'));
assert.ok(rpcs.includes("v_role not in ('OWNER','ADMIN')"));
for(const api of [onboardingApi,configApi,importApi]){
  assert.ok(api.includes('sessionToken()'));
  assert.ok(api.includes('sameOrigin'));
  assert.ok(!/body\.agencyId|body\.agency_id|p_agency_id/.test(api),'Client-controlled agency id found in API');
}

assert.ok(wizard.includes('Quick Setup'));
assert.ok(wizard.includes('Advanced Setup'));
assert.ok(wizard.includes("setTimeout(async()=>"));
assert.ok(wizard.includes('850'));
assert.ok(wizard.includes('Resume later'));
assert.ok(rpcs.includes("array['profile','markets','industries','icp','specialization','pipelines']"));
assert.ok(rpcs.includes("onboarding_status='COMPLETED'"));
assert.ok(dashboard.includes("onboarding.progress?.status !== 'COMPLETED'"));
assert.ok(dashboard.includes("redirect('/onboarding')"));
assert.ok(dashboard.includes('realMetricTotal > 0'), 'Metrics must be gated on persisted workspace records');
assert.ok(dashboard.includes('Your next hire starts here.'), 'Empty workspaces need a clear next action');
assert.ok(dashboard.includes('Workspace blueprint'));

for(const domain of ['INDUSTRY','COMPANY_SIZE','COMPANY_TYPE','FUNDING_STAGE','JOB_FUNCTION','SENIORITY','EMPLOYMENT_TYPE','WORK_AUTHORIZATION_STATUS']) assert.ok(rpcs.includes(`'${domain}'`) || core.includes(`'${domain}'`));
assert.ok(core.includes("'TECH_SOFTWARE'"));
assert.ok(core.includes("'TECH_SAAS'"));
assert.ok(core.includes("'HEALTH_BIOTECH'"));
assert.ok(rpcs.includes('xzrecruiter_add_custom_taxonomy'));
assert.ok(rpcs.includes('agency_id=v_agency_id'));

for(const token of ['employee_growth_preference','hiring_volume_preference','remote_first_preference','company_scope','revenue_bands']) assert.ok(core.includes(token));
for(const token of ["'RECRUITMENT'","'CANDIDATE'","'SALARY_BAND'","'NOTICE_PERIOD'","'WORKPLACE'"]) assert.ok(core.includes(token)||rpcs.includes(token));

for(const stage of ['NEW','APPLIED','SCREENING','QUALIFIED','SHORTLISTED','SUBMITTED','INTERVIEW','OFFER','PLACED','REJECTED','WITHDRAWN','ON_HOLD']) assert.ok(rpcs.includes(`'${stage}'`),`Recruitment stage missing ${stage}`);
for(const stage of ['TARGET_ACCOUNT','LEAD','CONTACTED','CONVERSATION','MEETING','OPPORTUNITY','CLIENT','REQUIREMENT','PLACEMENT','LOST','DISQUALIFIED','NURTURE']) assert.ok(rpcs.includes(`'${stage}'`),`BD stage missing ${stage}`);
assert.ok(rpcs.includes('required_fields'));
assert.ok(rpcs.includes('rejection_reasons'));
assert.ok(rpcs.includes('transition_rules'));
assert.ok(wizard.includes('draggable'));
assert.ok(wizard.includes('Save pipeline'));

for(const type of ['TEXT','LONG_TEXT','NUMBER','DECIMAL','CURRENCY','PERCENTAGE','DATE','DATETIME','CHECKBOX','SINGLE_SELECT','MULTI_SELECT','EMAIL','PHONE','URL','COUNTRY','TIMEZONE','USER','COMPANY','CANDIDATE','JOB','TAG']) assert.ok(core.includes(`'${type}'`));
assert.ok(core.includes('validation_rules'));
assert.ok(core.includes('custom_field_groups'));
assert.ok(advanced.includes('custom_layouts'));
assert.ok(advanced.includes('custom_layout_sections'));
assert.ok(advanced.includes('assignment_rules'));
assert.ok(advanced.includes('permission_profiles'));
assert.ok(advanced.includes('agency_memberships.role remains authoritative'));
assert.ok(core.includes("filter_logic text not null default 'AND'"));
assert.ok(core.includes("check (filter_logic in ('AND','OR'))"));
assert.ok(table.includes('persistedSavedViews'));
assert.ok(table.includes('onSaveView'));
assert.ok(table.includes('onApplyView'));

for(const role of ['OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER','SOURCER','BUSINESS_DEVELOPMENT','ACCOUNT_MANAGER','HIRING_MANAGER','INTERVIEWER','VIEWER_ANALYST']) assert.ok(core.includes(`'${role}'`));
for(const dimension of ['COUNTRY','REGION','CITY','INDUSTRY','JOB_FUNCTION','ACCOUNT_SEGMENT']) assert.ok(core.includes(`'${dimension}'`));
assert.ok(rpcs.includes('xzrecruiter_save_territory'));

for(const preset of ['TECH_AGENCY','HEALTHCARE_STAFFING','EXEC_SEARCH','FINANCE_ACCOUNTING','ENGINEERING_AGENCY','GENERAL_STAFFING','US_STAFFING','UK_RECRUITMENT','GCC_RECRUITMENT','AU_NZ_RECRUITMENT','INDIA_RECRUITMENT']) assert.ok(core.includes(`'${preset}'`));
assert.ok(wizard.includes('Everything stays editable'));

const parsed=csv.parseCsv('Name,Email,Note\n"Jane, Doe",jane@example.com,"Senior, available"\nJohn,john@example.com,Ready');
assert.deepEqual(parsed.headers,['Name','Email','Note']);
assert.equal(parsed.rows.length,2);
assert.equal(parsed.rows[0].Name,'Jane, Doe');
assert.equal(parsed.rows[0].Note,'Senior, available');
const candidateMapping=csv.suggestMapping(['Candidate Name','Email','Mobile','Country Code'],'CANDIDATE');
assert.equal(candidateMapping.full_name,'Candidate Name');
assert.equal(candidateMapping.email,'Email');
assert.equal(candidateMapping.phone,'Mobile');
assert.equal(candidateMapping.country_code,'Country Code');
assert.ok(imports.includes('idempotency_key'));
assert.ok(imports.includes("v_status:='DUPLICATE'"));
assert.ok(imports.includes("v_status:='INVALID'"));
assert.ok(imports.includes('xzrecruiter_commit_import'));
assert.ok(importApi.includes('body.rows.length > 1000'));
assert.ok(imports.includes('agency_company_records'));
assert.ok(!imports.includes('insert into public.companies'));

assert.ok(settings.includes('company size'));
assert.ok(settings.includes('Configuration Center'));
for(const route of ['/onboarding?edit=1','/settings','/import','/onboarding?section=pipelines&edit=1']) assert.ok(commands.includes(route));
assert.ok(!shell.includes("href: '#'"));
assert.ok(shell.includes("href: '/settings'"));

for(const breakpoint of ['@media(max-width:900px)','@media(max-width:600px)','@media(max-width:480px)','@media(max-width:430px)','@media(max-width:390px)','@media(max-width:360px)']) assert.ok(css.includes(breakpoint),`Missing ${breakpoint}`);
assert.ok(css.includes('[dir="rtl"]'));
assert.ok(css.includes('prefers-reduced-motion'));
assert.ok(css.includes('overflow-x:hidden'));
assert.ok(wizard.includes('mobile-step-strip'));
assert.ok(commands.includes('ArrowDown')&&commands.includes('ArrowUp')&&commands.includes('Enter'));

console.log(`STEP3_QA_PASS agencies=${fixtures.length} tenant_tables=${ownedTables.length} pipelines=ATS+BD imports=staged quick+advanced=true step1+step2=preserved`);
