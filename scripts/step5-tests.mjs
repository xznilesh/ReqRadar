import fs from 'node:fs';

const read=(p)=>fs.readFileSync(p,'utf8');
const checks=[];
function must(file,needles){const text=read(file);for(const needle of needles){if(!text.includes(needle))throw new Error(`${file} missing ${needle}`);checks.push(`${file}:${needle}`)}}
function exists(file){if(!fs.existsSync(file))throw new Error(`missing ${file}`);checks.push(file)}

[
 'app/clients/page.js','app/contacts/page.js','app/opportunities/page.js','app/tasks/page.js','app/business/pipeline/page.js','app/vendors/page.js',
 'app/components/Client360Drawer.js','app/components/CrmWorkspace.js','app/components/CrmCustomFieldsPanel.js','app/components/VendorPortalWorkspace.js',
 'app/api/crm/route.js','lib/crm.js','app/step5.css'
].forEach(exists);

must('lib/crm.js',['xzrecruiter_crm_dispatch','getCrmReferenceContext','getCrmSearch','saveClient','saveContact','saveOpportunity','moveOpportunity','saveTask','saveContract','saveCustomValues']);
must('app/components/Client360Drawer.js',['Client 360','Business opportunities','Commercial terms','Placement revenue','Relationship timeline']);
must('app/components/CrmWorkspace.js',['Server-side search','saveSavedView','OPPORTUNITY','CONTACT','CLIENT']);
must('app/components/CrmCustomFieldsPanel.js',['Workspace-defined business data','saveCustomValues','MULTI_SELECT','SINGLE_SELECT']);
must('app/components/AppShell.js',['/clients','/contacts','/opportunities','/business/pipeline','/vendors','/tasks']);
must('app/components/CommandPalette.js',['Open Clients & Accounts','Open Opportunities','Open Business Pipeline']);
must('supabase/migrations/20260926152427_20260903_step5_recruitment_crm_core.sql',['crm_opportunities','crm_tasks','recruitment_client_contracts','crm_custom_field_values']);
must('supabase/migrations/20260926152438_20260903_step5_recruitment_crm_rpcs.sql',['xzrecruiter_client_360','xzrecruiter_contact_360','xzrecruiter_opportunity_360','xzrecruiter_save_crm_custom_values']);

console.log(`Step 5 CRM regression checks passed (${checks.length} assertions).`);
