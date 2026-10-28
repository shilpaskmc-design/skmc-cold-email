# SKMC Cold Email Automation — n8n Database Mapping

**Version:** 1.1 | **Date:** 2026-10-17 | **Status:** Draft v1.1 — Pending Review. **Not approved.**

**Master references:** `n8n-workflow-spec.md` v1.1 (catalog §3), `n8n-workflow-contracts.md` v1.1 (§4). Workflow IDs and behavior are defined there — not redefined here.

**Derived from:** Architecture v1.3 (Approved), Database Schema v1.2 (Approved baseline), Lifecycle v1.0, API Integration Spec v1.0, Verification & Suppression Rules v1.0.

---

## §1 Purpose

Maps each of the 17 approved application tables to the workflows that access them, with exact operations (READ/INSERT/UPDATE), required columns, relied-upon constraints/indexes, and transaction rules. The diagram-level view lives in `n8n-workflow-diagrams.md`.

## §2 Global PostgreSQL Access Rules (Schema v1.2 §5.18)

Two roles operate `outreach_db` (migration 05a, executed and live-verified 2026-10-17):

- **`outreach_admin`** — schema owner, migrations only. NOT used by runtime workflows.
- **`outreach_app`** — runtime role for all n8n data access:
  - **Append-only tables** (`verification_results`, `suppression_events`, `lifecycle_events`, `config_history`): `SELECT, INSERT` only. `UPDATE, DELETE` explicitly revoked. **PostgreSQL-enforced** — live-verified: `SET ROLE outreach_app` UPDATE/DELETE attempts returned `permission denied`; SELECT succeeded (migration 05a verification test).
  - **`suppression_list`** (current state): `SELECT, INSERT, UPDATE` (soft-deactivation legitimate); **DELETE revoked**.
  - **Operational tables** (`leads`, `companies`, `campaigns`, `campaign_assignments`, `lead_enrichment`, `email_events`, `replies`, `sending_domains`, `mailboxes`, `policy_config`, `workflow_runs`, `dead_letter_events`): `SELECT, INSERT, UPDATE` as required; **no DELETE grants issued** — soft-deactivation pattern throughout.
  - `outreach_user` retained as legacy owner (member of `outreach_admin`); `n8n_user` untouched (n8n internal DB role); **no cross-database foreign keys** — n8n connects to `n8n_db` (own role) and `outreach_db` (`outreach_app`) separately; consistency across DBs is workflow-enforced.

**Approved-vs-live distinction:** the grant matrix above is the approved/intended design (Schema §5.18). Live-verified evidence exists for: role existence, table ownership (`outreach_admin`), and append-only enforcement on the three tested tables. A full `\dp` grants dump re-verification against the live DB is a **PENDING VERIFICATION item** (requires VPS access; read-only, no changes).

---

## §3 Table Mappings (17 tables, Schema §5.1–§5.17 order)

### §3.1 `sending_domains`
- **Columns:** domain_id (PK), domain_name (UNIQUE), health_status (`health_status_enum`), active, created_at, updated_at. Bounce/complaint windows + thresholds = `policy_config` DOMAIN scope, NOT columns.
- **Accessed by:** WF-16 (READ — health evaluation input).
- **Operations:** READ only.
- **Constraints relied upon:** `domain_name UNIQUE`; health thresholds are config-scope (uq via `uq_config_scoped`).
- **Health ownership:** Authorized administrators control `health_status` transitions (escalation is context-aware behavior). WF-15 may update health indicators ONLY when provider evidence and approved mapping are available. No automatic unpause, sending enablement, or unsupported healthy-status assignment. All changes auditable via `config_history` / `workflow_runs`.

