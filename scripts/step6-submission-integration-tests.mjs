import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';
const sql=await readFile(new URL('../supabase/migrations/20260926153505_20260925_step6_submission_pack_rpcs.sql',import.meta.url),'utf8');
const core=await readFile(new URL('../supabase/migrations/20260926153500_20260925_step6_submission_pack_core.sql',import.meta.url),'utf8');
const contracts=[
  ['qualified gate',"v_candidacy<>'QUALIFIED'"],['screening gate',"'SCREENING_INCOMPLETE'"],['interest gate',"'CANDIDATE_INTEREST_NOT_CONFIRMED'"],
  ['current intelligence',"'CURRENT_CANDIDATE_INTELLIGENCE_REQUIRED'"],['resume required',"'PRIMARY_RESUME_REQUIRED'"],['hard requirement',"'APPROVED_HARD_REQUIREMENT_FAILED'"],
  ['immutable versions','candidate_submission_versions'],['review history','candidate_submission_reviews'],['idempotency','candidate_submission_idempotency'],
  ['queue pagination','least(coalesce(p_limit,30),100)'],['audit pack','submission.pack_generated'],['audit return','submission.am_returned'],['audit client','submission.client_submitted']
];
for(const [name,needle] of contracts)assert.ok((sql+core).includes(needle),name);
for(const op of ['STEP6_GENERATE','STEP6_SEND','STEP6_AM','STEP6_CLIENT'])assert.ok(sql.includes('pg_advisory_xact_lock')&&sql.includes(op),op);
assert.ok(sql.includes("v_s.latest_version_number<>p_expected_version")&&sql.includes("v_s.version_lock<>p_expected_lock"));
assert.ok(sql.includes('client_submission_snapshot=v_snapshot'));
assert.ok(sql.includes("v_client_pack:=jsonb_build_object(")&&!sql.match(/v_client_pack:=v_pack[^\n]*commercialInternal/));
console.log('Step 6 integration-contract tests passed.');
