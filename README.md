# XZ Recruiter

XZRecruiter is a recruitment operations workspace for staffing companies: client requirements, candidates, submissions, interviews, offers and placements.

The September 30 enterprise UI update introduces a light workspace with navy navigation, consistent forms and tables, working quick-create shortcuts, mobile access to all navigation, and browser regression tests. See [release and verification notes](docs/enterprise-ui-release.md).

Install reproducibly with `npm ci`. Run `npm run test:ui:browser` after `npx playwright install chromium`. On environments with an existing Chromium installation, set `UI_BROWSER_EXECUTABLE` to its path.

## Current engineering state

- Step 1: security, authentication and branding foundation
- Step 2: global localization, IANA timezone and premium product-shell foundation
- Step 3: agency onboarding and recruitment configuration
- Step 4: global enterprise ATS **source closeout** on `step4-global-enterprise-ats`

## Step 4 source closeout

The ATS source now covers the complete operational recruitment path from candidate capture to placement while preserving Step-1 security, Step-2 globalization and Step-3 configurable pipelines.

Key source capabilities include:

- Candidate 360 with quick capture plus an on-demand full profile editor
- skills, education, certifications, languages, mobility, work-authorization notes, availability and compensation data
- private PDF/DOCX/TXT resume storage and parsing with per-field confidence/evidence
- recruiter review before parsed fields are applied
- duplicate comparison with explicit primary-field resolution, audited merge, alternate-contact preservation and carried talent-pool membership
- Candidate 360 notes, attachments, activity timeline, talent pools, archive-safe lifecycle, bulk actions and tenant-authorized CSV export
- server-side candidate/job search, bounded pagination, filters and saved views
- Job 360 with client, hiring manager, department, function, seniority, location, IANA timezone, compensation, work authorization, sponsorship, requirements, benefits, SLA and publishing configuration
- reusable structured public pre-screening questions; required answers are validated server-side and knockout flags are stored only as recruiter-review evidence, never automatic rejection
- configurable recruitment pipelines with board/table views, drag-and-drop plus keyboard/select fallback
- server-side stage gates using configured `required_fields` and transition rules for resume, screening, submission, interview, scorecard, offer, approved offer and placement evidence
- Application 360 with structured screening, client submission draft/submit and consolidated timeline
- global interview scheduling with IANA wall-clock conversion, DST validation, conflict checks and recruiter/candidate timezone context
- reusable weighted interview scorecards with blind peer-feedback protection
- Offer 360 with approval trail, lifecycle control and immutable version chain
- durable placement and agency-fee records
- public job pages with consent-required applications and private resume upload via short-lived one-time upload tokens
- candidate portal for applications, interviews, offers, profile/availability/consent updates and private resume refresh
- private signed document/attachment access, direct-browser deny-by-default RLS architecture and session-derived workspace ownership
- responsive mobile/desktop behavior and RTL-aware UI foundations

## Verification

```bash
npm install
npm run lint
npm run test:step2
npm run test:step3
npm run test:step4
npm run test:step4:closeout
npm run test:step4:performance
npm run test:step4:stage-guard
npm run test:step4:public-apply
npm run test:step4:candidate360
npm run test:step4:job360
npm run build
```

The performance guard proves bounded-query architecture, indexes and no whole-table browser loading. Its synthetic 100k-record check is **not** represented as a real database p95 benchmark.

## Production activation remains separate

Step-4 SQL migrations are intentionally not applied to the live Supabase project as part of source closeout. Before a live environment can be called Step-4 certified, complete the production gate separately:

- review and apply the Step-4 migrations in order
- configure the private `xzrecruiter-private` storage bucket
- configure `SUPABASE_SERVICE_ROLE_KEY` only in the secure server runtime and never as `NEXT_PUBLIC_*`
- run real two-tenant adversarial isolation tests
- verify PDF/DOCX/TXT upload, parsing, signed download and candidate-portal resume refresh end to end
- validate public application screening and consent flows
- test cross-timezone/DST interviews with real database writes
- measure actual query p95 on representative 1k/10k/50k/100k+ datasets
- run desktop/tablet/mobile/Arabic-RTL smoke tests
- certify the final Vercel deployment

Source closeout does not claim measured superiority over another ATS; comparable live task-time and production performance benchmarks require equivalent deployed datasets and conditions.