### §3.2 `mailboxes`
- **Columns:** mailbox_id (PK), domain_id (FK→sending_domains), email_address (UNIQUE), warmup_status (`warmup_status_enum`), warmup_started_at/completed_at, health_status, paused_at, pause_reason, active, created_at, updated_at. No daily-cap columns — caps are `policy_config` MAILBOX scope.
- **Accessed by:** WF-16 (READ); WF-06 (READ — mailbox context for enrollment, where Warmbly contract requires).
- **Operations:** READ only.
- **Constraints:** `idx_mailboxes_domain`; FK to sending_domains.
- **Health ownership:** Authorized administrators control mailbox `warmup_status` and `paused_at`/`pause_reason` settings. WF-15 may update `health_status` indicators ONLY when provider evidence and approved mapping are available. No automatic unpause, sending enablement, or unsupported healthy-status assignment. All changes auditable via `config_history` / `workflow_runs`.

### §3.3 `companies`
- **Columns:** company_id (PK), company_name, company_domain (UNIQUE — ENRICHMENT DEDUPE ONLY), profile_json, employee_count, annual_revenue, funding_round, tech_stack[], active, timestamps.
- **Accessed by:** WF-01 (READ+INSERT — company dedupe by `company_domain` at intake, explicit INSERT per contracts v1.1 §4.1), WF-03 (READ+INSERT/UPDATE — enrichment-driven profile fields where approved, explicit INSERT/UPDATE per contracts v1.1 §4.3).
- **Constraints:** `company_domain UNIQUE` (dedupe key).

### §3.4 `leads`
- **Columns:** lead_id (PK), source_system, external_lead_id, external_person_id, email (CITEXT nullable), first_name, last_name, company, title, company_id (FK), company_domain (display/enrichment only), reason (internal audit), signals JSONB, signals_schema_version, qualification_fit (`qualification_fit_enum`: A_FIT/B_FIT/C_FIT/REJECT), verification_status (`verification_status_enum`, default NOT_CHECKED), lifecycle_status (`lifecycle_status_enum` 14 states, default DISCOVERED), suppression_status (`suppression_status_enum`: ACTIVE/INACTIVE), active, created_at, updated_at.
- **Accessed by:** ALL 16 workflows (WF-01 INSERT; WF-02/03/04/05/12/15 UPDATE; WF-06/07/08/09/10/11/13/14/16 READ; WF-02/05/13 also READ for gate decisions).
- **Operations per workflow:** WF-01 INSERT; WF-02 UPDATE (qualification_fit, lifecycle_status); WF-03 UPDATE (cache columns from enrichment); WF-04 UPDATE (verification_status cache — same-tx with history INSERT); WF-05 UPDATE (lifecycle_status → CAMPAIGN_READY; stale → VERIFICATION_PENDING); WF-12/15 UPDATE (lifecycle/cache); processors WF-08/09 UPDATE lifecycle via contracts.
- **Constraints/indexes relied upon:** `uq_leads_source_lead`, `uq_leads_source_person`, `uq_leads_email_resolved` (identity); `idx_leads_lifecycle`, `idx_leads_gate` (WF-05 gate scans), `idx_leads_parked` (WF-13), `idx_leads_company`.
- **Transaction rules:** cache-consistency contracts (below). Email mutation: **DB-D7 OPEN — workflows MUST NOT mutate leads.email in a way that moves a lead out from under an active suppression without explicit suppression re-evaluation** (Schema §5.9 identity contract point 4).

### §3.5 `lead_enrichment`
- **Columns:** enrichment_id (PK), lead_id (FK), provider (default 'APOLLO'), requested_fields[], returned_fields[] (double-buy guard evidence), raw_response JSONB, skipped (TRUE = guard skipped Apollo), created_at.
- **Accessed by:** WF-03 (READ for guard + INSERT); WF-04 trigger context (READ).
- **Constraints:** `idx_enrichment_lead`; FK to leads.
- **Transaction rule:** enrichment row + leads cache update per WF-03 contract; append-style (no UPDATE of prior rows).

