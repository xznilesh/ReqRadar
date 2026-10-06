import fs from 'node:fs';
const required = [
  'app/page.js','app/dashboard/page.js','app/login/page.js','app/signup/page.js','app/verify-email/page.js','app/reset-password/page.js',
  'app/settings/global/page.js','app/settings/page.js','app/onboarding/page.js','app/import/page.js',
  'app/components/Brand.js','app/components/AppShell.js','app/components/WorkspaceSelector.js','app/components/CommandPalette.js',
  'app/components/EnterpriseTable.js','app/components/FormControls.js','app/components/DetailDrawer.js','app/components/ContextActionBar.js','app/components/GlobalSettingsForm.js',
  'app/components/OnboardingWizard.js','app/components/SettingsCenter.js','app/components/ImportWizard.js',
  'app/api/settings/global/route.js','app/api/onboarding/route.js','app/api/config/route.js','app/api/import/route.js',
  'app/api/auth/verify-email/route.js','app/api/auth/password-reset/request/route.js','app/api/auth/password-reset/complete/route.js','app/api/health/ready/route.js',
  'app/step2.css','app/step3.css','lib/db.js','lib/auth.js','lib/globalization.js','lib/global-context.js','lib/onboarding.js','lib/csv.js','i18n/resources.js','public/xzrecruiter-logo.svg',
  'tests/fixtures/global-markets.json','tests/fixtures/step3-agencies.json','scripts/step2-tests.mjs','scripts/step3-tests.mjs',
  'supabase/migrations/20260926151841_20260903_step1_foundation_security_branding.sql','supabase/migrations/20260926151845_20260903_step1_workspace_session_binding.sql',
  'supabase/migrations/20260926151850_20260903_step2_global_operating_foundation.sql','supabase/migrations/20260926151859_20260903_step2_global_integrity_hardening.sql',
  'supabase/migrations/20260926151909_20260903_step3_agency_onboarding_core.sql','supabase/migrations/20260926151915_20260903_step3_agency_onboarding_rpcs.sql',
  'supabase/migrations/20260926151920_20260903_step3_safe_import_foundation.sql','supabase/migrations/20260926151927_20260903_step3_advanced_configuration_foundations.sql'
];
const missing=required.filter((p)=>!fs.existsSync(p));
if(missing.length){console.error('Missing required files:',missing.join(', '));process.exit(1);}

const auth=fs.readFileSync('lib/auth.js','utf8');
const signup=fs.readFileSync('app/api/auth/signup/route.js','utf8');
const logo=fs.readFileSync('public/xzrecruiter-logo.svg','utf8');
const step2=fs.readFileSync('supabase/migrations/20260926151850_20260903_step2_global_operating_foundation.sql','utf8');
const step2Hardening=fs.readFileSync('supabase/migrations/20260926151859_20260903_step2_global_integrity_hardening.sql','utf8');
const step3Files=[
  'supabase/migrations/20260926151909_20260903_step3_agency_onboarding_core.sql','supabase/migrations/20260926151915_20260903_step3_agency_onboarding_rpcs.sql',
  'supabase/migrations/20260926151920_20260903_step3_safe_import_foundation.sql','supabase/migrations/20260926151927_20260903_step3_advanced_configuration_foundations.sql'
].map((p)=>fs.readFileSync(p,'utf8')).join('\n');

if(!auth.includes('__Host-xz_session')||!auth.includes('httpOnly: true')) throw new Error('Secure Step-1 session invariant missing');
if(!/requiresEmailVerification\s*:\s*true/.test(signup)) throw new Error('Mandatory Step-1 verification contract missing');
if(logo.includes('>XZ</text>')||!logo.includes('>Recruiter</text>')) throw new Error('XZ Recruiter brand invariant failed');
if(/\bdrop\s+table\b|\btruncate\b|alter\s+table\s+[^;]+\s+drop\s+column/i.test(`${step2}\n${step2Hardening}\n${step3Files}`)) throw new Error('Destructive schema statement detected');
if(!step2.includes('workspace_global_settings')||!step2.includes('global_timezones')) throw new Error('Persisted Step-2 globalization missing');
if(!step2Hardening.includes('interviews_timezone_iana_check')||!step2Hardening.includes('taxonomy_labels_agency')) throw new Error('Step-2 integrity hardening missing');
if(!step3Files.includes('onboarding_progress')||!step3Files.includes('recruitment_pipelines')||!step3Files.includes('custom_field_definitions')||!step3Files.includes('import_batches')) throw new Error('Step-3 persisted configuration missing');
if(!step3Files.includes('private.xzrecruiter_session_context')||!step3Files.includes('u.email_verified_at is not null')) throw new Error('Step-3 verified tenant session gate missing');
console.log('XZ Recruiter Step-1 + Step-2 + Step-3 source verification passed.');
