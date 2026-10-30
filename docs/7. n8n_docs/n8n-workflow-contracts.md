# SKMC Cold Email Automation — n8n Workflow Contracts

**Version:** 1.1 | **Date:** 2026-10-17 | **Status:** Draft v1.1 — Pending Review. **Not approved.**

**Master reference:** `n8n-workflow-spec.md` v1.1 (catalog §3; common rules §5). Workflow IDs are defined there and cross-referenced here — not redefined.

**Derived from (approved sources only):**
1. `architecture.md` v1.3 (Approved) 2. `database-schema.md` v1.2 (Approved baseline) 3. `lead-lifecycle-status-flow.md` v1.0 (Approved) 4. `api-integration-spec.md` v1.0 (Approved) 5. `verification-suppression-rules.md` v1.0 (Approved)

Campaign & ICP (v0.1 template) contributes NO policy. All 17 tables, all enums, all constraints use exact names from Database Schema v1.2.

---

## §1 Purpose

Defines the implementable behavior contract for each of the 16 workflows (WF-01…WF-16) from the master catalog. Every contract uses the same 27-field template (§2). Detailed workflow-to-table operations live in `n8n-database-mapping.md`; visual flows in `n8n-workflow-diagrams.md` — not duplicated here.

## §2 Contract Template — 27 fields

1. Workflow ID · 2. Name · 3. Purpose · 4. Trigger · 5. Preconditions · 6. Input contract · 7. Canonical identity resolution · 8. Database reads · 9. Decision/gates · 10. External calls · 11. Database writes · 12. Lifecycle effects · 13. Verification effects · 14. Suppression effects · 15. Campaign-assignment effects · 16. Success output · 17. Downstream workflow/event · 18. Retry behavior · 19. Terminal-failure behavior · 20. DLQ behavior · 21. Idempotency behavior · 22. Replay behavior · 23. Race-condition considerations · 24. Audit requirements · 25. Metrics/observability · 26. OPEN dependencies · 27. Traceability

No field is omitted; "None" is stated explicitly where empty.

## §3 Common Conventions (apply to every contract)

- **Error classes** (API §14): RETRYABLE / NON_RETRYABLE / RATE_LIMITED / AUTH_FAILURE / VALIDATION_FAILURE / PROVIDER_UNAVAILABLE / TIMEOUT / DUPLICATE_EVENT / POLICY_REJECTED.
- **Retry taxonomy** (Doc 6 §11; API §15): bounded configurable retry with backoff; Retry-After honored; RETRY/REVIEW are workflow states, NEVER lifecycle states; transient failure never advances lifecycle (Lifecycle §13).
- **Workflow-run contract** (Schema §5.16): every execution inserts/updates one `workflow_runs` row — `workflow_name`, `n8n_exec_id`, `status` ∈ ('ok','failed','retried','dead_lettered'), optional `lead_id`/`campaign_id`/`external_ref`, `items_in`/`items_out`, `error`, `started_at`/`finished_at`.
- **Identity resolution** (Arch §6; API §16): (1) `(source_system, external_lead_id)` → (2) normalized `email` → (3) `(source_system, external_person_id)` → (4) ambiguous → manual review, never auto-merge. Provider IDs are never trusted as identity without resolution (API §12).
- **Canonical-supremacy rule:** latest canonical SAFETY state wins over stale workflow work; append-only history (`verification_results`, `suppression_events`, `lifecycle_events`, `config_history`) is never updated or deleted (Schema §5.18 grants).
- **Fail-closed:** safety-critical gate undeterminable → no send/enroll/unsafe lifecycle mutation; auditing, error classification, DLQ ingestion and safety-direction updates (suppression ACTIVATION, cache repair toward canonical, alert emission) always permitted (Doc 6 §23; master spec §5.5).
- **Secrets:** never in payloads, logs, audit text, or docs (API §17).

---

## §4 Contracts

### §4.1 WF-01 — Lead Intake

