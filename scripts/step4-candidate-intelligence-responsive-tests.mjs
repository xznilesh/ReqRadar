import assert from 'node:assert/strict';
import fs from 'node:fs';

const ui=fs.readFileSync('app/components/CandidateIntelligenceWorkspace.js','utf8');
const css=fs.readFileSync('app/step4-candidate-intelligence.css','utf8');
const page=fs.readFileSync('app/recruiter/requirements/[id]/candidates/[candidateId]/intelligence/page.js','utf8');
const requirement=fs.readFileSync('app/components/RecruiterRequirementWorkspace.js','utf8');

for(const label of [
  'Match overview','Approved hard-rule check','Must-have check','Strengths','Gaps','Risks / uncertainties',
  'Fit dimensions','Preferred skills','Source & profile evidence','Potential duplicate evidence','Previous intelligence','Recruiter review'
])assert.ok(ui.includes(label),'candidate intelligence surface missing '+label);

assert.ok(ui.includes('Resume version')&&ui.includes('Parse status')&&ui.includes('Parser version'),'resume freshness/provenance missing');
assert.ok(ui.includes('Confirmed hard rule still unresolved.'),'UNKNOWN hard-rule warning missing');
assert.ok(ui.includes('Decision support only · not an approval or rejection'),'human-authority copy missing');
assert.ok(!ui.includes('<pre>{JSON.stringify(d.signals'),'raw duplicate JSON must not be dumped into recruiter UI');
assert.ok(ui.includes('DuplicateEvidence'),'duplicate evidence must be recruiter-readable');

for(const bp of ['@media(max-width:1100px)','@media(max-width:760px)','@media(max-width:480px)'])assert.ok(css.includes(bp),'responsive breakpoint missing '+bp);
assert.ok(css.includes('min-height:42px'),'mobile touch targets missing');
assert.ok(css.includes('.ci-overview')&&css.includes('.ci-rule-table')&&css.includes('.ci-components'),'critical candidate intelligence layout missing');

assert.ok(page.includes('CandidateIntelligenceWorkspace'));
assert.ok(requirement.includes('/intelligence'),'Step-3 recruiter queue must link directly to candidate intelligence');
assert.ok(requirement.includes('Talent intelligence'),'tenant-scoped talent discovery must be reachable from requirement workspace');
assert.ok(requirement.includes('Open intelligence'),'existing candidate intelligence must be reachable without deep navigation');

console.log('STEP4_CANDIDATE_RESPONSIVE_PASS desktop=true tablet=true mobile=true provenance=true no_raw_ai_dump=true one_two_click_entry=true');