### §3.6 `verification_results` (append-only)
- **Columns:** verification_id (PK), lead_id (FK), provider (`verification_provider_enum`: ZEROBOUNCE/MILLIONVERIFIER), result_status (canonical 8-value enum), provider_status, provider_sub_status, catchall_domain, mx_found, mx_record, smtp_provider, free_email, domain_age_days, did_you_mean, is_fallback (TRUE = MV fallback), raw_metadata JSONB, checked_at (freshness source), created_at.
- **Accessed by:** WF-04 (INSERT + READ latest), WF-05 (READ latest via `idx_verif_lead_fresh`), WF-06 (READ freshness recheck), WF-15 (READ canonical vs cache).
- **Privileges:** SELECT/INSERT only for outreach_app (UPDATE/DELETE revoked — §5.18, live-verified).
- **Key index:** `idx_verif_lead_fresh (lead_id, checked_at DESC)`.
- **Invariant:** reverification INSERTs a new row; history never updated. Same-transaction cache sync contract (Schema §7).

### §3.7 `campaigns`
- **Columns:** campaign_id (PK), campaign_name, service_line, icp_doc_ref, required_fields[], signals_template_keys[] (fail-closed personalization allowlist), conflict_group (conflict semantics; NULL = independent), active, timestamps.
- **Accessed by:** WF-05 (READ — eligibility inputs), WF-06 (READ), WF-13 (READ — campaign config where applicable).
- **Operations:** READ only from workflows. Campaign creation = administrative/manual (owner action, not a workflow contract).
- **Constraints:** `conflict_group` semantics enforced by n8n gate, not DB (Schema §8).

### §3.8 `campaign_assignments`
- **Columns:** assignment_id (PK), lead_id (FK), campaign_id (FK), enrolled_at, exited_at, exit_reason, active, created_at.
- **Accessed by:** WF-06 (INSERT on confirmed enrollment), WF-12 (UPDATE exit: active=FALSE, exited_at, exit_reason='COMPLETED'), WF-05 (READ — conflict evaluation), WF-06 (READ — recheck), WF-14/15 (READ context).
- **Constraints:** `uq_assign_active_lead_campaign (lead_id, campaign_id) WHERE active=TRUE` — duplicate simultaneous enrollment impossible at DB level; `idx_assign_campaign`, `idx_assign_lead`. Historical rows never deleted (re-enrollment creates new row).
- **Transaction rule:** assignment INSERT precedes external Warmbly call; IN_SEQUENCE lifecycle only on confirmed enrollment (non-atomic external — WF-06 contract).

### §3.9 `suppression_list` (current effective state)
- **Columns:** suppression_id (PK), lead_id (FK nullable — pre-lead entries), email (CITEXT — canonical lookup key), scope ('GLOBAL'|'CAMPAIGN' CHECK), campaign_id (FK, set iff CAMPAIGN), reason (`suppression_reason_enum` 7 values), source_event_id, active, created_by (default 'n8n_service'), timestamps. CHECK: GLOBAL⇔campaign_id NULL.
- **Accessed by:** WF-01/02/04/05/06/08/09/10/11/14 (READ — canonical suppression gate); WF-10/11 (INSERT/UPDATE — GLOBAL activation); WF-09 (INSERT/UPDATE — hard_bounce per policy); WF-08 (INSERT — explicit_unsubscribe classification only); WF-15 (READ canonical for cache repair).
- **Constraints:** `uq_supp_active_global` (email WHERE active AND GLOBAL), `uq_supp_active_campaign` (email, campaign_id WHERE active AND CAMPAIGN), `idx_supp_email`, `idx_supp_lead`.
- **Privileges:** SELECT/INSERT/UPDATE; **DELETE revoked** (live-verified).
- **Cache contract:** `leads.suppression_status` is denormalized; canonical lookup wins; disagreement BLOCKS sending (fail-closed); WF-15 repairs.

### §3.10 `suppression_events` (append-only history)
- **Columns:** event_id (PK), suppression_id (FK), action (`suppression_event_action_enum`: ACTIVATED/DEACTIVATED/SCOPE_CHANGED/REASON_UPDATED), old/new scope, old/new reason, actor (default 'n8n_service'), source_event_id, occurred_at.
- **Accessed by:** WF-08/09/10/11 (INSERT ACTIVATED), WF-14 (READ during replay evidence review), WF-15 (READ).
- **Privileges:** SELECT/INSERT only (live-verified: DELETE denied).
- **Note:** DEACTIVATED/SCOPE_CHANGED/REASON_UPDATED rows are created only via explicitly authorized audited actions — no runtime workflow contract issues them.

