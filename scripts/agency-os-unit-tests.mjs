import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { evaluateStaffingRate,evaluateDuplicatePair,buildCandidateProfileSnapshot,computeCandidateMatch } from '../lib/candidate-intelligence.mjs';
import { CLIENT_FEEDBACK_DECISIONS,clientFeedbackStatus,staffingStage,STAFFING_PIPELINE } from '../lib/workflow-contract.mjs';
import { staffingConversionRatios } from '../lib/manager-control.mjs';

assert.equal(evaluateStaffingRate({max:100,currency:'USD',period:'HOURLY'},{amount:90,currency:'USD',period:'HOURLY'}).status,'PASS');
assert.equal(evaluateStaffingRate({max:100,currency:'USD',period:'HOURLY'},{amount:110,currency:'USD',period:'HOURLY'}).status,'WARN');
for(const candidate of [{amount:90,currency:'INR',period:'HOURLY'},{amount:90,currency:'USD',period:'ANNUAL'},{currency:'USD',period:'HOURLY'},{amount:-1,currency:'USD',period:'HOURLY'}])assert.equal(evaluateStaffingRate({max:100,currency:'USD',period:'HOURLY'},candidate).status,'UNKNOWN');
assert.equal(evaluateDuplicatePair({phone:'+91 123-456'},{phone:'0091123456'}).status,'exact_duplicate');
assert.ok(evaluateDuplicatePair({linkedin_url:'http://in.linkedin.com/in/example/?trk=test'},{linkedin_url:'https://www.linkedin.com/in/example'}).signals.some(s=>s.type==='EXACT_SOURCE_URL'));
assert.equal(evaluateDuplicatePair({},{}).signals.length,0);
const profile=buildCandidateProfileSnapshot({candidate:{salary_expected:110,salary_currency:'USD',salary_period:'HOURLY'}});
const match=computeCandidateMatch({profile,brief:{fields:{compensation:{value:{max:100,currency:'USD',period:'HOURLY'}}}}});
assert.equal(match.rateFit.status,'WARN');assert.ok(match.gaps.some(g=>g.dimension==='compensation'));assert.equal(match.evidenceMeta.scoreIsDecision,false);
assert.equal(staffingStage({candidacy_state:'QUALIFIED',workflow_status:'AM_APPROVED'}),'AM Approved');
assert.equal(staffingStage({candidacy_state:'QUALIFIED',workflow_status:'CLIENT_SUBMITTED',client_viewed_at:'2026-09-30'}),'Client Review');
assert.equal(staffingStage({candidacy_state:'JOINED'}),'Placed');
assert.equal(staffingStage({candidacy_state:'REJECTED'}),'Rejected');
assert.equal(STAFFING_PIPELINE.length,11);
assert.equal(staffingConversionRatios({qualified:4,clientSubmitted:2}).submissionToQualified,50);
assert.equal(staffingConversionRatios({}).joinToOffer,null);

// Execute the real API handler against deterministic RPC/rate-limit adapters.
const context=vm.createContext({console});let calls=[],rateAllowed=true;
const mocks={
 'next/server':{NextResponse:{json:(data,options={})=>({status:options.status||200,data})}},
 '@/lib/workflow-contract.mjs':{CLIENT_FEEDBACK_DECISIONS},
 '@/lib/supabase-api':{rpc:async(name,args)=>{calls.push({name,args});return {ok:true,decision:args.p_decision,status:clientFeedbackStatus(args.p_decision)}}},
 '@/lib/request-security':{mutationRequestIsTrusted:()=>true,declaredBodyWithin:()=>true},
 '@/lib/rate-limit':{consumeRateLimit:async()=>({ok:true,allowed:rateAllowed}),rateLimitIdentityForRequest:()=> 'fixture'}
};
const module=new vm.SourceTextModule(fs.readFileSync('app/api/public/client-portal/feedback/route.js','utf8'),{context});
await module.link(async name=>{const m=mocks[name];assert.ok(m,'unexpected dependency '+name);return new vm.SyntheticModule(Object.keys(m),function(){for(const [k,v] of Object.entries(m))this.setExport(k,v)},{context})});await module.evaluate();
const req=(decision,origin='https://example.test')=>({headers:{get:key=>key==='origin'?origin:null},nextUrl:{origin:'https://example.test'},json:async()=>({token:'synthetic-portal-token-not-a-secret',submissionId:'00000000-0000-4000-8000-000000000001',decision,comment:'Please discuss availability'})});
for(const d of CLIENT_FEEDBACK_DECISIONS){const r=await module.namespace.POST(req(d));assert.equal(r.status,200);assert.equal(calls.at(-1).args.p_decision,d)}
const count=calls.length;
assert.equal((await module.namespace.POST(req('APPROVE_AM'))).status,400);assert.equal(calls.length,count);
assert.equal((await module.namespace.POST(req('ADVANCE','https://attacker.invalid'))).status,403);assert.equal(calls.length,count);
rateAllowed=false;assert.equal((await module.namespace.POST(req('ADVANCE'))).status,429);assert.equal(calls.length,count);
console.log('AGENCY_UNIT_API_PASS staffing_rates=true identity_normalization=true existing_matcher=true pipeline_projection=true conversions=true portal_decisions=true origin=true rate_limit=true');
