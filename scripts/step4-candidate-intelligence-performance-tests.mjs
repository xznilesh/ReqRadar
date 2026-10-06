import assert from 'node:assert/strict';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { buildCandidateProfileSnapshot,computeCandidateMatch,evaluateDuplicatePair } from '../lib/candidate-intelligence.mjs';

const core=fs.readFileSync('supabase/migrations/20260926152601_20260927_step4_candidate_intelligence_core.sql','utf8');
const b=fs.readFileSync('supabase/migrations/20260926153440_20260927_step4_candidate_intelligence_rpcs_b.sql','utf8');

for(const index of [
  'idx_xzr_candidate_profile_skills_lookup','idx_xzr_candidate_profile_skills_candidate',
  'idx_xzr_candidate_intelligence_jobs','idx_xzr_candidate_match_current',
  'idx_xzr_candidate_match_profile','idx_xzr_candidate_duplicate_source','idx_xzr_candidate_duplicate_compare',
  'idx_xzr_candidate_documents_checksum','idx_xzr_applications_source_reference'
])assert.ok(core.includes(index),'missing performance index '+index);
assert.ok(b.includes('least(coalesce(p_limit,30),50)'),'talent discovery must be bounded');
assert.ok(b.includes('where c.agency_id=v_agency'),'tenant scope must be applied before candidate ranking');

const criteria=[
  {criterion_kind:'HARD_REQUIREMENT',field_key:'experience',value_text:'4 years',am_confirmed:true,enforcement:'ACTIVE',evidence:['4+ years']},
  {criterion_kind:'MUST_HAVE',field_key:'mandatorySkills',value_text:'Node.js',label:'Node.js'},
  {criterion_kind:'MUST_HAVE',field_key:'mandatorySkills',value_text:'PostgreSQL',label:'PostgreSQL'},
  {criterion_kind:'NICE_TO_HAVE',field_key:'preferredSkills',value_text:'AWS',label:'AWS'},
];
const brief={fields:{jobTitle:{value:'Backend Engineer'}},hiringBrief:{}};

function candidate(i){
  return {
    full_name:'Candidate '+i,current_title:i%4===0?'Software Developer':'Backend Engineer',
    experience_years:3+(i%8),relevant_experience_years:3+(i%6),
    skills:i%5===0?['NodeJS']:['NodeJS','Postgres',...(i%3===0?['AWS']:[])],
    city:i%2?'Bengaluru':'Pune',country_code:'IN'
  };
}
function runBatch(count){
  const started=performance.now();let checksum=0;
  for(let i=0;i<count;i++){
    const profile=buildCandidateProfileSnapshot({candidate:candidate(i),resumeText:'Backend engineer Node.js PostgreSQL project evidence.'});
    const match=computeCandidateMatch({criteria,brief,profile});
    checksum+=match.score;
  }
  return {elapsed:performance.now()-started,checksum};
}

const oneK=runBatch(1000);
const tenK=runBatch(10000);
assert.ok(oneK.elapsed<2500,'1,000 candidate local evidence matches should be comfortably sub-2.5s in CI');
assert.ok(tenK.elapsed<15000,'10,000 candidate local evidence matches should be under 15s in CI');
assert.ok(oneK.checksum>0&&tenK.checksum>0);

const base={full_name:'Aarav Mehta',email:'aarav@example.com',phone:'+919999999999',current_company:'Acme',city:'Bengaluru'};
const dupStarted=performance.now();let duplicateHits=0;
for(let i=0;i<10000;i++){
  const other=i===9999?{...base}:{full_name:'Person '+i,email:'p'+i+'@example.com',phone:'+918000'+String(i).padStart(6,'0'),current_company:'Company '+i,city:'Pune'};
  if(evaluateDuplicatePair(base,other).status==='exact_duplicate')duplicateHits++;
}
const dupElapsed=performance.now()-dupStarted;
assert.equal(duplicateHits,1);
assert.ok(dupElapsed<5000,'10,000 in-memory duplicate comparisons should be under 5s in CI');

console.log('STEP4_CANDIDATE_PERFORMANCE_PASS candidates_1k_ms='+oneK.elapsed.toFixed(2)+' candidates_10k_ms='+tenK.elapsed.toFixed(2)+' duplicate_10k_ms='+dupElapsed.toFixed(2)+' bounded_search=true indexed=true');