### §3.11 `email_events` (Warmbly webhook events)
- **Columns:** event_id (PK), warmbly_event_id (provider event ID traceability), idempotency_key (TEXT NOT NULL UNIQUE — primary dedup), lead_id/campaign_id/mailbox_id (FKs), event_type (`email_event_enum`: SENT/DELIVERED/SOFT_BOUNCE/HARD_BOUNCE/REPLY/UNSUBSCRIBE/SPAM_COMPLAINT/OPEN/CLICK), bounce_type ('soft'|'hard'), smtp_diag, occurred_at (NOT NULL), raw_payload (JSONB NOT NULL), processed_at (NULL until processor completes), created_at.
- **Accessed by:** WF-07 (INSERT raw), WF-08/09/10/11/12 (READ + UPDATE processed_at), WF-15/16 (READ — metrics/reconciliation).
- **Constraints:** idempotency_key UNIQUE; `idx_events_time`, `idx_events_metrics`, `idx_events_lead`, FK indexes.
- **Key contract:** key = warmbly_event_id when supplied, else deterministic fallback — **exact fallback composition = DB-D4 OPEN** (design candidate in Schema §12; not resolved).
- **Note:** raw_payload JSONB NOT NULL means non-JSON payloads cannot be stored here — unparseable evidence goes to `dead_letter_events.payload_ref` (WF-07 contract).

### §3.12 `replies`
- **Columns:** reply_id (PK), event_id (FK→email_events), lead_id (FK NOT NULL), campaign_id (FK), classification (`reply_class_enum`: positive/negative/explicit_unsubscribe/out_of_office/neutral), classifier ('n8n'|'manual', default 'n8n'), body_excerpt, received_at (NOT NULL), created_at.
- **Accessed by:** WF-08 (INSERT + READ for classification context), WF-14 (READ replay).
- **Constraints:** `idx_replies_lead`, FK indexes.
- **Transaction rule:** reply INSERT + lifecycle_events + processed_at per WF-08 contract; dedup via event idempotency.

### §3.13 `lifecycle_events` (append-only audit)
- **Columns:** event_id (PK), lead_id (FK NOT NULL), from_status (nullable — initial), to_status (NOT NULL), reason, triggered_by (default 'n8n'), metadata JSONB, occurred_at.
- **Accessed by:** WF-01/02/03/04/05/06/08/09/10/12 (INSERT on approved transitions); WF-13 (READ — due-determination basis: latest PARKED transition occurred_at); WF-14/15/16 (READ).
- **Privileges:** SELECT/INSERT only (live-verified).
- **Invariant:** records ONLY approved transitions over the 14-state enum; RETRY/REVIEW go to workflow_runs/DLQ; suppression changes to suppression_events; NEVER UPDATE/DELETE.

### §3.14 `policy_config` (current effective configuration)
- **Columns:** config_id (PK), config_key, scope_type (`config_scope_enum`: GLOBAL/DOMAIN/MAILBOX/CAMPAIGN), scope_id (NULL iff GLOBAL; polymorphic UUID — NOT FK-validated), value (typed at read time), value_note, updated_by, updated_at. CHECK: GLOBAL⇔scope_id NULL.
- **Accessed by:** WF-03/04/05/06/09/13/16 (READ — runtime values ONLY; config_history NEVER a runtime source).
- **Constraints:** `uq_config_global`, `uq_config_scoped`.
- **Registry (13 keys, all NULL = fail-closed):** daily_send_cap_per_mailbox, sending_window, send_spacing_min, send_spacing_max, warmup_period_days, bounce_pause_threshold, complaint_pause_threshold, minimum_sample_size, verification_valid_for_days, c_fit_revisit_days, catch_all_policy, negative_reply_cooldown_days, apollo_credits_alert_pct.
- **Write path:** NO runtime workflow writes policy_config. Config changes = audited manual path (UPDATE policy_config + INSERT config_history, same transaction). **WF-15 reconciliation obligation (schema-mandated):** verify every non-NULL scope_id references an existing row in the table matching scope_type (polymorphic-FK limitation); report + alert violations.

