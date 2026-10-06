import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';

function required(name){const value=String(process.env[name]||'').trim();if(!value)throw new Error('missing_env:'+name);return value}
const base=required('XZRECRUITER_E2E_BASE_URL').replace(/\/$/,'');
const email=required('XZRECRUITER_E2E_EMAIL');
const password=required('XZRECRUITER_E2E_PASSWORD');
const jobId=required('XZRECRUITER_E2E_JOB_ID');
const applicationId=required('XZRECRUITER_E2E_APPLICATION_ID');
const candidateName=required('XZRECRUITER_E2E_CANDIDATE_NAME');
const jobTitle=required('XZRECRUITER_E2E_JOB_TITLE');
const expectedJourney=['JD','SOURCING','SCREENING','SUBMISSION','INTERVIEW','OFFER','JOINING'];
const output=process.env.XZRECRUITER_E2E_ARTIFACT_DIR||'test-results/enterprise-e2e';
const bypass=String(process.env.VERCEL_AUTOMATION_BYPASS_SECRET||'').trim();
const browser=await chromium.launch({headless:true});
let context;
try{
  context=await browser.newContext({
    baseURL:base,
    ...(bypass?{extraHTTPHeaders:{'x-vercel-protection-bypass':bypass,'x-vercel-set-bypass-cookie':'true'}}:{}),
    recordVideo:process.env.XZRECRUITER_E2E_VIDEO==='true'?{dir:output}:undefined
  });
  const page=await context.newPage();
  const runtimeErrors=[];
  page.on('pageerror',e=>runtimeErrors.push(e.message));

  await page.goto('/login',{waitUntil:'domcontentloaded'});
  await page.getByLabel('Work email').fill(email);
  await page.getByLabel('Password',{exact:true}).fill(password);
  await page.getByRole('button',{name:/Sign in securely/}).click();
  await page.waitForURL(url=>!url.pathname.startsWith('/login'),{timeout:30000});
  assert.ok(!page.url().includes('/login'),'login did not establish an authenticated browser session');
  console.log('ENTERPRISE_E2E_PASS login');

  const checkpoints=[
    {name:'JD',path:`/jobs/${jobId}/requirement`,assertion:async()=>{
      await page.getByRole('heading',{name:jobTitle,exact:false}).waitFor({timeout:20000});
      const response=await page.request.get(`/api/requirements/jd?jobId=${encodeURIComponent(jobId)}`);
      assert.equal(response.ok(),true,'JD context endpoint failed');
      const body=await response.json();
      assert.equal(body?.ok,true,'JD context is not ready');
      assert.equal(body?.job?.recruiter_ready,true,'requirement is not recruiter-ready');
      assert.equal(String(body?.job?.requirement_state||'').toUpperCase(),'OPEN','requirement is not open');
      assert.equal(String(body?.brief?.brief_status||'').toUpperCase(),'APPROVED','approved hiring brief missing');
    }},
    {name:'SOURCING',path:'/recruiter',assertion:async()=>{
      await page.getByRole('heading',{name:'Today'}).waitFor({timeout:20000});
    }},
    {name:'SCREENING',path:'/pipeline',assertion:async()=>{
      await page.getByText(candidateName,{exact:false}).first().waitFor({timeout:20000});
      const response=await page.request.post('/api/ats',{data:{action:'screeningContext',payload:{applicationId}}});
      assert.equal(response.ok(),true,'screening context failed');
      const body=await response.json();
      assert.equal(body?.ok,true,'screening context is not ready');
      assert.ok(body?.session,'human screening session missing');
      assert.ok(['COMPLETED','QUALIFIED','DISQUALIFIED','FOLLOW_UP_REQUIRED'].includes(String(body.session.status||body.summary?.outcome||'').toUpperCase())||body?.summary,'screening has no durable outcome/evidence');
    }},
    {name:'SUBMISSION',path:`/recruiter/submissions/${applicationId}`,assertion:async()=>{
      await page.getByRole('heading',{name:/→/}).waitFor({timeout:20000});
      const response=await page.request.get(`/api/submissions?applicationId=${encodeURIComponent(applicationId)}`);
      assert.equal(response.ok(),true,'submission context failed');
      const body=await response.json();
      assert.equal(body?.ok,true,'submission context is not ready');
      const status=String(body?.submission?.workflow_status||body?.submission?.status||body?.workflow||'').toUpperCase();
      assert.ok(status&&!['DRAFT','NOT_STARTED'].includes(status),'submission did not reach review/client workflow');
    }},
    {name:'INTERVIEW',path:'/interviews',assertion:async()=>{
      await page.getByRole('heading',{name:'Interviews'}).waitFor({timeout:20000});
      await page.getByText(candidateName,{exact:false}).first().waitFor({timeout:20000});
    }},
    {name:'OFFER',path:'/offers',assertion:async()=>{
      await page.getByRole('heading',{name:'Offers'}).waitFor({timeout:20000});
      await page.getByText(candidateName,{exact:false}).first().waitFor({timeout:20000});
    }},
    {name:'JOINING',path:'/placements',assertion:async()=>{
      await page.getByRole('heading',{name:'Placements'}).waitFor({timeout:20000});
      await page.getByText(candidateName,{exact:false}).first().waitFor({timeout:20000});
    }}
  ];

  const completed=[];
  for(const step of checkpoints){
    await page.goto(step.path,{waitUntil:'domcontentloaded'});
    assert.ok(!page.url().includes('/login'),`${step.name} redirected to login`);
    await step.assertion();
    completed.push(step.name);
    console.log('ENTERPRISE_E2E_PASS '+step.name.toLowerCase());
  }
  assert.deepEqual(completed,expectedJourney);
  assert.deepEqual(runtimeErrors,[],'browser runtime errors detected');
  console.log('ENTERPRISE_BROWSER_GOLDEN_PATH_PASS steps='+completed.join('>')+' live_database=true browser=true seeded_fixture=true');
}finally{
  await context?.close();
  await browser.close();
}
