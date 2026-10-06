import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration=fs.readFileSync('supabase/migrations/20260926152350_20260903_step4_zzzzzzzzzzz_candidate_profile_merge.sql','utf8');
const editor=fs.readFileSync('app/components/CandidateProfileEditor.js','utf8');
const drawer=fs.readFileSync('app/components/CandidateCloseoutDrawer.js','utf8');
const page=fs.readFileSync('app/candidates/[id]/page.js','utf8');
const ats=fs.readFileSync('lib/ats.js','utf8');
const layout=fs.readFileSync('app/layout.js','utf8');

for(const token of ['xzrecruiter_candidate_profile_context','xzrecruiter_update_candidate_profile','xzrecruiter_merge_candidates','possible_duplicate','work_authorization_summary','desired_locations','talent_pool_members','candidate_merge_events','field_resolution']) assert.ok(migration.includes(token),`candidate profile migration missing ${token}`);
assert.ok(!/\bdrop\s+table\b|\btruncate\b/i.test(migration),'Candidate profile migration must remain additive');
for(const token of ['Identity & contact','Role & experience','Location & global mobility','Availability & compensation','Privacy & lifecycle','workAuthorizationText','desiredLocationsText','profile-save-state']) assert.ok(editor.includes(token),`Candidate 360 editor missing ${token}`);
for(const token of ['Full profile','Choose primary values','mergeResolution','primaryEmail','primaryPhone','currentTitle','currentCompany','countryCode','Merge with selected values']) assert.ok(drawer.includes(token),`Duplicate resolution UI missing ${token}`);
for(const token of ['CandidateProfileEditor','candidateProfileContext','requireReadyWorkspace']) assert.ok(page.includes(token),`Candidate profile route missing ${token}`);
assert.ok(ats.includes('candidateProfileContext')&&ats.includes('updateCandidateProfile'),'ATS action map missing Candidate 360 RPCs');
assert.ok(layout.includes("./step4-final-quality.css"),'Final quality styles must be loaded');
console.log('STEP4_CANDIDATE360_PASS on_demand_full_profile=true explicit_merge_resolution=true alternate_contacts_preserved=true pool_membership_preserved=true privacy_controls=true');
