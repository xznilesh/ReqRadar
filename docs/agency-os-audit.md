# Recruitment / IT Staffing Agency OS gap audit

Baseline: `bfa32c31f2892bba6c9ffdf753263d5805ef5575` on `main`.
Scope: extend the existing application, never introduce a parallel ATS/CRM/matcher.
Status: source implementation and isolated verification complete; draft review only, not production certification.

| # | Existing evidence | Gap / extension decision |
|---|---|---|
| 1 | Step 1–9 source, migrations and tests inspected; baseline `npm run test:step9` passes | Preserve every existing gate; track runtime gaps separately. |
| 2 | `JobProfileEditor`, `JdBrainWorkspace`, `jd-contract.mjs`: rate/period, location, authorization, contract duration, mandatory criteria | Reuse intake; require a customer link and expose client commercial configuration separately from candidate pay. |
| 3 | `recruitment_jobs.client_id` already references `recruitment_clients`; clients are operating accounts | Extend the same client table with parent-client linkage for multiple accounts. Never create another clients/jobs table. |
| 4 | `CrmWorkspace`, `Client360Drawer`, `xzrecruiter_client_360`: companies, contacts, owner, jobs, activity, contracts and placements | Add submission/interview history and currency-separated revenue to Client 360. |
| 5 | `candidate-intelligence.mjs`: location, work model, authorization, notice and availability already evaluated | Add evidenced rate/period/currency comparisons to this matcher; unknown/incomparable remains unknown, no automatic rejection. |
| 6 | `xzrecruiter_talent_match_search` and recruiter talent-search UI | Automatically load suggestions for an approved requirement; retain same tenant-scoped search, label historical matches and stale scores. An approval/readiness trigger persists bounded rediscovery results using the same search; creation before an approved brief intentionally waits for usable criteria. |
| 7 | `candidates.owner_user_id`, source references, assignments, activity and task engine | Add explicit audited, version-checked ownership transfer restricted to managers; show last-contact through existing activities. |
| 8 | `ApplicationScreeningDrawer`, `screening-domain.js`, screening sessions/facts | Notice, compensation, availability, relocation and authorization already exist. Preserve human-verification provenance. |
| 9 | `evaluateDuplicatePair`, candidate merge functions, resume checksum, source records | Normalize equivalent LinkedIn URLs and phone representations; retain evidence and human-reviewed merge. |
| 10 | `xzrecruiter_client_submit` checks duplicate candidate/job/client but locks submission ID | Serialize candidate/job/client releases and enforce a unique index; expose submission history before release. |
| 11 | Immutable `candidate_submission_versions`, `client_facing_pack`, Step 6 configuration | Render client-safe structured presentations in selectable summary/detail formats; never export raw internal pack. |
| 12 | Step 6 AM approval/version/fingerprint gates | Preserve; fix portal read/feedback scope to released, approved submissions only. |
| 13 | Client portal UI, API, token sessions and SQL feedback | Existing API accepts different decision codes than UI/SQL. Align contract; audit feedback and return authoritative status. |
| 14 | Canonical candidacy + submission + client-review + joining states | Project requested business labels from existing state; retain internal AI/screening/AM states and guarded transitions. |
| 15 | Step 8 thresholds, requirement health, alerts and manager requirement view | Reuse existing unworked/stalled/feedback queues; no second SLA engine. |
| 16 | Step 8 deterministic automation, cooldowns, alerts, reminders and tasks | Reuse existing recruiter follow-up, client-feedback, interview, offer/joining and no-activity rules. Do not claim external message delivery from an alert. |
| 17 | `crm_activities`, recruitment events and notes; manual EMAIL/CALL/WHATSAPP/LINKEDIN/SMS types | Link communications across client/job/candidate and provide shared timeline; no fabricated messaging integrations. |
| 18 | Step 8 cohort funnel, source and recruiter performance | Add defined conversion ratios, time-to-submit/fill and commercial breakdown without changing cohort semantics. |
| 19 | Existing client contracts and placements store agency fee/currency/recruiter | Separate expected vs achieved placement revenue by currency, client and recruiter. Do not equate a placement fee with cash received. Extend existing placement creation with candidacy-owner attribution and serialization; add audited, version-checked joining/completion/cancellation to the existing placement screen. |
| 20 | Session-derived agency, RLS deny, canonical business permissions, audit events | All extensions retain session-derived tenant; enforce parent/account/job consistency and explicit commercial permissions. |

## Verified baseline risks

- Client portal UI uses `COMMENT/ADVANCE/REQUEST_INTERVIEW/HOLD/REJECT`; route accepts `SHORTLISTED/INTERVIEW/REJECTED/ON_HOLD`. These paths cannot interoperate.
- Portal SQL only filters `status <> DRAFT`, which is insufficient evidence of AM-approved client release. Use workflow status, approval, timestamp and immutable release snapshot.
- Client-submit locking is per submission, while the conflict invariant is candidate + requirement + client.
- Source migrations assume base tables not created in this repository. This prevents certifying a clean database bootstrap from repository migrations alone.
- Read-only catalog inspection of connected project `iyqucjzqpetddakemlqa` finds `placements.placement_fee`, `offer_id`, `created_by_user_id` and several legacy profile fields absent, although existing RPCs reference it. Do not silently fabricate/backfill historical revenue.
- Existing migration filenames contain duplicate date prefixes. The release gate already blocks this; retain the block pending reconciliation against live migration history.
- Source tests include static/synthetic checks. Passing them does not establish live browser, database, AI, backup/restore or pilot evidence.

## Safety and rollout

Additive schema only. No dropping/rebuilding tables or replacing the design system. No production merge/deploy until the original release gate plus agency regression tests pass. Apply new migration only after all existing Step 1–9 dependencies, using reconciled migration history. Existing orphan requirements must be explicitly linked by an authorized user, never assigned to an invented customer.

## Verification and deployment status

- `npm run test:step9`: passed before and after the extension; existing tests retained.
- `npm run test:agency`: passed. Isolated PostgreSQL executes the additive migration against a catalog-derived structure fixture with synthetic data and session/permission test doubles. Covers tenant/RBAC denial, portal AM release isolation, feedback actions, duplicate release constraint, identity normalization, automatic rediscovery, ownership concurrency, communication idempotency, currency-separated revenue, placement gates/attribution/status transitions and audit events.
- `npm run lint`, `npm run typecheck`, `npm run build`, `git diff --check`: passed. Production dependency audit reports zero vulnerabilities.
- The fixture is not a full historical migration replay or live RLS/browser certification. Independent concurrent connections, production performance, supported external messaging delivery and live AI remain unverified. Timeline entries explicitly log communication; they do not send messages.
- `npm run test:step9:release`: **blocked as designed** by duplicate historical migration versions, missing verified database URL, live AI credentials, backup/restore evidence, browser E2E evidence and pilot evidence. Existing production readiness endpoint returned HTTP 200; that does not certify these changes.
- Production CI now invokes the existing live release gate and agency tests before deployment. No release block was removed and historical migration files were not renamed.
- No live data mutation, migration application, main-branch merge or production deployment performed. Reconcile historical migration versions against the deployed migration ledger, resolve conflicting released submissions explicitly, then apply this migration in staging and provide the live evidence before release.
- Revenue supports date/client/recruiter/account-manager filtering; the UI explicitly distinguishes these from the funnel's requirement/source filters. Timing uses the requirement creation cohort, while revenue uses placement creation cohort. Results are bounded; historical missing commercial values are shown as unpriced, never invented.