### §3.15 `config_history` (immutable audit)
- **Columns:** id (BIGINT IDENTITY PK), config_key, scope_type, scope_id, old_value, new_value, changed_by, changed_at, change_reason.
- **Accessed by:** NO runtime workflow (audit trail only; audit/forensic reads by admin tooling, not workflows).
- **Privileges:** SELECT/INSERT only.

### §3.16 `workflow_runs`
- **Columns:** run_id (PK), workflow_name, n8n_exec_id, status ('ok'|'failed'|'retried'|'dead_lettered' CHECK), lead_id/campaign_id (optional correlation FKs), external_ref, items_in, items_out, error, started_at (NOT NULL), finished_at.
- **Accessed by:** ALL 16 workflows (INSERT at start, UPDATE on completion/failure). WF-16 (READ — failure-rate metrics).
- **Constraints:** `idx_runs_status`, FK indexes.
- **Contract:** every execution writes exactly one run record; status CHECK-constrained; no invented columns.

### §3.17 `dead_letter_events`
- **Columns:** event_id (PK), workflow (TEXT), payload_ref (TEXT NOT NULL), error (TEXT NOT NULL), attempt_count (default 0), last_attempt_at, status (`dlq_status_enum`: OPEN/REPLAYED/RESOLVED/DISCARDED, default OPEN), lead_id (optional FK), created_at.
- **Accessed by:** WF-07/04/03/06/08/09/10/11/12 (INSERT on terminal failure/exhaustion — per contracts), WF-14 (READ + UPDATE status/attempt_count), WF-16 (READ — depth metrics).
- **Constraints:** `idx_dlq_lead`; FK index.
- **Alert rule:** OPEN count above configured threshold in window → alert (thresholds config; NULL → fail-closed no-alert + config audit).

---

## §4 WF-01…WF-16 × 17-Table Access Matrix

Legend: R=READ, I=INSERT, U=UPDATE, — =no access.

| WF | sending_domains | mailboxes | companies | leads | lead_enrichment | verification_results | campaigns | campaign_assignments | suppression_list | suppression_events | email_events | replies | lifecycle_events | policy_config | config_history | workflow_runs | dead_letter_events |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| WF-01 | — | — | R,I | R,I | — | — | — | — | R | — | — | — | I | — | — | I,U | — |
| WF-02 | — | — | — | R,U | — | — | — | — | R | — | — | — | I | — | — | I,U | — |
| WF-03 | — | — | R,I,U | R,U | R,I | — | R | — | R | — | — | — | I | R | — | I,U | — |
| WF-04 | — | — | — | R,U | R | R,I | — | — | R | — | — | — | I | R | — | I,U | I |
| WF-05 | — | — | — | R,U | — | R | R | R | R | — | — | — | I | R | — | I,U | — |
| WF-06 | — | R | — | R | — | R | R | R,I | R | — | — | — | I | R | — | I,U | I |
| WF-07 | — | — | — | R | — | — | — | — | — | — | I | — | — | — | — | I,U | I |
| WF-08 | — | — | — | R,U | — | — | — | R | R,U | I | R,U | I | I | R | — | I,U | I |
| WF-09 | — | — | — | R,U | — | — | — | R | R,U | I | R,U | — | I | R | — | I,U | I |
| WF-10 | — | — | — | R,U | — | — | — | R | R,I,U | I | R,U | — | I | — | — | I,U | I |
| WF-11 | — | — | — | R | — | — | — | — | R,I,U | I | R,U | — | — | — | — | I,U | I |
| WF-12 | — | — | — | R,U | — | — | — | R,U | — | — | R,U | — | I | — | — | I,U | I |
| WF-13 | — | — | — | R | — | — | R | — | — | — | — | — | R | R | — | I,U | — |
| WF-14 | — | — | — | R | — | R | — | R | R | R | R | R | R | — | — | I,U | R,U |
| WF-15 | — | — | — | R,U | — | R | — | R | R | R | R | — | — | R | — | I,U | R |
| WF-16 | R | R | — | — | — | — | — | — | — | — | R | — | — | R | — | R | R |

