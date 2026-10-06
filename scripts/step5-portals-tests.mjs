import fs from 'node:fs';
const exists=p=>{if(!fs.existsSync(p))throw new Error(`missing ${p}`);return fs.readFileSync(p,'utf8')};
const portalSql=exists('supabase/migrations/20260926152448_20260903_step5_client_vendor_portals.sql');
const vendorResume=exists('supabase/migrations/20260926152454_20260903_step5_vendor_private_resume.sql');
const files=[
 'app/components/ClientPortalWorkspace.js','app/components/VendorPortalWorkspace.js','app/components/PortalManager.js',
 'app/api/public/client-portal/feedback/route.js','app/api/public/vendor-portal/submit/route.js'
];
files.forEach(exists);
const requirements=[
 ['client portal token','xzrecruiter_client_portal'],['client feedback','xzrecruiter_client_portal_feedback'],
 ['vendor portal','xzrecruiter_vendor_portal'],['vendor submission','xzrecruiter_vendor_portal_submit'],
 ['vendor sharing','vendor_job_access'],['portal expiry','expires_at'],['token hashing','token_hash']
];
for(const [label,needle] of requirements)if(!portalSql.toLowerCase().includes(needle.toLowerCase()))throw new Error(`Portal requirement missing: ${label}`);
for(const needle of ['xzrecruiter_vendor_portal_prepare_resume','xzrecruiter_vendor_portal_finalize_resume','vendor_candidate_submissions'])if(!vendorResume.includes(needle))throw new Error(`Vendor resume requirement missing: ${needle}`);
const submitRoute=exists('app/api/public/vendor-portal/submit/route.js');
for(const needle of ['formData','uploadPrivateObject','xzrecruiter_vendor_portal_prepare_resume','xzrecruiter_vendor_portal_finalize_resume'])if(!submitRoute.includes(needle))throw new Error(`Vendor multipart resume flow missing ${needle}`);
const vendorUi=exists('app/components/VendorPortalWorkspace.js');
if(!vendorUi.includes('Candidate submission')||!vendorUi.includes('Shared requirements'))throw new Error('Vendor portal workflow incomplete');
const clientUi=exists('app/components/ClientPortalWorkspace.js');
if(!/feedback|decision/i.test(clientUi))throw new Error('Client portal feedback workflow incomplete');
const manager=exists('app/components/PortalManager.js');
if(!/client|vendor/i.test(manager))throw new Error('Portal manager must expose client/vendor portal controls');
console.log(`Step 5 portal regression checks passed (${files.length+requirements.length+9} assertions).`);
