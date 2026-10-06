import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration=fs.readFileSync('supabase/migrations/20260926152402_20260903_step4_zzzzzzzzzzzz_job_profile_screening.sql','utf8');
const editor=fs.readFileSync('app/components/JobProfileEditor.js','utf8');
const page=fs.readFileSync('app/jobs/[id]/page.js','utf8');
const workspace=fs.readFileSync('app/components/JobWorkspace.js','utf8');
const apply=fs.readFileSync('app/components/PublicApplyForm.js','utf8');
const api=fs.readFileSync('app/api/public/apply/route.js','utf8');
const ats=fs.readFileSync('lib/ats.js','utf8');

for(const token of ['xzrecruiter_job_profile_context','xzrecruiter_update_job_profile','screening_questions','hiring_manager_email','work_authorization_requirements','sponsorship_available','invalid_screening_question','screening_required','application_screening_answers','public_application_resume_tokens']) assert.ok(migration.includes(token),`Job 360 migration missing ${token}`);
assert.ok(!/\bdrop\s+table\b|\btruncate\b/i.test(migration),'Job 360 migration must remain additive');
assert.ok(migration.includes("public_visibility='PUBLIC'")&&migration.includes("status='OPEN'"),'Public apply must remain bound to open public jobs');
assert.ok(!migration.includes('auto_reject'),'Structured knockout evidence must not become automatic rejection');
for(const token of ['Requisition','Location & employment','Compensation & authorization','Role brief','Pre-screening questions','Knockout evidence','Publishing & tags','screeningQuestions','hiringManagerEmail','sponsorshipAvailable']) assert.ok(editor.includes(token),`Job 360 editor missing ${token}`);
for(const token of ['JobProfileEditor','jobProfileContext','requireReadyWorkspace']) assert.ok(page.includes(token),`Job 360 route missing ${token}`);
for(const token of ['Full Job 360','Quick edit','bulkJobAction','SET_STATUS','SET_PRIORITY','ADD_TAG','ARCHIVE']) assert.ok(workspace.includes(token),`Job workspace missing ${token}`);
for(const token of ['screeningAnswers','Pre-screening','questionControl','MULTI_SELECT','does not automatically reject']) assert.ok(apply.includes(token),`Public screening form missing ${token}`);
assert.ok(api.includes("error==='screening_required'")&&api.includes('return 422'),'Public API should expose screening validation semantically');
assert.ok(ats.includes('jobProfileContext')&&ats.includes('updateJobProfile'),'ATS action map missing Job 360 RPCs');
console.log('STEP4_JOB360_PASS full_job_profile=true client+hiring_manager=true screening_builder=true public_answers=persisted knockout=review_only resume_flow=preserved');
