import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';

function required(name){
  const value=String(process.env[name]||'').trim();
  if(!value)throw new Error('missing_env:'+name);
  return value;
}
const base=required('XZRECRUITER_E2E_BASE_URL').replace(/\/$/,'');
const bypass=String(process.env.VERCEL_AUTOMATION_BYPASS_SECRET||'').trim();
const fixtures={
  a:{
    email:required('XZRECRUITER_TENANT_A_EMAIL'),
    password:required('XZRECRUITER_TENANT_A_PASSWORD'),
    candidateId:required('XZRECRUITER_TENANT_A_CANDIDATE_ID'),
    documentId:required('XZRECRUITER_TENANT_A_DOCUMENT_ID')
  },
  b:{
    email:required('XZRECRUITER_TENANT_B_EMAIL'),
    password:required('XZRECRUITER_TENANT_B_PASSWORD'),
    candidateId:required('XZRECRUITER_TENANT_B_CANDIDATE_ID'),
    documentId:required('XZRECRUITER_TENANT_B_DOCUMENT_ID')
  }
};
const browser=await chromium.launch({headless:true});
const contexts=[];

async function authenticatedPage(fixture,label){
  const context=await browser.newContext({
    baseURL:base,
    ...(bypass?{extraHTTPHeaders:{'x-vercel-protection-bypass':bypass,'x-vercel-set-bypass-cookie':'true'}}:{})
  });
  contexts.push(context);
  const page=await context.newPage();
  await page.goto('/login',{waitUntil:'domcontentloaded'});
  await page.getByLabel('Work email').fill(fixture.email);
  await page.getByLabel('Password',{exact:true}).fill(fixture.password);
  await page.getByRole('button',{name:/Sign in securely/}).click();
  await page.waitForURL(url=>!url.pathname.startsWith('/login'),{timeout:30000});
  assert.ok(!page.url().includes('/login'),label+' login failed');
  return {context,page};
}

async function candidateAccess(page,candidateId){
  const response=await page.request.post(base+'/api/ats',{
    headers:{origin:base,'content-type':'application/json'},
    data:{action:'candidateCloseout',payload:{candidateId}}
  });
  const body=await response.json().catch(()=>({}));
  return {status:response.status(),body};
}

async function documentAccess(page,documentId){
  const response=await page.request.get(base+'/api/ats/document?documentId='+encodeURIComponent(documentId),{
    headers:{origin:base},
    maxRedirects:0
  });
  return {status:response.status(),location:response.headers().location||''};
}

try{
  const A=await authenticatedPage(fixtures.a,'tenant_a');
  const B=await authenticatedPage(fixtures.b,'tenant_b');
  console.log('TENANT_ISOLATION_PASS dual_login');

  const ownA=await candidateAccess(A.page,fixtures.a.candidateId);
  assert.equal(ownA.status,200,'tenant A cannot access its own candidate');
  assert.equal(ownA.body?.ok,true,'tenant A own candidate context not ready');

  const ownB=await candidateAccess(B.page,fixtures.b.candidateId);
  assert.equal(ownB.status,200,'tenant B cannot access its own candidate');
  assert.equal(ownB.body?.ok,true,'tenant B own candidate context not ready');
  console.log('TENANT_ISOLATION_PASS own_candidate_access');

  const crossAB=await candidateAccess(A.page,fixtures.b.candidateId);
  const crossBA=await candidateAccess(B.page,fixtures.a.candidateId);
  assert.ok([403,404].includes(crossAB.status),'tenant A accessed tenant B candidate');
  assert.ok([403,404].includes(crossBA.status),'tenant B accessed tenant A candidate');
  assert.ok(crossAB.body?.ok!==true,'tenant A cross-tenant candidate returned success');
  assert.ok(crossBA.body?.ok!==true,'tenant B cross-tenant candidate returned success');
  console.log('TENANT_ISOLATION_PASS cross_candidate_denied');

  const ownDocA=await documentAccess(A.page,fixtures.a.documentId);
  const ownDocB=await documentAccess(B.page,fixtures.b.documentId);
  assert.equal(ownDocA.status,302,'tenant A own private document did not produce a signed redirect');
  assert.equal(ownDocB.status,302,'tenant B own private document did not produce a signed redirect');
  assert.ok(ownDocA.location&&ownDocB.location,'private document signed locations missing');
  console.log('TENANT_ISOLATION_PASS own_document_signed_redirect');

  const crossDocAB=await documentAccess(A.page,fixtures.b.documentId);
  const crossDocBA=await documentAccess(B.page,fixtures.a.documentId);
  assert.ok([403,404].includes(crossDocAB.status),'tenant A accessed tenant B private document');
  assert.ok([403,404].includes(crossDocBA.status),'tenant B accessed tenant A private document');
  assert.equal(Boolean(crossDocAB.location),false,'cross-tenant A document leaked signed URL');
  assert.equal(Boolean(crossDocBA.location),false,'cross-tenant B document leaked signed URL');
  console.log('TENANT_ISOLATION_PASS cross_document_denied');

  console.log('STEP9_TENANT_ISOLATION_LIVE_PASS candidates=true documents=true signed_url_leak=false dual_tenant=true');
}finally{
  for(const context of contexts)await context.close().catch(()=>{});
  await browser.close();
}
