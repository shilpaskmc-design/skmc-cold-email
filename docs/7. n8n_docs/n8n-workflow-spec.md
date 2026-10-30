# SKMC Cold Email Automation — n8n Workflow Specification

**Version:** 1.1 | **Date:** 2026-10-17 | **Status:** Draft v1.1 — Written, Pending Cross-Document Validation. **Not approved.**

**Companion documents (planned):**
- `n8n-workflow-contracts.md` — full WF-01…WF-16 implementation contracts (27-field template)
- `n8n-database-mapping.md` — workflow-to-table mappings for all 17 approved tables
- `n8n-workflow-diagrams.md` — end-to-end flowchart + sequence diagrams

**Derived from (approved sources only):**
1. `architecture.md` — v1.3, Approved
2. `database-schema.md` — v1.2, Approved implementation baseline
3. `lead-lifecycle-status-flow.md` — v1.0, Approved
4. `api-integration-spec.md` — v1.0, Approved
5. `verification-suppression-rules.md` — v1.0, Approved

Campaign & ICP Specification (v0.1 template, business decisions pending) is a supporting document. **No policy is derived from it.** Original v1.0 file preserved as `n8n-workflow-spec-v1.0-pre-approval-backup-20261017-111320.md`.

---

## §1 Purpose

This document is the master workflow specification: the workflow catalog, orchestration architecture, and common rules that all workflow implementations must follow. Detailed per-workflow behavior lives in `n8n-workflow-contracts.md`; physical DB operations in `n8n-database-mapping.md`; visual flows in `n8n-workflow-diagrams.md`. This document does not repeat those details — it defines and cross-references them.

## §2 Component Responsibilities (Arch §5)

- **PostgreSQL is canonical.** All business/lifecycle/suppression/verification/audit state lives here.
- **n8n** is the orchestration and policy-gate execution layer. It is NOT canonical storage, NOT CRM, NOT transport, NOT a sequence engine.
- **Warmbly** owns sequence/mailbox execution only. Warmbly state is never canonical; it is reconciled against PostgreSQL (Arch §17, §20).
- **OpenOutreach** is the lead source of source-identifiers and qualification verdicts.
- **Verification providers** (ZeroBounce primary, MillionVerifier conditional fallback) produce verdict-at-check-time only — never durable canonical truth (Arch §10; DB §7).

## §3 Master Catalog — 16 workflows

Consolidated from the 20 candidates (A–T) listed in the prior skeleton's inventory. Consolidation rationale: verification fallback/retry is orchestrated inside WF-04 (per Doc 6 §7/§11 provider-order and failure matrix); re-enrollment evaluation is a path through WF-05 (per Lifecycle §14/§20), not a separate always-on workflow; retry policy is a per-contract concern (Doc 6 §11; API §15), not a workflow; reply types are separate workflows because their lifecycle and suppression effects are structurally different (Doc 6 §16–§18).

**Trigger categories (unambiguous, by primary trigger):**
- **Event-driven: 12** — WF-01…WF-12 (external API/webhook events or internal event hand-offs between workflows).
- **Scheduled: 4** — WF-13, WF-14, WF-15, WF-16 (cron). WF-14 additionally supports manual invocation, but its primary trigger is scheduled.
- Total: **16.** No invented workflows. Count changes only if source-derived requirements demonstrate a genuine need.

