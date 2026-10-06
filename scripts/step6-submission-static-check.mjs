import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';
const read=p=>readFile(new URL('../'+p,import.meta.url),'utf8');
const [domain,route,api,core,rpcs,recruiterPage,amPage,queuePage,ui,queueUi,css]=await Promise.all([
  read('lib/submission-pack.mjs'),read('app/api/submissions/route.js'),read('lib/submissions.js'),
  read('supabase/migrations/20260926153500_20260925_step6_submission_pack_core.sql'),read('supabase/migrations/20260926153505_20260925_step6_submission_pack_rpcs.sql'),
  read('app/recruiter/submissions/[applicationId]/page.js'),read('app/account-manager/submissions/[applicationId]/page.js'),read('app/account-manager/submissions/page.js'),
  read('app/components/SubmissionPackWorkspace.js'),read('app/components/AccountManagerSubmissionQueue.js'),read('app/step6-submission.css')]);
for(const x of ['CLIENT_CONFIRMED','RESUME','AI_DERIVED','CANDIDATE_DECLARED','RECRUITER_VERIFIED','DOCUMENT_VERIFIED','ACCOUNT_MANAGER_CONFIRMED','UNKNOWN'])assert.ok(domain.includes(x),'missing provenance '+x);
for(const x of ['generate','sendToAm','startReview','amDecision','clientSubmit'])assert.ok(route.includes(`action==='${x}'`)||route.includes(`'${x}'`),'missing API action '+x);
for(const x of ['xzrecruiter_generate_submission_pack','xzrecruiter_send_submission_to_am','xzrecruiter_am_submission_decision','xzrecruiter_client_submit','xzrecruiter_submission_queue'])assert.ok(api.includes(x),'missing RPC map '+x);
assert.ok(core.includes('candidate_submission_versions')&&core.includes('candidate_submission_reviews')&&core.includes('candidate_submission_idempotency'));
assert.ok(rpcs.includes("'submission_not_eligible'")&&rpcs.includes("'stale_approval_blocked'")&&rpcs.includes("'duplicate_client_submission'"));
assert.ok(recruiterPage.includes('await params')&&amPage.includes('await params'));assert.ok(queuePage.includes('WAITING_FOR_REVIEW'));
assert.ok(ui.includes('Client-facing preview')&&ui.includes('Quality Gate'));assert.ok(queueUi.includes('Submission Quality Queue'));assert.ok(css.includes('@media(max-width:480px)'));
console.log('Step 6 static check passed.');
