# Enterprise UI release — September 30, 2026

## Changes

- Light operational surfaces, navy navigation, teal actions, consistent form/table styling and responsive layouts across the existing ATS, CRM, recruiter, manager and portal components.
- Public website describes available recruitment operations rather than disabled hiring-radar modules. Illustrative data is explicitly labeled.
- Navigation shows working routes; manager/account-manager roles can find submission review. Mobile navigation opens the complete route list.
- Quick-create URLs now open candidate, job, client, contact, opportunity, task, vendor and interview forms. Closing a form does not reopen it automatically.
- Record dialogs and command palette support Escape, focus trapping, focus restoration and background scroll locking. Popovers close on outside clicks.
- Table filtering and pagination reset selection; keyboard activation of nested row buttons does not accidentally select the row.
- Dashboard empty state has actionable candidate, job, import and client setup links. Metrics still come from persisted records.
- Login displays service-unavailable errors and recovers from verification resend network errors.
- Recruiter requirement routes now use one dynamic segment name (`[id]`). The previous `[id]` / `[jobId]` sibling conflict stopped Next.js from starting/building.
- Next.js updated from 16.3.3 to 16.3.8 to resolve the critical dependency advisory. A committed lockfile and `npm ci` make installs reproducible.
- Browser regression suite is included in source verification and production deployment CI. Production retains its restrictive script CSP; development supports React's debugger requirements.

## Verification

Source verification includes `lint`, the repository's syntax check, Step 9 suites (unit, integration, modeled end-to-end, security, AI fixtures, performance guards and responsive source checks), legacy Step 2–5 checks, dependency audit, and Next.js production build.

`npm run test:ui:browser` runs 16 browser checks on the homepage, login, navigation, quick-create forms, command palette and table interactions at desktop/tablet/mobile sizes. It mounts existing components with isolated local fixtures, mocks only auth failure responses and makes no recruiting database writes. The temporary route is removed in a `finally` block and is never deployed. Screenshots/logs are stored under ignored `test-results/ui`.

## Scope and remaining production certification

This release changes UI and fixes the confirmed defects above; it does not rewrite or migrate production recruiting data. Production readiness is checked through `/api/health/ready`.

A valid test account was not available during implementation. Authenticated candidate creation, uploads, screening, submissions, interviews, offers and placements still need a live write-through acceptance run in a dedicated test workspace. Source/model tests and local browser fixtures are not substitutes for that evidence.

The existing full production certification gate also checks migration-history integrity, live two-tenant database security, live AI credentials/evaluation, backup/restore and pilot evidence. Historical SQL filenames reuse migration versions. This UI release does not claim that certification gate passed, and does not rename or reapply historical database migrations.