| ID | Name | Trigger | DB Writes (approved schema only) | External | Lifecycle Effects | Suppression Effects | Traceability |
|---|---|---|---|---|---|---|---|
| WF-01 | Lead Intake | OpenOutreach discovery event | `leads` INSERT; `lifecycle_events` | — | DISCOVERED | none | Arch §6, §7; Lifecycle §6; API §6.1; Schema §5.4 |
| WF-02 | Qualification Ingestion | OpenOutreach qualification verdict | `leads` (qualification fields, `lifecycle_status`); `lifecycle_events` | — | QUALIFIED / PARKED / terminal non-fit | none | Arch §7, §8, §9; Lifecycle §5, §6; Schema §5.4 |
| WF-03 | Enrichment Orchestration | WF-02 completion, conditional | `lead_enrichment` INSERT; `leads` cache columns; `lifecycle_events` | Apollo (optional, per API §7) | ENRICHMENT_PENDING → ENRICHED (approved transitions only) | none | Arch §5, §14; API §7; Lifecycle §7; Schema §5.5, §9 |
| WF-04 | Verification Orchestration | WF-03 completion / WF-02 path | `verification_results` INSERT (append-only); `leads` cache columns; `lifecycle_events` | ZeroBounce (primary); MillionVerifier (conditional fallback per policy) | VERIFICATION_PENDING → VERIFIED (valid+fresh); invalid → suppression state activates, lifecycle REMAINS VERIFICATION_PENDING (approved overlay — no lifecycle rewrite); TEMPORARY_FAILURE/UNKNOWN → lifecycle HOLDS at VERIFICATION_PENDING | **Only a canonical verdict INVALID/DISPOSABLE activates `invalid_email` suppression.** Provider/technical failures produce NO canonical verdict → NO suppression | Arch §10–§12; Doc 6 §7–§11; API §8–§10; Schema §5.6, §7 |
| WF-05 | Campaign Eligibility Gate (incl. re-entry evaluation) | WF-04 pass / explicit approved re-entry trigger | `leads.lifecycle_status → CAMPAIGN_READY`; `lifecycle_events` append | — | VERIFIED → CAMPAIGN_READY (only on full gate pass) | Check-only. No suppression mutation | Arch §11, §13; Lifecycle §9, §14, §20; Doc 6 §22, §25; Schema §5.4, §7, §8 |
| WF-06 | Assignment + Warmbly Enrollment | WF-05 pass | `campaign_assignments` INSERT; `lifecycle_events` | Warmbly API (TO VERIFY — endpoints/auth not confirmed) | CAMPAIGN_READY → IN_SEQUENCE | none | Arch §13, §17; API §11; Lifecycle §10; Schema §5.8, §8 |
| WF-07 | Webhook Ingestion | Warmbly webhook | `email_events` INSERT (raw payload); `workflow_runs` | — | None directly (processors apply lifecycle) | None directly | Arch §20; API §12; Lifecycle §16; Schema §5.11, §12 |
| WF-08 | Reply Processing | WF-07 REPLY event | `replies` INSERT; `lifecycle_events`; `suppression_list`+`suppression_events` only if reply classified `explicit_unsubscribe` | — | REPLIED_POSITIVE / REPLIED_NEGATIVE / UNSUBSCRIBED (only via explicit unsubscribe classification) | Only `explicit_unsubscribe` → GLOBAL | Arch §15, §16; Doc 6 §16, §18; Lifecycle §11; Schema §5.12, §5.9, §5.10 |
| WF-09 | Bounce Processing | WF-07 bounce event | `lifecycle_events` (hard bounce → BOUNCED); `suppression_list`+`suppression_events` per approved bounce policy | — | Hard: IN_SEQUENCE → BOUNCED. Soft: lifecycle unchanged | Hard: `hard_bounce` reason, scope per configured policy (OPEN values). Soft: none unless policy escalates | Arch §19, §20; Doc 6 §19; Lifecycle §11; Schema §5.11, §5.9 |
| WF-10 | Unsubscribe Processing | WF-07 unsubscribe event | `suppression_list`+`suppression_events` (GLOBAL, `explicit_unsubscribe`); `lifecycle_events` (UNSUBSCRIBED) | — | IN_SEQUENCE → UNSUBSCRIBED (the ONLY event producing UNSUBSCRIBED) | GLOBAL; NO automatic expiry | Arch §15, §16; Doc 6 §16; Lifecycle §5, §12; Schema §5.9, §5.10 |
| WF-11 | Spam Complaint Processing | WF-07 SPAM_COMPLAINT event | `suppression_list`+`suppression_events` (GLOBAL, `spam_complaint`); **no lifecycle transition row** | — | **None.** Lifecycle PRESERVED (remains IN_SEQUENCE; MUST NOT become UNSUBSCRIBED) | GLOBAL | Arch §15, §16; Doc 6 §17; Lifecycle §5, §12; Schema §5.9, §5.10 |
| WF-12 | Sequence Completion | WF-07 completed event | `lifecycle_events` (COMPLETED) | — | IN_SEQUENCE → COMPLETED (lifecycle-terminal) | none. COMPLETED ≠ suppression | Arch §9; Lifecycle §5, §20; Schema §5.4 |
| WF-13 | PARKED / C-Fit Revisit | Scheduled; cadence `c_fit_revisit_days` (NULL = fail-closed no-op + config-missing audit) | None directly — triggers WF-02 for due PARKED leads | — | None directly. Transitions result only from WF-02's fresh qualification verdict | none | Arch §8, §21; Lifecycle §6; Schema §5.14 |
| WF-14 | DLQ Processing & Replay | Scheduled (primary) + manual | `dead_letter_events` status transitions | varies by replayed item | None directly — replay routes through the correct processor workflow | Replay passes full safety re-checks before any effect | Arch §22; Doc 6 §27; API §15; Schema §5.17 |
| WF-15 | Scheduled Reconciliation | Scheduled; cadence OPEN | `leads` cache columns (same-transaction repair contract); `workflow_runs` | Warmbly queries (TO VERIFY) | None directly (report + repair only) | none | Arch §5, §20; Schema §5.4, §7 |
| WF-16 | Health/Alert Evaluation | Scheduled | None (computed from `workflow_runs`, `email_events`, `dead_letter_events` counts) | — | none | none | Arch §19, §23; Schema §5.16, §5.17 |

## §4 Orchestration Architecture

PostgreSQL is canonical throughout. Happy-path flow:

Discovery → Qualification → Conditional Enrichment → Verification → Eligibility → Assignment → Warmbly Enrollment → Sending → Webhook feedback → Lifecycle/Suppression updates → Re-entry/Reconciliation.

- Every gate is fail-closed (§5 rule 5).
- Every execution writes a `workflow_runs` row (Schema §5.16).
- No workflow implies direct provider-to-provider canonical mutation (Arch §29).
- Workflow dependency graph: see `n8n-workflow-diagrams.md`.

