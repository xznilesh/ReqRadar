import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';
const core=await readFile(new URL('../supabase/migrations/20260926153500_20260925_step6_submission_pack_core.sql',import.meta.url),'utf8');
const sql=await readFile(new URL('../supabase/migrations/20260926153505_20260925_step6_submission_pack_rpcs.sql',import.meta.url),'utf8');
for(const idx of ['idx_xzr_submission_am_queue','idx_xzr_submission_candidate_requirement','idx_xzr_submission_versions_history','idx_xzr_submission_reviews_history','idx_xzr_submission_idempotency_lookup'])assert.ok(core.includes(idx),idx);
assert.ok(sql.includes('limit v_limit offset v_offset'));assert.ok(sql.includes('limit 30')&&sql.includes('limit 20'),'history must be bounded');
assert.ok(sql.includes('current_version_id'),'current pack retrieval must be persisted, not regenerated on page load');
console.log('Step 6 performance guards passed.');
