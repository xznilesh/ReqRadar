# Enterprise release certification — 2026-10-06

## Status

**BLOCKED / FAIL-CLOSED.**

This branch hardens release controls but does not claim XZRecruiter is enterprise-certified. Production promotion must remain blocked until the external/live checks below are executed successfully.

## Verified environment evidence — 2026-10-06

- GitHub source-quality CI passed deterministic `npm ci`, lint, dependency audit, typecheck, Steps 1–9 source suites, Playwright UI regression and clean Next.js production build.
- Repository still contains 48 migration files with duplicate version prefixes: `20260903 ×34`, `20260925 ×5`, `20260927 ×4`, `20260929 ×2`.
- The connected Supabase account exposes only `resumedigger` and `xzmargin`; the XZRecruiter project referenced by the old runtime fallback is not accessible to the connected Supabase account. No live migration/RLS/storage certification is claimed.
- Vercel project `xzrecruiter` currently has **zero configured project environment variables**. The production deployment currently serving `xzrecruiter.vercel.app` is an older CLI deployment from commit `e260691733555b344dcfd7cb18c6fc694fe14864`.
- The current production readiness endpoint returns HTTP 200 / database ready, but that old deployment still relies on the previous hard-coded Supabase fallback. This is health evidence only, not enterprise database certification.
- Vercel reports XZRecruiter is **not Git-linked** in the team project linkage inventory; current production deployments are CLI-based. The hard release gate therefore protects the active deployment path, and `vercel.json` also disables future native Git deployment bypass.
- GitHub production environment currently does not provide the live E2E fixture variables, performance database URL, production database URL, AI credential, malware scanner URL, or enterprise evidence variables required by the release gate. Earlier diagnostic steps failed on missing inputs; those failures must never be presented as successful certification.
- No migration filename/history has been changed and no live XZRecruiter database mutation has been executed by this hardening work.

## Migration safety

Do **not** rename or rewrite existing migration filenames until the actual XZRecruiter Supabase project is connected and its remote migration history has been compared with the repository.

Known duplicate local version prefixes include at least:
- 20260903
- 20260925
- 20260927
- 20260929

Required sequence:
1. Connect the actual XZRecruiter Supabase project.
2. Export/list `supabase_migrations.schema_migrations` / provider migration history.
3. Produce an explicit local ↔ remote migration mapping.
4. Create a disposable/staging clone or branch.
5. Reconcile version collisions there using provider-supported migration repair.
6. Reset/apply from clean state and verify schema, functions, indexes, RLS and storage policies.
7. Only after the mapping and clean replay pass may migration filenames/history be repaired for production.

No migration rename is included in this branch.

## Live database certification

The correct XZRecruiter DB must pass the existing live suites and additional manual/automated checks for:
- migration parity
- RLS enabled on exposed tenant tables
- cross-tenant read/write denial
- role/privilege escalation denial
- private storage policy enforcement and signed URL authorization
- orphan/integrity checks
- duplicate/impossible workflow states
- privileged function/view security
- Supabase security/performance advisors

## Browser E2E

`scripts/enterprise-browser-e2e.mjs` requires a real deployed staging candidate and a dedicated seeded tenant.

Required secrets:
- `XZRECRUITER_E2E_EMAIL`
- `XZRECRUITER_E2E_PASSWORD`

Required variables:
- `XZRECRUITER_E2E_BASE_URL`
- `XZRECRUITER_E2E_JOB_ID`
- `XZRECRUITER_E2E_APPLICATION_ID`
- `XZRECRUITER_E2E_CANDIDATE_NAME`
- `XZRECRUITER_E2E_JOB_TITLE`

The verifier exercises authenticated browser state and validates:
login → JD/approved brief → recruiter sourcing workspace → human screening evidence → submission workflow → interview → offer → joining.

## PostgreSQL load certification

`scripts/step9-postgres-load.mjs` runs against a production-like **non-production** PostgreSQL database.

Required secret:
- `XZRECRUITER_PERF_DATABASE_URL`

The harness refuses to target the configured production database unless an explicit override is supplied. Default scales are:
- 1,000
- 10,000
- 50,000
- 100,000 candidates/jobs
- 2x application rows

It records p50/p95/p99 for representative candidate, job and pipeline queries.

Optional SLO variables:
- `XZRECRUITER_PERF_P95_MS`
- `XZRECRUITER_PERF_P99_MS`

## Upload security

Production private uploads now fail closed when malware scanning is not configured, unavailable, times out, reports malware, or returns an indeterminate response.

Required production secret:
- `XZRECRUITER_MALWARE_SCAN_URL`
- scanner token remains `XZRECRUITER_MALWARE_SCAN_TOKEN` when required by the provider.

The only unscanned bypass is `XZRECRUITER_ALLOW_UNSCANNED_UPLOADS=true`, and it is intentionally ignored in production.

## Reproducible/supply-chain delivery

Release/deploy gates require:
- committed npm lockfile
- deterministic `npm ci`
- high-severity production dependency audit
- successful clean production build
- CycloneDX SBOM generation
- release artifacts retained by GitHub Actions

## Mandatory evidence still external

The final release gate requires non-empty evidence references for:
- `XZRECRUITER_BACKUP_RESTORE_EVIDENCE`
- `XZRECRUITER_ENTERPRISE_AUTH_EVIDENCE`
- `XZRECRUITER_PRIVACY_COMPLIANCE_EVIDENCE`
- `XZRECRUITER_INTEGRATIONS_EVIDENCE`
- `XZRECRUITER_OBSERVABILITY_EVIDENCE`
- `XZRECRUITER_PILOT_EVIDENCE`

Browser and PostgreSQL load evidence are emitted from the same successful GitHub Actions run and must not be replaced with unsupported manual claims.

### Enterprise authentication evidence must cover

- MFA enrollment/challenge and AAL-sensitive actions
- SAML SSO on the real project/IdP
- OIDC requirement decision and verified flow if required by customer contract
- organization membership and least-privilege mapping
- user lifecycle/provisioning strategy (including SCIM if contractually required)
- admin session revocation
- session lifetime/inactivity policy
- device/session visibility appropriate to the chosen identity architecture

### Privacy/compliance evidence must cover

- executable retention rules
- deletion and legal-hold behavior
- candidate/customer export and DSAR workflow
- consent/notices history
- AI recommendation transparency
- human-review/override evidence
- customer compliance/audit export

### Integration evidence must cover

- Google and Microsoft email/calendar OAuth in staging
- credential/token rotation and revocation
- webhook signing, replay/idempotency and retry/dead-letter behavior
- API-key lifecycle
- connector health/visibility
- only job-board connectors actually supported by approved APIs/contracts

### Operations evidence must cover

- structured application telemetry
- external error monitoring
- actionable alerts
- incident runbooks
- on-call/escalation ownership
- provider backup/PITR configuration
- completed non-production restore drill with measured RPO/RTO

## Production deployment policy

The main production workflow has already been hotfixed to run the hard release gate before Vercel deployment.

This hardening branch goes further: it requires migration safety, the live browser verifier, the PostgreSQL load certificate, SBOM/dependency checks and all enterprise evidence before production deploy.

Do not merge this branch merely to obtain a green badge. Resolve the migration-history blocker and supply real live certification inputs first.