## §5 Common Rules

1. **Identity hierarchy** (API §5; Arch §6): (source_system, external_lead_id) → normalized email → (source_system, external_person_id) → manual review. `company_domain` is used only for company-level dedup, never contact identity (Arch §29 #8).
2. **Retry taxonomy** (Doc 6 §11; API §15): infra-retryable / provider-retryable / HOLD / REVIEW (workflow state) / terminal / DLQ. **RETRY, REVIEW, DLQ, FAILED, SUPPRESSED are workflow-processing concepts, NOT lifecycle states.**
3. **Idempotency model** (Schema §12; API §16; Lifecycle §16): business idempotency (approved partial unique indexes) + event idempotency (`email_events.idempotency_key UNIQUE`; `warmbly_event_id` stored for traceability when provider supplies one; deterministic fallback key composition is DB-D4 — OPEN) + workflow-execution idempotency (`workflow_runs` + n8n execution id).
4. **Transaction boundaries** (Arch §29; Schema §5.7 consistency contracts): external API effects are never DB-atomic with PostgreSQL writes. Unknown external outcome = HOLD + reconciliation; success is never assumed.
5. **Fail-closed rules — refined:**
   - **BLOCKED:** unsafe send; enrollment; external provider call; unsafe lifecycle mutation — whenever DB is unavailable, suppression state is unavailable/ambiguous, verification is missing/stale, provider is down, required config is NULL, or identity is ambiguous.
   - **PERMITTED even under failure:** mandatory auditing (`workflow_runs`, raw `email_events`, `lifecycle_events` where a contract defines them), error classification, DLQ ingestion, and **safety-direction state updates** — suppression ACTIVATION (never deactivation), cache repair toward canonical state, alert emission.
   - Meaning: fail-closed does not mean "do nothing" — it means unsafe forward actions are blocked while safety bookkeeping continues.
6. **Race conditions** (Doc 6 §26; Lifecycle §16): the latest canonical SAFETY state wins over stale workflow execution; historical evidence is preserved append-only and never rewritten.
7. **Secrets** are never in code, logs, audit text, or documentation (API §17). Retention/PII policy: OPEN (Arch §28).

## §6 OPEN Dependencies (unresolved — carried, fail-closed)

- **Architecture §28 open decisions (11 items):** catch-all policy, retention/PII, verification freshness value, C-Fit revisit cadence, negative-reply cooldown, minimum sample size, conflict resolution details, Warmbly endpoints/auth/webhooks (TO VERIFY), mailbox rotation, alert channel, and related.
- **Database open decisions DB-D1…DB-D8** (Schema §17) — in particular DB-D4 (exact idempotency-key composition), DB-D7 (email mutation), DB-D8 (suppression coexistence/precedence).
- **13 configuration keys** registered in `policy_config` with NULL values (`value_note = 'REQUIRED CONFIGURATION — OPEN DECISION'`) — fail-closed on NULL.

## §7 Implementation Order (revised per review)

1. Shared DB helpers + `outreach_app` credential wiring
2. `workflow_runs` / audit framework
3. WF-01 Lead Intake
4. WF-02 Qualification Ingestion
5. WF-03 Enrichment Orchestration
6. WF-04 Verification Orchestration
7. **WF-07 Webhook Ingestion**
8. **WF-08–WF-12 safety event handling** (idempotency + lifecycle/suppression effects tested)
9. **WF-14 DLQ + WF-15 Reconciliation** (recovery paths tested)
10. WF-05 Eligibility Gate
11. **WF-06 Warmbly Enrollment — activated only after steps 7–9 (webhook processing, safety event handling, idempotency, reconciliation/recovery) are tested**
12. WF-13, WF-16 scheduled workflows

Rationale: foundation before external sending; enrollment is the highest-risk external action and is gated behind proven feedback/recovery paths.

## §8 Traceability

Source-section references for every workflow are populated in the §3 catalog table above. The full workflow×table mapping matrix lives in `n8n-workflow-contracts.md` (final section). All references cite verified section numbers of the five approved documents.

## §9 Change Log

- v1.0 (2026-10-13): instruction skeleton draft (historical completeness failure — audited; content preserved in backup file).
- v1.1 (2026-10-17): derived master specification written from approved sources. Changes vs v1.0: (1) implementation order revised — WF-06 after webhook/safety/idempotency/recovery testing; (2) WF-12 no longer implies automatic re-enrollment; (3) WF-05 lifecycle persistence clarified within approved schema (no new table/state); (4) WF-07 duplicate/malformed/unknown/out-of-order behavior defined; (5) fail-closed rules refined — safety bookkeeping permitted under failure; (6) traceability populated with actual source-section references. Additional clarifications: WF-07 duplicates never repeat business effects or overwrite the original event; WF-04 distinguishes invalid-email verdicts from provider/technical failures (provider failure never creates `invalid_email` suppression); WF-06 rechecks suppression, verification freshness and assignment conflicts immediately before external enrollment; trigger-category counts made unambiguous (event-driven 12, scheduled 4 incl. WF-14 manual-capable). Status: Draft v1.1 — Written, Pending Cross-Document Validation. NOT approved.
