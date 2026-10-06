import assert from 'node:assert/strict';
import fs from 'node:fs';
import { analyzeJdWithProvider,createJdIdempotencyKey } from '../lib/jd-ai.mjs';
import { mockOutputForFixture } from './jd-test-helpers.mjs';

const fixture={role:'Data Engineer',text:'Data Engineer. 3-6 years. Python SQL Airflow required. Spark preferred. Pune onsite.',expected:{title:'Data Engineer',mustSkills:['Python','SQL','Airflow'],niceSkills:['Spark'],minYears:3,maxYears:6,city:'Pune',workModel:'ONSITE'}};
let calls=0;
const result=await analyzeJdWithProvider({
  jdText:fixture.text,
  sourceMeta:{sourceType:'PASTED',version:1},
  callModel:async()=>{calls++;if(calls===1)return {output_text:'not-json'};return {id:'resp_test',model:'fixture-model',output_text:JSON.stringify(mockOutputForFixture(fixture))}},
  maxAttempts:2,
});
assert.equal(calls,2);
assert.equal(result.data.fields.jobTitle.value,'Data Engineer');
assert.deepEqual(result.data.fields.mandatorySkills.value,['Python','SQL','Airflow']);
assert.equal(result.providerResponseId,'resp_test');

const key1=createJdIdempotencyKey({jobId:'job1',sourceId:'source1',jdText:fixture.text});
const key2=createJdIdempotencyKey({jobId:'job1',sourceId:'source1',jdText:fixture.text});
assert.equal(key1,key2);

const sql=fs.readFileSync('supabase/migrations/20260926152514_20260925_step2_ai_jd_brain.sql','utf8');
for(const token of [
  'requirement_jd_sources','requirement_ai_runs','requirement_hiring_briefs','requirement_criteria',
  'requirement_clarifications','requirement_brief_audit','xzrecruiter_prepare_jd_source',
  'xzrecruiter_begin_jd_ai_run','xzrecruiter_complete_jd_ai_run','xzrecruiter_approve_hiring_brief',
  "requirement_state='AM_REVIEW'","requirement_state='OPEN'","recruiter_ready=true",
  'agency_id=v_agency','idempotency_key',"v_started_at > now()-interval '5 minutes'",
  "criterion_kind='HARD_REQUIREMENT'","am_confirmed=false",
  "'criteria',coalesce((","'clarifications',coalesce((",
  "country_code=coalesce(v_country,country_code)"
])assert.ok(sql.includes(token),`missing integration contract ${token}`);
assert.ok(!/\bdrop\s+table\b|\btruncate\b|alter\s+table\s+[^;]+\s+drop\s+column/i.test(sql));
console.log('STEP2_JD_INTEGRATION_PASS retry=true persistence_contract=true versioning=true tenant_scope=true');