All UPDATE operations on `leads` cache/lifecycle columns follow the same-transaction contracts; all history-table operations are INSERT-only (privilege-enforced).

## §5 Append-Only & Integrity Summary

- **Append-only (privilege-enforced):** verification_results, suppression_events, lifecycle_events, config_history — UPDATE/DELETE revoked; live-verified on migration 05a.
- **No DELETE anywhere at runtime:** all tables use soft-deactivation (`active` flags) or status transitions; outreach_app has no DELETE grants on any table.
- **Cache-consistency contracts (application-enforced, NOT PostgreSQL-enforced):**
  1. `leads.verification_status` ↔ latest `verification_results` row (same-tx insert+update; Schema §7).
  2. `leads.suppression_status` ↔ active `suppression_list` by canonical email (same-tx; Schema §5.9/§10).
  - On disagreement: canonical wins; cache repaired toward canonical; disagreement BLOCKS sending until repaired (never permits).
- **Suppression history preservation:** lifecycle history preserved when suppression activates; SUPPRESSED is NOT a lifecycle state; no lifecycle rewrite for complaints.
- **No cross-DB FKs:** n8n_db ↔ outreach_db consistency is workflow-enforced only.

## §6 Application-Enforced Invariants (not DB-enforced)

1. Identity resolution hierarchy (no auto-merge on ambiguity).
2. Cache synchronization contracts (§5 above).
3. Eligibility gate logic (SEND_ELIGIBLE conceptual — evaluated by WF-05, no physical state).
4. Conflict/concurrency policy (`conflict_group` evaluation; no blanket one-active-campaign constraint).
5. Email mutation restraint (DB-D7 OPEN — no mutation out from under active suppression without re-evaluation).
6. In-flight verification guard (WF-04; workflow-level, no DB column).
7. Enrollment confirmation semantics (no IN_SEQUENCE without confirmed Warmbly enrollment).
8. Idempotency-key fallback composition (DB-D4 OPEN).
9. Warmbly propagation idempotency (execution-only; re-propagation harmless).

## §7 WF-15 Reconciliation Obligations (schema-mandated)

1. `leads` cache repair toward canonical (verification + suppression).
2. `policy_config` scope_id integrity — every non-NULL scope_id must exist in the table matching its scope_type (polymorphic-FK limitation, Schema §5.14).
3. Warmbly enrollment-state comparison — **BLOCKED/TO VERIFY** until Warmbly query capability is confirmed; no endpoint invented.
4. Cadence: OPEN (not fixed by approved docs).

## §8 Validation Checklist (executed — results in report)

1. Exactly 17 tables §3.1–§3.17 matching Schema v1.2 §5.1–§5.17 · 2. Exactly 16 workflow IDs in matrix · 3. All column/constraint/enum names from actual schema text · 4. Operations consistent with contracts §4 (contracts v1.1) · 5. Mismatches resolved (§3.1, §3.2 health ownership documented; §3.3 companies INSERT explicit in contracts v1.1) · 6. Append-only + no-DELETE rules per §5.18 · 7. Approved-vs-live distinction stated (§2) · 8. No invented privileges/objects.

## §9 Change Log

- v1.0 (2026-10-17): initial mapping draft from approved Database Schema v1.2 (actual §5.1–§5.18 text), master spec v1.1, contracts v1.0. Flagged gaps: sending_domains/mailboxes health_status writer undefined; companies INSERT not explicit in WF-01/WF-03 contracts. Status: Draft v1.0 — Pending Review. NOT approved.
