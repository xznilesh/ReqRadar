import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';
const sql=await readFile(new URL('../supabase/migrations/20260926153505_20260925_step6_submission_pack_rpcs.sql',import.meta.url),'utf8');
const core=await readFile(new URL('../supabase/migrations/20260926153500_20260925_step6_submission_pack_core.sql',import.meta.url),'utf8');
assert.ok((sql.match(/pg_advisory_xact_lock/g)||[]).length>=4,'all mutation families need transaction locks');
assert.ok((sql.match(/version_lock=version_lock\+1/g)||[]).length>=3,'mutations must advance optimistic lock');
assert.ok((sql.match(/stale_submission_version/g)||[]).length>=3,'stale clients must be rejected');
assert.ok(sql.includes("v_source is distinct from v_sv.source_fingerprint"),'approval/client submit must block mixed snapshots');
assert.ok(core.includes('unique(agency_id,operation,idempotency_key)'),'idempotency uniqueness missing');
console.log('Step 6 concurrency/idempotency tests passed.');
