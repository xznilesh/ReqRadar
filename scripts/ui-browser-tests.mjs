import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { chromium } from '@playwright/test';

const fixtureDir='app/ui-verification';
if(fs.existsSync(fixtureDir)) throw new Error('Refusing to overwrite an existing route');
fs.mkdirSync(fixtureDir);
fs.copyFileSync('tests/ui/workspace-fixture.js',fixtureDir+'/page.js');
const output=path.resolve('test-results/ui');fs.mkdirSync(output,{recursive:true});
const log=fs.openSync(output+'/server.log','w');
const server=spawn(process.execPath,['node_modules/next/dist/bin/next','dev','--port','3100'],{stdio:['ignore',log,log],env:{...process.env,NEXT_TELEMETRY_DISABLED:'1'}});
let browser;let checks=0;
const base='http://localhost:3100';
function pass(name){checks++;console.log('UI_BROWSER_PASS '+name)}
try {
 for(let i=0;i<60;i++){try{if((await fetch(base)).ok)break}catch{}if(i===59)throw new Error('QA server did not start');await new Promise(r=>setTimeout(r,500));}
 browser=await chromium.launch({headless:true,...(process.env.UI_BROWSER_EXECUTABLE?{executablePath:process.env.UI_BROWSER_EXECUTABLE}:{})});
 const page=await browser.newPage({viewport:{width:1440,height:1000}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 async function noOverflow(name){assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name);pass(name);}
 await page.goto(base);await page.getByRole('heading',{name:'Every requirement. Every candidate. One clear workflow.'}).waitFor();await noOverflow('desktop_home');await page.screenshot({path:output+'/home-desktop.png'});
 for(const width of [768,390]){await page.setViewportSize({width,height:844});await noOverflow('home_'+width);}
 await page.goto(base+'/login?error=service');await page.getByRole('alert').filter({hasText:'temporarily unavailable'}).waitFor();assert.equal(await page.getByLabel('Work email').count(),1);pass('login_service_error_and_labels');
 await page.route('**/api/auth/login',r=>r.fulfill({status:403,contentType:'application/json',body:JSON.stringify({error:'Verify your email first.',code:'email_unverified'})}));
 await page.route('**/api/auth/resend-verification',r=>r.abort());
 await page.getByLabel('Work email').fill('qa@example.invalid');await page.getByLabel('Password',{exact:true}).fill('Example-password-123');await page.getByRole('button',{name:'Sign in securely'}).click();await page.getByRole('button',{name:'Resend verification email'}).click();await page.getByRole('status').filter({hasText:'Could not send'}).waitFor();pass('resend_network_failure');
 await page.goto(base+'/ui-verification');await page.getByRole('heading',{name:'Candidate workspace'}).waitFor();await noOverflow('mobile_candidate_workspace');
 await page.getByRole('button',{name:'Open navigation',exact:true}).click();await page.getByRole('link',{name:'Submission Review',exact:true}).waitFor({state:'visible'});await page.keyboard.press('Escape');await page.getByRole('link',{name:'Submission Review',exact:true}).waitFor({state:'hidden'});pass('mobile_navigation');
 await page.setViewportSize({width:1440,height:1000});await page.screenshot({path:output+'/workspace-desktop.png'});
 await page.getByRole('button',{name:'Quick create',exact:true}).click();await page.getByRole('link',{name:'Create candidate',exact:false}).waitFor();await page.getByRole('heading',{name:'Candidate workspace'}).click();await page.getByRole('link',{name:'Create candidate',exact:false}).waitFor({state:'hidden'});pass('popover_outside_click');
 await page.getByRole('button',{name:'Open global command palette'}).click();await page.getByLabel('Search commands').fill('candidate');assert.equal(await page.getByRole('option').filter({hasText:'Coming later'}).count(),0);await page.keyboard.press('Escape');pass('command_palette');
 for(const [view,title] of [['candidates','New candidate'],['jobs','New job'],['clients','New account']]){
  await page.goto(base+'/ui-verification?view='+view+'&action=create');const dialog=page.getByRole('dialog',{name:'Record editor'});await dialog.waitFor();
  assert.ok(await dialog.getByRole('heading').textContent());assert.equal(await page.evaluate(()=>document.body.style.overflow),'hidden');
  await page.keyboard.press('Escape');await dialog.waitFor({state:'hidden'});await page.waitForTimeout(100);assert.equal(await dialog.count(),0);pass('quick_create_'+view+'_escape');
 }
 await page.goto(base+'/ui-verification?view=table');await page.getByRole('button',{name:'Next',exact:true}).click();await page.getByText('26–30 of 30').waitFor();await page.getByLabel('Search table').fill('Candidate 0');await page.getByText('1–1 of 1').waitFor();pass('table_filter_resets_page');
 const rowButton=page.getByRole('button',{name:'Open',exact:true});await rowButton.focus();await page.keyboard.press('Enter');assert.equal(await page.getByLabel('Select row 1').isChecked(),false);pass('nested_row_keyboard_does_not_select');
 await page.setViewportSize({width:390,height:844});await page.goto(base+'/ui-verification?action=create');await page.getByRole('dialog').waitFor();await noOverflow('mobile_create_dialog');await page.screenshot({path:output+'/candidate-form-mobile.png'});
 assert.deepEqual(errors,[]);pass('no_browser_runtime_errors');
 console.log('UI_BROWSER_SUITE_PASS checks='+checks+' live_database_writes=false');
} finally {
 await browser?.close();server.kill('SIGTERM');fs.rmSync(fixtureDir,{recursive:true,force:true});fs.closeSync(log);
}
