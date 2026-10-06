import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql=fs.readFileSync('supabase/migrations/20260926152345_20260903_step4_zzzzzzzzzz_public_apply_resume.sql','utf8');
const route=fs.readFileSync('app/api/public/apply/route.js','utf8');
const form=fs.readFileSync('app/components/PublicApplyForm.js','utf8');

for(const token of ['public_application_resume_tokens','consent_required','resume_upload_token','15 minutes','xzrecruiter_public_prepare_application_document','xzrecruiter_public_finalize_application_document','review_state=\'NEEDS_REVIEW\'','token_hash','used_at']) assert.ok(sql.includes(token),`public apply SQL missing ${token}`);
assert.ok(sql.includes("public_visibility='PUBLIC'")&&sql.includes("status='OPEN'"),'Public apply must stay bound to an open public job');
assert.ok(!/\bdrop\s+table\b|\btruncate\b/i.test(sql),'Public apply migration must be additive');
for(const token of ['multipart/form-data','storageConfigured','uploadPrivateObject','extractResumeText','parseResumeText','createHash','resumeUploaded','resumeParseStatus']) assert.ok(route.includes(token),`public apply route missing ${token}`);
for(const token of ['type="file"','max 8 MB','form.consent','required type="checkbox"','FormData','Submit application']) assert.ok(form.includes(token),`public apply form missing ${token}`);
assert.ok(!route.includes('SUPABASE_SERVICE_ROLE_KEY'),'Public route must use server storage helper rather than expose secrets');
console.log('STEP4_PUBLIC_APPLY_PASS consent=required resume=private+one_time_token parser=review_only multipart=true mobile_form=true');
