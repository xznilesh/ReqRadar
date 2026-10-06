import fs from 'node:fs';
const files=['supabase/migrations/20260926152427_20260903_step5_recruitment_crm_core.sql','supabase/migrations/20260926152438_20260903_step5_recruitment_crm_rpcs.sql','supabase/migrations/20260926152458_20260903_step5_tenant_integrity_hardening.sql','supabase/migrations/20260926152448_20260903_step5_client_vendor_portals.sql'];
const text=files.map(f=>fs.readFileSync(f,'utf8')).join('\n');
const assertions=[
 ['session-derived workspace','private.xzrecruiter_session_context'],
 ['deny direct browser access','xzrecruiter_data_api_deny'],
 ['RLS enabled','enable row level security'],
 ['client ownership','agency_id'],
 ['opportunity ownership','crm_opportunities'],
 ['task ownership','crm_tasks'],
 ['contract ownership','recruitment_client_contracts'],
 ['cross-tenant relation guard','xzrecruiter_validate_crm_scope'],
 ['scope trigger','xzrecruiter_crm_scope_guard'],
 ['security definer RPC boundary','security definer'],
 ['write permission guard','xzrecruiter_can_write'],
 ['portal token hashing','digest'],
 ['vendor job access','vendor_job_access']
];
for(const [name,needle] of assertions)if(!text.toLowerCase().includes(needle.toLowerCase()))throw new Error(`Step 5 security invariant missing: ${name} (${needle})`);
const api=fs.readFileSync('app/api/crm/route.js','utf8');
if(!api.includes('sameOrigin'))throw new Error('CRM mutation route missing same-origin guard');
const lib=fs.readFileSync('lib/crm.js','utf8');
if(lib.includes('p_agency_id'))throw new Error('CRM wrapper must not send p_agency_id; workspace must come from verified session');
const portalRoutes=['app/api/public/client-portal/feedback/route.js','app/api/public/vendor-portal/submit/route.js'];
for(const path of portalRoutes){const source=fs.readFileSync(path,'utf8');if(!source.includes('sameOrigin'))throw new Error(`${path} missing same-origin mutation guard`)}
console.log(`Step 5 security checks passed (${assertions.length+2+portalRoutes.length} assertions).`);
