# XZRecruiter production incident runbook

## Purpose

Use this runbook for production readiness failures, authentication outages, database errors, cross-tenant/security signals, integration failures, or a failed release promotion.

## First response

1. Freeze deployments. Do not bypass the hard release gate.
2. Confirm the canonical readiness endpoint and the exact production deployment SHA.
3. Check Vercel grouped runtime errors and recent function logs.
4. Check the XZRecruiter Supabase project health, database logs, Auth health, Storage health and security advisors.
5. If a security or tenant-isolation issue is suspected, stop privileged automation/integrations and preserve audit evidence before changing data.
6. Do not repair migration history or rename migration files during an incident without the verified local ↔ remote reconciliation report.

## Severity

- **SEV-1:** cross-tenant exposure, authentication bypass, corrupted/deleted customer data, malicious resume accepted into processing, or widespread unavailability.
- **SEV-2:** major hiring workflow unavailable, integrations failing broadly, sustained elevated 5xx/errors, or severe performance regression.
- **SEV-3:** localized feature degradation with safe workaround.

## Containment

For suspected access-control incidents:
- revoke affected application sessions;
- disable compromised credentials/API keys at the provider;
- suspend the affected connector/automation;
- verify no signed private-storage URL remains usable beyond its short TTL;
- preserve request IDs, audit/security events and provider logs.

For deployment regressions:
- prefer Vercel rollback/promotion to the last known-good certified deployment;
- never perform destructive database rollback surgery;
- use a tested forward-fix or verified provider restore/PITR when schema/data recovery is required.

## Database recovery

Before a production restore:
- record incident time and suspected corruption window;
- identify the last known-good restore point;
- restore into non-production first;
- execute live DB integrity/RLS/security checks and application smoke tests;
- record measured RPO/RTO;
- only then choose production recovery.

A provider backup existing is **not** restore evidence. A completed restore drill with verified application/database checks is required.

## Release restart

Release may resume only after:
- source CI green;
- migration reconciliation clean;
- live DB/RLS/storage/tenant-isolation certification green;
- browser golden path green;
- production-like PostgreSQL load SLO green;
- malware scanner healthy;
- required auth/privacy/integration/observability evidence present;
- post-fix production readiness green.

## Evidence to retain

Retain the affected deployment ID/SHA, GitHub Actions run IDs and artifacts, relevant request IDs, timestamped provider logs, migration reconciliation report, security/advisor output, restore evidence, and a short root-cause/corrective-action record. Do not store secrets or candidate PII in incident tickets or CI artifacts.