1. **Workflow ID:** WF-01
2. **Name:** Lead Intake
3. **Purpose:** Ingest discovered contacts from OpenOutreach into canonical `leads` with approved identity/dedup semantics.
4. **Trigger:** OpenOutreach discovery event per API §6.1 output contract.
5. **Preconditions:** Source payload authenticated; schema-valid; `source_system` present; at least one identity key (`external_lead_id` / `external_person_id` / `email`) present.
6. **Input contract:** API §6.1 per-lead fields — names, `company`, `title`, email, source identifiers, qualification fields, trigger codes / signals / personalization_evidence. No fields invented.
7. **Canonical identity resolution:** Priority hierarchy (§3); enforced by `uq_leads_source_lead`, `uq_leads_source_person`, `uq_leads_email_resolved` (all partial, source-scoped — Schema §5.4).
8. **Database reads:** `leads` (identity lookup); `suppression_list` (canonical `email` lookup — pre-lead suppression may exist; Schema §5.9 identity contract).
9. **Decision/gates:** duplicate source event → DUPLICATE_EVENT ack, no re-apply; email-less lead → inserted (email nullable) but flagged — can never pass downstream eligibility gate (Arch §11); active suppression on email → lead still inserted, gate blocks downstream, NO paid verification spend (Doc 6 §24 #1).
10. **External calls:** None.
11. **Database writes:** `leads` INSERT; `companies` INSERT (company dedupe by `company_domain` at intake, per Schema §5.3 unique constraint); `lifecycle_events` INSERT; `workflow_runs`.
12. **Lifecycle effects:** → DISCOVERED (initial state).
13. **Verification effects:** `leads.verification_status` = NOT_CHECKED (default). No provider call.
14. **Suppression effects:** None created. Check-only.
15. **Campaign-assignment effects:** None.
16. **Success output:** `leads` row, `lifecycle_status='DISCOVERED'`, full audit trail.
17. **Downstream workflow/event:** WF-02 (qualification verdict ingestion, when OpenOutreach verdict arrives).
18. **Retry behavior:** RETRYABLE transport/infra failures → bounded retry; lifecycle unchanged.
19. **Terminal-failure behavior:** NON_RETRYABLE (malformed beyond repair) → DLQ; lead NOT inserted; no fabricated fields.
20. **DLQ behavior:** `dead_letter_events` row with `payload_ref`; manual review; replay re-runs insert (guarded by uniques).
21. **Idempotency behavior:** Business idempotency via the three partial unique indexes; duplicate discovery event → no-op.
22. **Replay behavior:** Safe — insert guarded by uniques; duplicate replay = no-op.
23. **Race-condition considerations:** Two concurrent identical discovery events → one insert wins, other is DUPLICATE_EVENT; identity ambiguity → HOLD for manual review.
24. **Audit requirements:** `lifecycle_events` (DISCOVERED); `leads.reason` internal audit only; `workflow_runs`.
25. **Metrics/observability:** received; created; duplicates; suppressed-at-intake; email-less count.
26. **OPEN dependencies:** signals parser contract version (`signals_schema_version` — Schema §9); retention/PII (Arch §28).
27. **Traceability:** Arch §6, §7; API §6.1–6.3, §16; Lifecycle §6; Schema §5.4, §5.9; Doc 6 §13, §24.

### §4.2 WF-02 — Qualification Ingestion

1. **Workflow ID:** WF-02
2. **Name:** Qualification Ingestion
3. **Purpose:** Persist OpenOutreach qualification verdict and apply the approved fit-model outcome.
4. **Trigger:** OpenOutreach qualification verdict event (API §6; Arch §7).
5. **Preconditions:** Lead resolvable via identity hierarchy; verdict maps exactly to `qualification_fit_enum` ('A_FIT','B_FIT','C_FIT','REJECT').
6. **Input contract:** source-scoped verdict + reasoning fields; mapping per API §6.2/§6.3 (provider detail status normalized before canonical effect).
7. **Canonical identity resolution:** §3 hierarchy; verdict applied to the resolved `lead_id` only.
8. **Database reads:** `leads` (identity + current state); `suppression_list` (email lookup — suppression does not change fit processing but gates all downstream spend).
9. **Decision/gates:** A_FIT/B_FIT → enrichment path; C_FIT → PARKED (revisit cadence `c_fit_revisit_days` — NULL = fail-closed); REJECT → terminal non-fit, **no paid processing** (no enrichment/verification/Warmbly spend); duplicate verdict → DUPLICATE_EVENT.
10. **External calls:** None.
11. **Database writes:** `leads` (`qualification_fit`, `lifecycle_status`); `lifecycle_events`; `workflow_runs`.
12. **Lifecycle effects:** DISCOVERED → QUALIFIED (A/B); DISCOVERED → PARKED (C); REJECT → lifecycle per approved transition table (Lifecycle §5) — no invented state.
13. **Verification effects:** None.
14. **Suppression effects:** None.
15. **Campaign-assignment effects:** None.
16. **Success output:** `leads.qualification_fit` set; lifecycle updated; audit row.
17. **Downstream workflow/event:** A/B → WF-03; C → eligible for WF-13 revisit; REJECT → none.
18. **Retry behavior:** RETRYABLE → bounded retry; lead holds in current lifecycle.
19. **Terminal-failure behavior:** NON_RETRYABLE/unmappable verdict → DLQ; no canonical write.
20. **DLQ behavior:** `dead_letter_events`; replay re-evaluates mapping (never invents a mapping).
21. **Idempotency behavior:** Duplicate verdict event → DUPLICATE_EVENT, no repeated lifecycle event.
22. **Replay behavior:** Safe — re-application guarded by identity + event idempotency; lifecycle transition re-check guards (from_status match).
23. **Race-condition considerations:** Simultaneous qualification updates → latest canonical verdict wins; earlier evidence retained in append-only history.
24. **Audit requirements:** `lifecycle_events` (from_status → to_status, reason, triggered_by='n8n'); `workflow_runs`.
25. **Metrics/observability:** verdicts received; per-fit counts; duplicate verdicts; unmappable verdicts.
26. **OPEN dependencies:** C-Fit revisit cadence `c_fit_revisit_days` (NULL); Campaign/ICP fit thresholds remain draft — no promotion into policy.
27. **Traceability:** Arch §7, §8, §9; API §6.2, §6.3; Lifecycle §5, §6; Schema §5.4, §4 enums; Doc 6 §24.

### §4.3 WF-03 — Enrichment Orchestration

1. **Workflow ID:** WF-03
2. **Name:** Enrichment Orchestration
3. **Purpose:** Conditional supplemental enrichment via Apollo; never unconditional spend.
4. **Trigger:** WF-02 completion for QUALIFIED leads where approved rules require enrichment.
5. **Preconditions:** Lead QUALIFIED; email resolvable or enrichment independent of email per approved rules; enrichment-needed determination computed (missing required fields vs `campaigns.required_fields` when campaign context exists).
6. **Input contract:** lead_id + requested field set (approved fields only; no invented Apollo fields — API §7).
7. **Canonical identity resolution:** Already resolved (WF-01/02); enrichment binds to `lead_id`.
8. **Database reads:** `leads`; `lead_enrichment` (existing rows — double-buy guard); `campaigns.required_fields` (where campaign context known).
9. **Decision/gates:** enrichment needed? (conditional — Arch §14); double-buy guard: existing successful enrichment for lead+fields → skip provider call, record `skipped=TRUE`; suppression check (avoid spend on suppressed contact).
10. **External calls:** Apollo per API §7 contract (optional/supplemental).
11. **Database writes:** `lead_enrichment` INSERT (`provider`, `requested_fields`, `returned_fields`, `raw_response`, `skipped`); `leads` cache columns from returned fields; `companies` INSERT/UPDATE (enrichment-driven profile fields where approved, company dedupe by `company_domain` per Schema §5.3); `lifecycle_events`; `workflow_runs`.
12. **Lifecycle effects:** ENRICHMENT_PENDING → ENRICHED (approved transition, Lifecycle §7).
13. **Verification effects:** None.
14. **Suppression effects:** None.
15. **Campaign-assignment effects:** None.
16. **Success output:** enrichment row + lead cache updated + ENRICHED.
17. **Downstream workflow/event:** WF-04.
18. **Retry behavior:** RETRYABLE / RATE_LIMITED / TIMEOUT → bounded backoff (API §15); lifecycle unchanged during retry.
19. **Terminal-failure behavior:** AUTH_FAILURE / VALIDATION_FAILURE / NON_RETRYABLE → DLQ; lifecycle holds at ENRICHMENT_PENDING.
20. **DLQ behavior:** `dead_letter_events`; replay re-runs guarded by double-buy guard.
21. **Idempotency behavior:** Double-buy guard (existing-enrichment check before call); replay cannot double-spend without a state change justifying it.
22. **Replay behavior:** Guarded — guard re-evaluated on replay.
23. **Race-condition considerations:** Two concurrent enrichment triggers → guard check + insert ordering; second sees first's row and skips.
24. **Audit requirements:** `lead_enrichment.raw_response` retained per approved model; `workflow_runs`.
25. **Metrics/observability:** enrichment calls; skips (guard); failures by class; Apollo credit usage.
26. **OPEN dependencies:** Apollo credits alert threshold `apollo_credits_alert_pct` (NULL); Apollo endpoint/payload facts TO VERIFY where API §7 marks them; retention.
27. **Traceability:** Arch §5, §14; API §7; Lifecycle §7; Schema §5.5, §9; Doc 6 §24.

### §4.4 WF-04 — Verification Orchestration

1. **Workflow ID:** WF-04
2. **Name:** Verification Orchestration
3. **Purpose:** Canonical email verification per Doc 6 exactly — ZeroBounce primary, MillionVerifier conditional; credit economy; append-only history.
4. **Trigger:** WF-03 completion (or WF-02 path where enrichment not required).
5. **Preconditions:** Lead has resolved `email` (email-less lead can never reach here — Arch §11); current suppression state checked.
6. **Input contract:** lead_id + canonical email (CITEXT-normalized).
7. **Canonical identity resolution:** bound to resolved `lead_id`; verification always of the CURRENT canonical email — an email change invalidates prior-address evidence (Doc 6 §21 #3).
8. **Database reads:** `leads`; `verification_results` latest row (`idx_verif_lead_fresh`); `suppression_list` (email); `policy_config` (`verification_valid_for_days`, `catch_all_policy`).
9. **Decision/gates:** (a) suppression precheck — active suppression → no spend; (b) freshness — latest `checked_at` vs `verification_valid_for_days` (NULL → fail-closed); (c) acceptable existing result → no call (credit economy); (d) in-flight verification guard (workflow-level — no approved DB column; implementation decision); (e) provider call → normalization (API §9.2/§10.2) → canonical status ∈ 8-value enum exactly; (f) fallback decision per policy.
10. **External calls:** ZeroBounce (primary, API §9); MillionVerifier (conditional fallback/second opinion per policy — API §10.3). Never both by default (Schema §7).
11. **Database writes:** `verification_results` INSERT (append-only; full provider metadata columns; `is_fallback` flag); `leads.verification_status` update IN SAME TRANSACTION as history INSERT (Schema §7 consistency contract); `lifecycle_events`; `workflow_runs`.
12. **Lifecycle effects:** VERIFICATION_PENDING → VERIFIED (VALID+fresh); INVALID/DISPOSABLE → lifecycle REMAINS VERIFICATION_PENDING (approved overlay — no lifecycle rewrite); CATCH_ALL/RISKY/UNKNOWN/TEMPORARY_FAILURE → lifecycle HOLDS at VERIFICATION_PENDING.
13. **Verification effects:** New append-only history row per actual check; reverification = new row, never update.
14. **Suppression effects:** **Only a canonical verdict INVALID or DISPOSABLE activates `invalid_email` suppression** (scope per configured policy). **Provider/technical failures (TEMPORARY_FAILURE, TIMEOUT, PROVIDER_UNAVAILABLE, AUTH_FAILURE, malformed response) produce NO canonical verdict → NO suppression of any kind** (Doc 6 §11).
15. **Campaign-assignment effects:** None.
16. **Success output:** canonical status persisted + cache synchronized.
17. **Downstream workflow/event:** VALID+fresh → WF-05. CATCH_ALL/RISKY → hold-for-review per policy. Others → retry/fallback path.
18. **Retry behavior:** UNKNOWN/TEMPORARY_FAILURE/timeout/unavailable → bounded retry, then MV fallback per policy (API §10.3); each attempt appends evidence (Doc 6 §11).
19. **Terminal-failure behavior:** AUTH_FAILURE → alert + DLQ, fix credentials out-of-band; malformed provider response → VALIDATION_FAILURE → DLQ, **no canonical write**; conflicting provider results → latest row by `checked_at` governs, both rows retained, contradiction is a review signal (Doc 6 §11).
20. **DLQ behavior:** `dead_letter_events` + `workflow_runs` failure; replay re-runs verification only if freshness/need still justifies.
21. **Idempotency behavior:** Pre-call freshness check prevents duplicate spend; replay writes a new history row only when a recheck actually occurred (API §16).
22. **Replay behavior:** Full gate re-evaluation before any provider call.
23. **Race-condition considerations:** Two concurrent verifications → in-flight guard (workflow-level); email change during verification → result applies to evidence of the checked address only (DB-D7 OPEN governs mutation).
24. **Audit requirements:** every attempt appended (`verification_results`); provider failure class recorded; `workflow_runs`.
25. **Metrics/observability:** provider calls; per-status counts; retries; fallback usage; suppression activations from verdicts.
26. **OPEN dependencies:** `verification_valid_for_days` (NULL); `catch_all_policy` (NULL); MV fallback thresholds (policy, OPEN); in-flight guard mechanism (n8n implementation decision).
27. **Traceability:** Arch §10, §11, §12; API §8, §9, §10, §16; Lifecycle §8; Schema §5.6, §7, §5.18; Doc 6 §6–§11, §24, §25.

### §4.5 WF-05 — Campaign Eligibility Gate (incl. re-entry evaluation)

1. **Workflow ID:** WF-05
2. **Name:** Campaign Eligibility Gate
3. **Purpose:** Deterministic evaluation of the approved send-eligibility formula; gate-only — no external actions.
4. **Trigger:** WF-04 pass (VERIFIED+fresh) OR explicit approved re-entry trigger (NEW campaign launch / owner decision — never automatic).
5. **Preconditions:** Lead resolvable; campaign context provided (campaign_id); campaign `active`.
6. **Input contract:** lead_id, campaign_id, evaluation context.
7. **Canonical identity resolution:** bound to resolved lead; suppression matched on canonical email.
8. **Database reads:** `leads` (via `idx_leads_gate`); `suppression_list` (canonical email lookup); `verification_results` (latest by `idx_verif_lead_fresh`); `campaigns` (`required_fields`, `signals_template_keys`, `conflict_group`); `campaign_assignments` (active-assignment join for conflict evaluation); `policy_config` (values only at runtime — `config_history` NEVER a runtime source; row uniqueness per `uq_config_global`/`uq_config_scoped`).
9. **Decision/gates:** full Doc 6 §22 formula: email resolved AND no effective suppression (ANY active suppression blocks, fail-closed) AND current verification exists AND fresh AND acceptable under campaign policy (VALID; CATCH_ALL/RISKY only if policy admits — OPEN) AND lifecycle permits AND campaign eligibility (fit, required fields) AND conflict/concurrency passes (`conflict_group` evaluation + explicit-permission path, Arch §13) AND personalization/template keys pass (fail-closed, Arch §29 #14) AND all required configuration resolvable. **SEND_ELIGIBLE is conceptual logic — no new lifecycle state, no new table.**
10. **External calls:** None.
11. **Database writes:** On FULL pass: `leads.lifecycle_status → CAMPAIGN_READY`; `lifecycle_events` append; `workflow_runs`. Re-entry with stale verification: approved transition VERIFIED → VERIFICATION_PENDING (reverify).
12. **Lifecycle effects:** VERIFIED → CAMPAIGN_READY (only on full gate pass).
13. **Verification effects:** check-only (may route to reverification via WF-04).
14. **Suppression effects:** Check-only. No mutation.
15. **Campaign-assignment effects:** Check-only (conflict evaluation reads active assignments; `company_domain` never used for concurrency).
16. **Success output:** CAMPAIGN_READY + audit row, or documented gate rejection (reason recorded, lead holds).
17. **Downstream workflow/event:** WF-06.
18. **Retry behavior:** Infra failure during evaluation → bounded retry; lead holds; no lifecycle mutation on infra failure (Lifecycle §13).
19. **Terminal-failure behavior:** Persistent config missing (NULL gate values) → fail-closed block + alert; fix via audited config change.
20. **DLQ behavior:** N/A (gate holds/rejects are POLICY_REJECTED observations, not DLQ items) — but persistent DB unavailability → workflow retry → DLQ.
21. **Idempotency behavior:** Gate evaluation is read-only until pass; repeated evaluation safe; CAMPAIGN_READY transition guarded by from_status check.
22. **Replay behavior:** Safe — re-evaluates current canonical state; never caches a stale PASS.
23. **Race-condition considerations:** Suppression arriving during evaluation → latest canonical state wins; evaluation result never overrides a newer canonical SAFETY state; conflict decision unresolved at runtime → BLOCK (Doc 6 §23).
24. **Audit requirements:** gate outcome + per-gate reason recorded (observable rejection); `workflow_runs`.
25. **Metrics/observability:** evaluations; pass/reject counts per gate; stale-verification blocks; conflict blocks.
26. **OPEN dependencies:** `catch_all_policy`, `verification_valid_for_days`, `negative_reply_cooldown_days` (re-entry cooldown), conflict-resolution details (Arch §28 #7), DB-D8 coexistence/precedence.
27. **Traceability:** Arch §11, §13, §29; Doc 6 §21, §22, §23, §25; Lifecycle §9, §14, §20; Schema §5.4, §5.7, §5.8, §7, §8.

### §4.6 WF-06 — Assignment + Warmbly Enrollment

1. **Workflow ID:** WF-06
2. **Name:** Assignment + Warmbly Enrollment
3. **Purpose:** Create campaign assignment and enroll the lead in Warmbly — the highest-risk external action, gated behind all tested safety paths (master spec §7).
4. **Trigger:** WF-05 pass (lead CAMPAIGN_READY).
5. **Preconditions:** WF-05 approval AND **immediate pre-enrollment recheck** (in addition to WF-05): (a) current suppression — canonical `email` lookup on `suppression_list` (any active suppression → BLOCK; DB §5.9); (b) verification freshness — latest `checked_at` vs `verification_valid_for_days`; (c) assignment conflicts — active-assignment join + `campaigns.conflict_group` comparison (Schema §8).
6. **Input contract:** lead_id, campaign_id; personalization payload validated against `campaigns.signals_template_keys` (fail-closed — unknown/unapproved/missing key → reject sync, Arch §29 #14).
7. **Canonical identity resolution:** bound to resolved lead; suppression keyed by email.
8. **Database reads:** `suppression_list`; `verification_results`; `leads`; `campaigns`; `campaign_assignments`; `policy_config` (send caps/windows — NULL → fail-closed no-enroll).
9. **Decision/gates:** recheck gates (Preconditions) → assignment insert (guarded by `uq_assign_active_lead_campaign`) → Warmbly enrollment/sync call → **IN_SEQUENCE only on CONFIRMED enrollment** (no confirmed sync = no lifecycle transition — Lifecycle §5; Doc 6 §23).
10. **External calls:** Warmbly enrollment/sync per API §11 internal contract. **Warmbly endpoint paths, auth format, webhook names, event IDs, retry semantics: TO VERIFY — implementation placeholders, nothing invented.**
11. **Database writes:** `campaign_assignments` INSERT; `lifecycle_events`; `workflow_runs`.
12. **Lifecycle effects:** CAMPAIGN_READY → IN_SEQUENCE (only after confirmed enrollment).
13. **Verification effects:** None (freshness check only).
14. **Suppression effects:** None created; blocking check.
15. **Campaign-assignment effects:** `campaign_assignments` INSERT (`enrolled_at`); historical re-enrollment creates a NEW row (exited rows never deleted).
16. **Success output:** active assignment row + IN_SEQUENCE + Warmbly confirmation reference (`workflow_runs.external_ref`).
17. **Downstream workflow/event:** WF-07 (webhook feedback).
18. **Retry behavior:** Enrollment call RETRYABLE/TIMEOUT → bounded retry with same correlation; duplicate sync attempts guarded by assignment uniqueness (API §16).
19. **Terminal-failure behavior:** DB write succeeded + Warmbly failed → assignment exists, NOT IN_SEQUENCE, reconcile (WF-15); Warmbly succeeded + DB ack failed → unknown outcome → HOLD + reconcile, never assume enrolled; timeout/uncertain → DO NOT treat as enrolled (Doc 6 §23).
20. **DLQ behavior:** uncertain/failed enrollment → `dead_letter_events` after exhaustion; replay re-checks ALL safety gates before any re-sync.
21. **Idempotency behavior:** Business: `uq_assign_active_lead_campaign`; workflow-execution: `workflow_runs` + n8n_exec_id; enrollment requires fresh canonical pre-state.
22. **Replay behavior:** Full pre-enrollment recheck repeated; replay never bypasses current suppression/freshness.
23. **Race-condition considerations:** Suppression arrives during enrollment → stop propagation immediately; safety wins over in-flight enrollment (Doc 6 §30 F); verification becomes stale mid-enrollment → abort; two concurrent enrollments → unique index blocks second.
24. **Audit requirements:** `workflow_runs` (external_ref), `lifecycle_events`, enrollment-rejection observability; no secrets in any record.
25. **Metrics/observability:** enrollments; recheck rejections (per gate); sync failures by class; uncertain outcomes.
26. **OPEN dependencies:** Warmbly endpoints/auth/webhooks (TO VERIFY); DB-D4 (idempotency composition); DB-D7 (email mutation); send caps/window configs (NULL); Arch §28 mailbox rotation.
27. **Traceability:** Arch §13, §17, §29; API §11, §16; Lifecycle §5, §10; Schema §5.8, §8, §5.14; Doc 6 §22, §23, §24, §30F.

### §4.7 WF-07 — Webhook Ingestion

1. **Workflow ID:** WF-07
2. **Name:** Webhook Ingestion
3. **Purpose:** Generic ingestion of Warmbly events into canonical `email_events`; durable, idempotent, fail-safe.
4. **Trigger:** Warmbly webhook (HTTP).
5. **Preconditions:** Endpoint authentication/verification — **placeholder; mechanism TO VERIFY** (API §12). Unauthenticated → reject (POLICY_REJECTED).
6. **Input contract:** Warmbly native payload (names/fields OPEN) mapped by adapter to conceptual events (API §12): DELIVERY/SENT, REPLY, BOUNCE (hard/soft), UNSUBSCRIBE, SPAM_COMPLAINT, SEQUENCE COMPLETION, optional OPEN/CLICK → `email_event_enum` values only.
7. **Canonical identity resolution:** provider identifiers resolved against canonical lead (identity hierarchy) — never trusted directly (API §12).
8. **Database reads:** `leads` (identity resolution); `email_events` (duplicate check).
9. **Decision/gates:** pipeline = authenticate → parse → schema-validate → resolve lead → dedupe → insert → route → ack (API §12). Case handling: **DUPLICATE** (idempotency_key already exists) → original event row untouched, NO business effect repeated, 2xx ack, DUPLICATE_EVENT logged. **UNPARSEABLE payload** (non-JSON) → cannot satisfy `email_events.raw_payload JSONB NOT NULL` → `dead_letter_events` row (`payload_ref`), no `email_events` insert, ack 2xx to prevent retry storm (or 4xx per verified provider contract — TO VERIFY). **Schema-valid JSON but unknown event type / missing required identifiers** → not insertable into `email_events` (`event_type` NOT NULL enum) → DLQ "mapping unknown"/"identity unresolved", evidence preserved via `payload_ref`. **OUT-OF-ORDER** → per-event idempotent; ordering not required for correctness; terminal-ish events (unsubscribe/complaint) never resurrected by later delivery events; delivery events for suppressed/stopped leads logged and ignored for lifecycle purposes (API §12).
10. **External calls:** None (receives).
11. **Database writes:** `email_events` INSERT (raw_payload persisted verbatim; `warmbly_event_id` when supplied; `processed_at` NULL until processor completes); `workflow_runs`.
12. **Lifecycle effects:** None directly (processors own transitions).
13. **Verification effects:** None.
14. **Suppression effects:** None directly.
15. **Campaign-assignment effects:** None.
16. **Success output:** persisted event row + routed processor + 2xx ack.
17. **Downstream workflow/event:** WF-08 (REPLY), WF-09 (bounces), WF-10 (UNSUBSCRIBE), WF-11 (SPAM_COMPLAINT), WF-12 (completion); OPEN/CLICK → metrics only.
18. **Retry behavior:** Ingestion itself is at-least-once from provider; idempotency absorbs redelivery; provider retry semantics TO VERIFY.
19. **Terminal-failure behavior:** Persistent unparseable/unmappable → DLQ + alert; webhook endpoint failure → provider retry per TO VERIFY semantics.
20. **DLQ behavior:** `dead_letter_events` with payload_ref; replay = re-run classification/mapping; if mapping later defined, event re-processed under DB-D4-consistent key.
21. **Idempotency behavior:** `email_events.idempotency_key UNIQUE NOT NULL`; key = `warmbly_event_id` when supplied, else deterministic fallback from stable attributes — **exact fallback composition = DB-D4 OPEN (design candidate in Schema §12, not resolved)**.
22. **Replay behavior:** Duplicate replay → DUPLICATE_EVENT path; original row never overwritten.
23. **Race-condition considerations:** duplicate + out-of-order simultaneously → dedupe first, then event-semantics rules (API §12); webhook arrives before enrollment ack → event logged, no enrollment implied.
24. **Audit requirements:** raw payload retained per approved model; DUPLICATE_EVENT + DLQ routes logged; `workflow_runs`.
25. **Metrics/observability:** received; persisted; duplicates; unmappable; unauthenticated rejects; processing latency.
26. **OPEN dependencies:** DB-D4 (key composition); Warmbly webhook auth/event names/payload fields/ordering guarantees (TO VERIFY); endpoint auth mechanism (n8n implementation decision).
27. **Traceability:** Arch §20; API §12, §14, §16; Lifecycle §16; Schema §5.11, §12; Doc 6 §26.

### §4.8 WF-08 — Reply Processing

1. **Workflow ID:** WF-08
2. **Name:** Reply Processing
3. **Purpose:** Apply approved reply-classification semantics to REPLY events.
4. **Trigger:** WF-07-routed REPLY event (`email_events.event_type='REPLY'`, `processed_at` NULL).
5. **Preconditions:** Event row exists; lead resolved; reply content available.
6. **Input contract:** event_id, lead_id, campaign_id, reply body reference.
7. **Canonical identity resolution:** already resolved at ingestion; classification binds to lead_id.
8. **Database reads:** `email_events`; `leads`; `suppression_list` (context); reply policy config where defined.
9. **Decision/gates:** classify → `reply_class_enum` exactly: positive / negative / explicit_unsubscribe / out_of_office / neutral. positive → stop sequence + sales-flow handoff (NO CRM states — DB-D3); negative → stop/exit per reply policy, **NO automatic suppression** (`negative_reply` is not a suppression reason); explicit_unsubscribe → unsubscribe semantics (see WF-10); out_of_office → configurable pause/resume per reply policy (OPEN); neutral → route per reply policy.
10. **External calls:** Warmbly sequence-stop where reply policy requires (execution-only; TO VERIFY endpoints).
11. **Database writes:** `replies` INSERT (`classification`, `classifier='n8n'`, `body_excerpt`, `received_at`); `lifecycle_events` on transitions; `suppression_list`+`suppression_events` ONLY for explicit_unsubscribe; `email_events.processed_at`; `workflow_runs`.
12. **Lifecycle effects:** positive → IN_SEQUENCE → REPLIED_POSITIVE; negative → IN_SEQUENCE → REPLIED_NEGATIVE; explicit_unsubscribe → IN_SEQUENCE → UNSUBSCRIBED; out_of_office/neutral → none by themselves.
13. **Verification effects:** None.
14. **Suppression effects:** Only `explicit_unsubscribe` classification → GLOBAL `explicit_unsubscribe`. Negative reply creates NO suppression record (Doc 6 §18).
15. **Campaign-assignment effects:** Stop/exit per reply policy where lifecycle leaves the sequence.
16. **Success output:** persisted reply + classification + applied semantics.
17. **Downstream workflow/event:** positive → sales handoff (downstream process, not a workflow state); negative → cooldown applies to any future re-entry (OPEN value).
18. **Retry behavior:** RETRYABLE infra → bounded; classification unchanged.
19. **Terminal-failure behavior:** unclassifiable reply → REVIEW (workflow state) — no guessed classification; → DLQ after bounded review period.
20. **DLQ behavior:** `dead_letter_events`; replay re-runs classification (may be classified manually — `classifier='manual'`).
21. **Idempotency behavior:** reply rows deduped via event idempotency (API §12); duplicate REPLY event → DUPLICATE_EVENT, no second lifecycle transition.
22. **Replay behavior:** guarded by event idempotency + from_status transition checks.
23. **Race-condition considerations:** reply crossing completion event → both processed independently; terminal-ish classification wins for safety; reply during enrollment → safety semantics apply.
24. **Audit requirements:** `replies` row + `lifecycle_events` + `email_events.processed_at`; classifier identity recorded.
25. **Metrics/observability:** replies by classification; unclassifiable count; manual classifications.
26. **OPEN dependencies:** `negative_reply_cooldown_days` (NULL); out_of_office pause/resume policy (reply policy — OPEN); sequence-stop endpoint (TO VERIFY).
27. **Traceability:** Arch §15, §16; API §12; Doc 6 §16, §18; Lifecycle §11; Schema §5.12, §4 reply_class_enum.

### §4.9 WF-09 — Bounce Processing

1. **Workflow ID:** WF-09
2. **Name:** Bounce Processing
3. **Purpose:** Apply approved hard/soft bounce semantics; keep observed bounce separate from verification status.
4. **Trigger:** WF-07-routed bounce event (event_type SOFT_BOUNCE / HARD_BOUNCE).
5. **Preconditions:** event row; lead resolved; `bounce_type` present ('soft' | 'hard' — Schema §5.11).
6. **Input contract:** event_id, lead_id, campaign_id, bounce_type, `smtp_diag`.
7. **Canonical identity resolution:** resolved at ingestion.
8. **Database reads:** `email_events`; `leads`; bounce policy config (scope for `hard_bounce` suppression — OPEN value).
9. **Decision/gates:** hard → BOUNCED + suppression per approved bounce policy; soft → lifecycle unchanged (not lifecycle-terminal by itself — Lifecycle §11), escalation to suppression ONLY via approved bounce policy (threshold config `bounce_pause_threshold` — NULL → fail-closed, no escalation).
10. **External calls:** Warmbly stop for hard bounce (execution-only).
11. **Database writes:** `lifecycle_events` (hard); `suppression_list`+`suppression_events` (hard, per policy); `email_events.processed_at`; `workflow_runs`.
12. **Lifecycle effects:** hard: IN_SEQUENCE → BOUNCED. soft: none.
13. **Verification effects:** None — the observed bounce is delivery evidence, NOT a verification status; prior verification not retroactively invalidated (Arch §29 #6). No `bounce_risk_score` exists.
14. **Suppression effects:** hard → `hard_bounce` reason, scope per configured policy (OPEN — GLOBAL via `uq_supp_active_global`, or CAMPAIGN via `uq_supp_active_campaign`). soft → none unless policy escalates.
15. **Campaign-assignment effects:** hard → no resend within campaign; future contact only via full re-enrollment gate.
16. **Success output:** semantics applied + audit.
17. **Downstream workflow/event:** none (hard bounce is terminal for this campaign).
18. **Retry behavior:** RETRYABLE infra → bounded.
19. **Terminal-failure behavior:** missing/unresolvable bounce metadata → REVIEW/DLQ; no guessed lifecycle effect.
20. **DLQ behavior:** `dead_letter_events`; replay re-applies guarded semantics.
21. **Idempotency behavior:** event idempotency; duplicate bounce → DUPLICATE_EVENT, no repeated transition/suppression.
22. **Replay behavior:** transition guarded by from_status; suppression activation guarded by identity uniques.
23. **Race-condition considerations:** bounce crossing unsubscribe → unsubscribe (terminal-ish safety) governs; duplicate bounce events idempotent.
24. **Audit requirements:** lifecycle_events + suppression evidence per policy; processed_at.
25. **Metrics/observability:** bounce counts by type; policy escalations; suppressed-from-bounce count.
26. **OPEN dependencies:** hard_bounce suppression scope (policy OPEN); `bounce_pause_threshold` (NULL); soft-bounce escalation policy (OPEN).
27. **Traceability:** Arch §19, §20, §29#6; Doc 6 §19; Lifecycle §11; Schema §5.11, §5.9, §4.

### §4.10 WF-10 — Unsubscribe Processing

1. **Workflow ID:** WF-10
2. **Name:** Unsubscribe Processing
3. **Purpose:** Apply exact approved explicit-unsubscribe semantics.
4. **Trigger:** WF-07-routed UNSUBSCRIBE event (or WF-08 reply classified explicit_unsubscribe).
5. **Preconditions:** event row; lead/email resolved.
6. **Input contract:** event_id, lead_id, campaign_id.
7. **Canonical identity resolution:** suppression keyed by canonical `email` (identity contract).
8. **Database reads:** `email_events`; `leads`; `suppression_list` (existing active suppression for identity).
9. **Decision/gates:** stop sequence → UNSUBSCRIBED → GLOBAL suppression. If an active GLOBAL suppression already exists for the email → idempotent: no duplicate row (unique index would reject), events still recorded.
10. **External calls:** Warmbly sequence stop (execution-only; idempotent re-propagation harmless).
11. **Database writes:** `suppression_list` INSERT/UPDATE (active GLOBAL, `explicit_unsubscribe`, `source_event_id`); `suppression_events` INSERT (ACTIVATED); `lifecycle_events` (IN_SEQUENCE → UNSUBSCRIBED); `email_events.processed_at`; `workflow_runs`.
12. **Lifecycle effects:** IN_SEQUENCE → UNSUBSCRIBED (the ONLY event producing UNSUBSCRIBED).
13. **Verification effects:** None.
14. **Suppression effects:** GLOBAL, reason `explicit_unsubscribe`, **NO automatic expiry**; removal/reactivation only via explicitly authorized audited DEACTIVATED event (runtime DELETE revoked).
15. **Campaign-assignment effects:** active sequence stopped; assignment exit per lifecycle semantics.
16. **Success output:** suppression active + lifecycle UNSUBSCRIBED + full audit.
17. **Downstream workflow/event:** none.
18. **Retry behavior:** RETRYABLE → bounded.
19. **Terminal-failure behavior:** unresolvable lead/email from event → REVIEW/DLQ (suppression still activatable keyed by email where lead unresolved — identity contract).
20. **DLQ behavior:** `dead_letter_events`; replay re-applies (idempotent).
21. **Idempotency behavior:** event idempotency + `uq_supp_active_global`; duplicate unsubscribe → DUPLICATE_EVENT.
22. **Replay behavior:** safe; suppression propagation idempotent.
23. **Race-condition considerations:** unsubscribe during enrollment → immediate stop; wins over in-flight sending; complaint vs unsubscribe never conflated (WF-11).
24. **Audit requirements:** suppression_list + suppression_events + lifecycle_events + processed_at.
25. **Metrics/observability:** unsubscribe count; duplicate count; propagation status.
26. **OPEN dependencies:** Warmbly stop endpoint (TO VERIFY).
27. **Traceability:** Arch §15, §16; Doc 6 §16; Lifecycle §5, §12; Schema §5.9, §5.10, §5.18; API §12.

### §4.11 WF-11 — Spam Complaint Processing

1. **Workflow ID:** WF-11
2. **Name:** Spam Complaint Processing
3. **Purpose:** Apply exact approved spam-complaint semantics — suppression WITHOUT lifecycle rewrite.
4. **Trigger:** WF-07-routed SPAM_COMPLAINT event (`email_events.event_type='SPAM_COMPLAINT'` — not a reply classification).
5. **Preconditions:** event row; lead/email resolved.
6. **Input contract:** event_id, lead_id, campaign_id.
7. **Canonical identity resolution:** suppression keyed by canonical `email`.
8. **Database reads:** `email_events`; `suppression_list`; `leads`.
9. **Decision/gates:** stop sequence → GLOBAL suppression (`spam_complaint`) → **lifecycle PRESERVED (remains IN_SEQUENCE; MUST NOT become UNSUBSCRIBED)**. Preservation is NOT a transition — **no `lifecycle_events` row is appended for preservation by itself** (Doc 6 §17 #6).
10. **External calls:** Warmbly stop (execution-only).
11. **Database writes:** `suppression_list` + `suppression_events` (ACTIVATED, GLOBAL, `spam_complaint`); `email_events.processed_at`; `workflow_runs`. **No lifecycle_events row.**
12. **Lifecycle effects:** **None.** No transition; lifecycle history preserved untouched (Arch §16).
13. **Verification effects:** None.
14. **Suppression effects:** GLOBAL `spam_complaint`; NO automatic expiry; audited deactivation only.
15. **Campaign-assignment effects:** active sequence stopped; no lifecycle exit row (suppression dimension handles blocking).
16. **Success output:** suppression active + evidence persisted.
17. **Downstream workflow/event:** none.
18. **Retry behavior:** RETRYABLE → bounded.
19. **Terminal-failure behavior:** unresolvable identity → REVIEW/DLQ; suppression by email still possible.
20. **DLQ behavior:** `dead_letter_events`; replay idempotent.
21. **Idempotency behavior:** event idempotency + `uq_supp_active_global`; duplicate complaint → DUPLICATE_EVENT.
22. **Replay behavior:** safe.
23. **Race-condition considerations:** complaint arriving before delayed sent/delivery event → suppression activates immediately; the later delivery event is evidence only, does NOT resurrect sending and does NOT change lifecycle (Doc 6 §29 B; API §12).
24. **Audit requirements:** suppression_list + suppression_events + processed_at. (Absence of a lifecycle_events row is itself the approved behavior — reviewers must not "fix" this.)
25. **Metrics/observability:** complaint count; duplicates; stop propagation status.
26. **OPEN dependencies:** Warmbly stop endpoint (TO VERIFY); DB-D8 (coexistence/precedence) carried OPEN.
27. **Traceability:** Arch §9, §15, §16; Doc 6 §17, §29B; Lifecycle §5, §11, §12; Schema §5.9, §5.10; API §12.

### §4.12 WF-12 — Sequence Completion

1. **Workflow ID:** WF-12
2. **Name:** Sequence Completion
3. **Purpose:** Record sequence exhaustion (no reply) as lifecycle-terminal COMPLETED.
4. **Trigger:** WF-07-routed sequence-completion event.
5. **Preconditions:** event row; lead resolved; lead IN_SEQUENCE.
6. **Input contract:** event_id, lead_id, campaign_id, sequence reference.
7. **Canonical identity resolution:** resolved at ingestion.
8. **Database reads:** `email_events`; `leads`; `campaign_assignments`.
9. **Decision/gates:** completed → COMPLETED. **COMPLETED is NOT suppression.** **WF-12 triggers NO re-enrollment.** No direct/unconditional COMPLETED → IN_SEQUENCE transition exists.
10. **External calls:** None.
11. **Database writes:** `lifecycle_events` (IN_SEQUENCE → COMPLETED); `campaign_assignments` exit record (`active=FALSE`, `exited_at`, `exit_reason='COMPLETED'` — derived per Schema §8 re-enrollment model; API §12 assigns exit handling to this spec); `email_events.processed_at`; `workflow_runs`.
12. **Lifecycle effects:** IN_SEQUENCE → COMPLETED (lifecycle-terminal).
13. **Verification effects:** None.
14. **Suppression effects:** None.
15. **Campaign-assignment effects:** assignment deactivated with exit evidence; historical row preserved (never deleted).
16. **Success output:** COMPLETED + assignment exit recorded.
17. **Downstream workflow/event:** **None automatic.** Future re-enrollment only via explicit approved trigger → WF-05 full gate (suppression → cooldown (OPEN) → verification existence → freshness → reverification if stale → verification policy → campaign eligibility → conflict → enrollment gate — Doc 6 §21; no bypass from previous participation).
18. **Retry behavior:** RETRYABLE → bounded.
19. **Terminal-failure behavior:** unresolved event → REVIEW/DLQ.
20. **DLQ behavior:** `dead_letter_events`; replay guarded.
21. **Idempotency behavior:** event idempotency; duplicate completion → DUPLICATE_EVENT.
22. **Replay behavior:** from_status guard; exit record idempotent (already-inactive → no-op).
23. **Race-condition considerations:** completion crossing reply → reply classification governs (reply processing may occur after completion event; classification drives the transition — completion event then evidence-only); completion during suppression activation → suppression wins.
24. **Audit requirements:** lifecycle_events + assignment exit evidence + processed_at.
25. **Metrics/observability:** completions; duplicates; assignment exits.
26. **OPEN dependencies:** none beyond carried globals.
27. **Traceability:** Arch §9; Doc 6 §20, §21; API §12; Lifecycle §5, §14, §20; Schema §5.4, §5.8, §8.

### §4.13 WF-13 — PARKED / C-Fit Revisit

1. **Workflow ID:** WF-13
2. **Name:** PARKED/C-Fit Revisit
3. **Purpose:** Scheduled re-evaluation trigger for due PARKED (C_FIT) leads; no direct lifecycle mutation.
4. **Trigger:** Scheduled (cron). Cadence `c_fit_revisit_days` — **NULL → workflow runs no-op + config-missing audit/alert (fail-closed)**.
5. **Preconditions:** `c_fit_revisit_days` resolvable (non-NULL).
6. **Input contract:** none external; internal query window.
7. **Canonical identity resolution:** operates on already-resolved leads.
8. **Database reads:** `policy_config` (`c_fit_revisit_days`); `leads` via `idx_leads_parked`; `lifecycle_events` (latest PARKED transition timestamp — due-determination basis; **no approved `parked_at` column exists** — deriving due-ness from lifecycle_events history is the schema-supported basis; any alternative is an implementation decision, not schema semantics).
9. **Decision/gates:** due leads (PARKED + C_FIT + revisit elapsed) → re-trigger qualification (WF-02) with fresh verdict; non-due → skip.
10. **External calls:** None.
11. **Database writes:** `workflow_runs` only (+ config-missing audit note). No direct `leads`/`lifecycle_events` writes.
12. **Lifecycle effects:** **None directly.** Any transition results exclusively from WF-02's fresh qualification verdict through approved transitions.
13. **Verification effects:** None.
14. **Suppression effects:** None.
15. **Campaign-assignment effects:** None.
16. **Success output:** due-lead set handed to WF-02 (or empty batch).
17. **Downstream workflow/event:** WF-02.
18. **Retry behavior:** infra failure → next scheduled run; missing config → persistent no-op + alert until fixed via audited change.
19. **Terminal-failure behavior:** N/A (scheduled observer).
20. **DLQ behavior:** N/A; batch failures logged in `workflow_runs`.
21. **Idempotency behavior:** per-lead revisit — re-triggering WF-02 for an already-re-evaluated lead is safe (WF-02 idempotent); no duplicate revisit within the configured window.
22. **Replay behavior:** safe — recomputes due set from canonical state.
23. **Race-condition considerations:** lead exits PARKED between query and trigger → WF-02 transition guards handle; batch size/cost bounded.
24. **Audit requirements:** `workflow_runs` per run; config-missing condition alerted and audited.
25. **Metrics/observability:** parked population; due count; config-missing state.
26. **OPEN dependencies:** `c_fit_revisit_days` (NULL); due-determination basis (implementation decision — lifecycle_events-derived basis documented).
27. **Traceability:** Arch §8, §21; Lifecycle §6; Schema §5.14, §5.4 (`idx_leads_parked`), §5.13.

### §4.14 WF-14 — DLQ Processing & Replay

1. **Workflow ID:** WF-14
2. **Name:** DLQ Processing & Replay
3. **Purpose:** Inspect, classify and controlled-replay dead-lettered items; replay never bypasses current safety state.
4. **Trigger:** Scheduled (primary) + manual invocation.
5. **Preconditions:** `dead_letter_events` rows with status OPEN.
6. **Input contract:** DLQ item (`workflow`, `payload_ref`, `error`, `attempt_count`).
7. **Canonical identity resolution:** item correlates to lead where `lead_id` recorded; replayed operation re-resolves identity — never reuses stale resolution.
8. **Database reads:** `dead_letter_events`; target workflow's precondition sources (per replayed contract).
9. **Decision/gates:** classification (retryable-now / needs-fix / discard); replay decision requires the replayed item's own full safety re-checks — suppression (canonical email), verification freshness, config availability, eligibility — before any effect that could send/enroll; replay of a suppressed/unsafe item → RESOLVED/DISCARDED without effect.
10. **External calls:** whatever the replayed original contract calls (e.g., provider verification, Warmbly sync — all subject to the same re-checks).
11. **Database writes:** `dead_letter_events` (`status` → REPLAYED/RESOLVED/DISCARDED; `attempt_count` increment; `last_attempt_at`); `workflow_runs`; effects of the replayed operation via its own contract.
12. **Lifecycle effects:** None directly — replayed operations route through their proper processors; WF-14 never mutates lifecycle itself.
13. **Verification effects:** per replayed contract (e.g., WF-04 replay).
14. **Suppression effects:** only via replayed processor contracts (activation-direction only).
15. **Campaign-assignment effects:** per replayed contract (e.g., WF-06 replay with full rechecks).
16. **Success output:** classified/replayed DLQ items + audit.
17. **Downstream workflow/event:** the replayed item's native processor.
18. **Retry behavior:** bounded per item; `attempt_count` enforced.
19. **Terminal-failure behavior:** repeated replay failure → remains OPEN + alert; human review.
20. **DLQ behavior:** this IS the DLQ processor; no DLQ-of-DLQ.
21. **Idempotency behavior:** replay re-executes with same correlation id; target idempotency (API §15) prevents double effects.
22. **Replay behavior:** full safety re-evaluation each replay; never bypasses current suppression/freshness/config state.
23. **Race-condition considerations:** replay racing live events → latest canonical SAFETY state wins; replayed event older than a newer terminal event → newer state governs.
24. **Audit requirements:** every replay attempt audited; replay decisions recorded.
25. **Metrics/observability:** DLQ depth by workflow; replay outcomes; aging.
26. **OPEN dependencies:** DLQ alert threshold/window (config, NULL); replay tooling (n8n implementation decision).
27. **Traceability:** Arch §22; API §14, §15; Lifecycle §17; Schema §5.17, §4 dlq_status_enum; Doc 6 §23, §27.

### §4.15 WF-15 — Scheduled Reconciliation

1. **Workflow ID:** WF-15
2. **Name:** Scheduled Reconciliation
3. **Purpose:** Repair denormalized caches toward canonical state; detect external-state drift; schema-mandated config integrity verification.
4. **Trigger:** Scheduled; cadence OPEN (not fixed by approved docs).
5. **Preconditions:** DB available.
6. **Input contract:** none external.
7. **Canonical identity resolution:** repairs bind to canonical lead_id/email.
8. **Database reads:** `leads` caches vs `verification_results` (latest by `checked_at`) and `suppression_list` (canonical email); `policy_config` non-GLOBAL rows; `workflow_runs`; `campaign_assignments` vs Warmbly state (TO VERIFY).
9. **Decision/gates:** (a) cache disagreement → **canonical wins; cache repaired toward canonical in the same transaction as its evidence basis; disagreement always treated as BLOCKING for sending until repaired (never permitting)** (Schema §5.9/§7 contracts); (b) `policy_config` scope_id integrity — **schema-MANDATED**: every non-NULL `scope_id` must reference an existing row in the table matching `scope_type` (Schema §5.14 known polymorphic-FK limitation); row-uniqueness per `uq_config_global`/`uq_config_scoped` verified; violations → report + alert; (c) Warmbly enrollment-state comparison — **BLOCKED/TO VERIFY until Warmbly query capability is verified; no endpoint invented**.
10. **External calls:** Warmbly queries — TO VERIFY (implementation placeholder until verified).
11. **Database writes:** `leads` cache repairs (toward canonical); `workflow_runs`. No `lifecycle_events` rows for repairs (repairs are cache corrections, not transitions).
12. **Lifecycle effects:** None directly.
13. **Verification effects:** cache synchronized to canonical history — never the reverse.
14. **Suppression effects:** cache synchronized to canonical `suppression_list` — never the reverse; no suppression created/removed by reconciliation.
15. **Campaign-assignment effects:** none (report-only mismatches until Warmbly queries verified).
16. **Success output:** repaired caches + mismatch report.
17. **Downstream workflow/event:** WF-16 (alerts on persistent mismatch).
18. **Retry behavior:** next scheduled run on failure.
19. **Terminal-failure behavior:** persistent contradiction → alert (sample-size aware per WF-16).
20. **DLQ behavior:** N/A (no items; failures in `workflow_runs`).
21. **Idempotency behavior:** repair idempotent (canonical-derived values).
22. **Replay behavior:** safe — recomputes from canonical.
23. **Race-condition considerations:** repair racing a live workflow write → same-transaction contract of the writer governs; reconciliation never overrides a concurrent canonical write.
24. **Audit requirements:** repair log (`workflow_runs` + `error`/metadata), mismatch report.
25. **Metrics/observability:** drift counts per cache; config integrity violations; repaired rows.
26. **OPEN dependencies:** cadence (OPEN); Warmbly state-query endpoints (TO VERIFY); retention.
27. **Traceability:** Arch §5, §20; Schema §5.4, §5.9, §5.14, §7, §10; Doc 6 §23; API §18.

### §4.16 WF-16 — Health/Alert Evaluation

1. **Workflow ID:** WF-16
2. **Name:** Health/Alert Evaluation
3. **Purpose:** Evaluate alert conditions from computed operational metrics; no canonical writes.
4. **Trigger:** Scheduled.
5. **Preconditions:** DB available; alert-channel configuration where required (channel itself OPEN).
6. **Input contract:** none external.
7. **Canonical identity resolution:** N/A.
8. **Database reads:** `workflow_runs` (failure rates); `dead_letter_events` (OPEN count growth); `email_events` (metric basis); `sending_domains`/`mailboxes` (`health_status`); `policy_config` (thresholds, `minimum_sample_size`, windows).
9. **Decision/gates:** metric + window + minimum sample + threshold + action model. **NULL config → condition not evaluable → no alert fired + config-missing audit (fail-closed, including against false alarms).** Webhook-silence rule (Arch §20 corrected): alert ONLY when expected sending/event activity exists without expected webhook data; no campaign activity + no events ≠ incident. Context-aware escalation; no blind cascade (Schema §13).
10. **External calls:** alert delivery — channel OPEN (Arch §28 #10); placeholder until approved.
11. **Database writes:** None canonical (computations from `workflow_runs`/`email_events`/DLQ counts; `workflow_runs` for own executions).
12. **Lifecycle effects:** None.
13. **Verification effects:** None.
14. **Suppression effects:** None.
15. **Campaign-assignment effects:** None.
16. **Success output:** evaluation report + (where configured) alerts.
17. **Downstream workflow/event:** alert channel (OPEN).
18. **Retry behavior:** next scheduled run.
19. **Terminal-failure behavior:** N/A.
20. **DLQ behavior:** N/A.
21. **Idempotency behavior:** evaluation idempotent; alert dedup/windowing (implementation decision).
22. **Replay behavior:** safe — recomputed.
23. **Race-condition considerations:** metrics read snapshot; health escalations are context-aware, never automatic lifecycle mutation.
24. **Audit requirements:** evaluation runs in `workflow_runs`; alert history outside canonical DB (implementation).
25. **Metrics/observability:** self-evaluating; DLQ depth; provider failure rates; webhook-silence indicators; config-missing count.
26. **OPEN dependencies:** alert channel (Arch §28 #10); `minimum_sample_size`, thresholds, windows (NULL); retention.
27. **Traceability:** Arch §19, §20, §23; Schema §5.16, §5.17, §13, §5.1/§5.2; Doc 6 §23; API §18.

---

## §5 Consolidated Fail-Closed Matrix (full expansion of master spec §5.5)

| Case | Send/Enroll? | Immediate action | Retry/Review | Lifecycle mutation? | Always permitted |
|---|---|---|---|---|---|
| DB unavailable | NO | Halt gate | Bounded → DLQ | NO | workflow_runs attempt (where writable), alert |
| Suppression lookup unavailable/ambiguous | NO | Canonical wins; cache repair; block until consistent | Reconcile → retry | NO | cache repair (toward canonical), alert |
| Verification missing | NO | Reverify required | Reverify (WF-04) | NO | gate-rejection audit |
| Verification stale | NO | Reverify FIRST | WF-04 fresh op | Approved only: VERIFIED → VERIFICATION_PENDING | new history row |
| Verification provider unavailable | NO | Backoff; MV fallback per policy | Retry → fallback → DLQ | NO (HOLDS at VERIFICATION_PENDING) | workflow_runs, DLQ |
| Provider auth failure | NO | Stop retrying; fix out-of-band | NON_RETRYABLE → DLQ | NO | dead_letter_events, alert |
| Normalization failure | NO | VALIDATION_FAILURE — no canonical write | NON_RETRYABLE → DLQ | NO | DLQ evidence |
| Config NULL (`catch_all_policy`, `verification_valid_for_days`, caps, windows, sample size) | NO | Fail-closed block | Fix via audited config change | NO | alert + config-missing audit |
| Campaign conflict unresolved at runtime | NO | BLOCK | Human/explicit-permission path (OPEN) | NO | review record |
| Personalization missing/unknown key | NO | Reject Warmbly sync | Fix/approve data | NO (stays CAMPAIGN_READY) | rejection log + alert |
| Warmbly enrollment uncertain | NO | Never treat as enrolled | Retry sync → DLQ | NO (no IN_SEQUENCE unconfirmed) | workflow_runs, alert |
| Webhook unauthenticated | NO (n/a) | Reject | n/a | NO | reject log |
| Webhook unmappable | NO (n/a) | DLQ route | mapping fix → replay | NO | DLQ evidence |
| Identity ambiguous | NO | Manual review (no auto-merge) | REVIEW | NO | review record |

**Standing rule:** infrastructure failure must not create unjustified business/lifecycle state; safety uncertainty must never become send authorization (Doc 6 §23; Arch §29).

## §6 Workflow×Table Summary (detail in `n8n-database-mapping.md`)

Writes: WF-01 leads+lifecycle_events · WF-02 leads+lifecycle_events · WF-03 lead_enrichment+leads+lifecycle_events · WF-04 verification_results+leads+lifecycle_events · WF-05 leads+lifecycle_events · WF-06 campaign_assignments+lifecycle_events · WF-07 email_events · WF-08 replies+lifecycle_events(+suppression\*) · WF-09 lifecycle_events(+suppression\*) · WF-10 suppression_list+suppression_events+lifecycle_events · WF-11 suppression_list+suppression_events · WF-12 lifecycle_events+campaign_assignments · WF-13 — · WF-14 dead_letter_events · WF-15 leads(cache) · WF-16 —. (\*suppression writes only via explicit_unsubscribe classification / hard-bounce policy respectively.) Every workflow: `workflow_runs`.

## §7 OPEN Dependencies Register (per workflow)

- **All workflows:** 13 `policy_config` keys NULL (fail-closed); Arch §28 open decisions; DB-D1..D8 carried (esp. DB-D4 idempotency composition — WF-06/07; DB-D7 email mutation — WF-01/04; DB-D8 suppression coexistence — WF-05/11).
- **Provider/API TO VERIFY:** Warmbly endpoints/auth/webhook names/event IDs/ordering (WF-06, WF-07, WF-08, WF-09, WF-10, WF-11, WF-15); Apollo facts where API §7 marks them (WF-03).
- **n8n implementation decisions (not architecture):** in-flight verification guard (WF-04); endpoint auth mechanism (WF-07); alert-channel integration + dedup (WF-16); replay tooling (WF-14); WF-13 due-determination basis; queue mode/concurrency/retry orchestration settings.

## §8 Validation Checklist (executed — results in delivery report)

1. 27 fields present in all 16 contracts · 2. IDs/names match master spec v1.1 catalog exactly · 3. All table/column/constraint names verified against Schema v1.2 §4–§5 · 4. Lifecycle transitions ⊆ approved 14-state enum and approved transition table · 5. Exactly 8 canonical verification statuses · 6. Suppression reasons ⊆ 7-value enum · 7. No invented DB objects/states/policies · 8. DB-D4/D7/D8, Arch §28 items, NULL configs remain OPEN · 9. No CRM states · 10. No secrets.

## §9 Change Log

- v1.0 (2026-10-17): initial contracts draft derived from approved Architecture v1.3, Database Schema v1.2, Lifecycle v1.0, API Integration Spec v1.0, Verification & Suppression Rules v1.0, and master workflow specification v1.1. Status: Draft v1.0 — Pending Review. NOT approved.
- v1.1 (2026-10-17): explicit `companies` INSERT/UPDATE responsibilities added to WF-01 (company dedupe at intake) and WF-03 (enrichment-driven profile fields), per Schema §5.3. Status: Draft v1.1 — Pending Review. NOT approved.
