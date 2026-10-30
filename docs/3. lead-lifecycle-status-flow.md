# SKMC Cold Email Automation
## Lead Lifecycle & Status Flow

### Document Control

| Field | Value |
|---|---|
| Document | SKMC Cold Email Automation — Lead Lifecycle & Status Flow |
| Version | 1.0 |
| Date | 2026-10-13 |
| Status | Approved — Lead lifecycle implementation specification of Architecture v1.3 |
| Governing Architecture | `/opt/data/skmc-cold-email/docs/architecture.md` — Version 1.3 — Approved — Single Source of Truth |
| Database Reference | `/opt/data/skmc-cold-email/docs/database-schema.md` — Version 1.2 — Approved — Database implementation of Architecture v1.3 |
| Purpose | Implementation-ready specification of lead lifecycle state semantics, transitions, gates, and interactions with verification, suppression, campaign assignment, and workflow processing |
| Last Updated | 2026-10-13 |

Not authoritative for this document: implementation-plan-v1.3.md, chat history, prior drafts, or assumptions inherited from earlier discussions. Where this document derives behavior beyond the approved documents, it is labeled **DERIVED** and marked for review.

---

## 1. Purpose and Scope

This document specifies HOW a lead moves through the SKMC Cold Email Automation system: state meanings, entry conditions, writers, consumers, allowed/forbidden transitions, failure handling, and the interaction of lifecycle with verification, suppression, campaign assignment, and workflow processing.

It is an implementation specification derived FROM the approved Architecture v1.3 and the approved Database Schema v1.2. It does not define new architecture, does not alter database structures, and does not resolve Architecture Open Decisions.

**This document does NOT control:**
- n8n node-level workflow design (future n8n Workflow Specification);
- API payloads/field mappings (future API Integration Specification);
- ICP/qualification scoring formulas (Campaign & ICP Specification);
- database structures (Database Schema v1.2 — referenced, not redefined);
- schedules/infrastructure (implementation plan).

**Five distinct dimensions must never be collapsed:**

| Dimension | Meaning | Canonical Store | NOT the same as |
|---|---|---|---|
| **Lead Lifecycle State** | Where the lead is in the cold-email process | `leads.lifecycle_status` (14-state enum) | Not workflow state, not suppression, not verification |
| **Workflow Processing State** | How a workflow run is progressing (retry/review/DLQ) | `workflow_runs.status`, `dead_letter_events` | Holding states for PROCESSING, not for the lead |
| **Suppression State** | Whether contact is prohibited, and at what scope | `suppression_list` (+ `leads.suppression_status` cache) | SUPPRESSED is NOT a lifecycle state |
| **Verification State** | Current effective email verification verdict | `verification_results` history (canonical, latest by `checked_at`) + `leads.verification_status` cache | Verification verdict ≠ aggregate bounce rate |
| **Campaign/Assignment State** | Active/exited campaign participation | `campaign_assignments` (+ `campaigns`) | Re-enrollment permitted via history, not deletion |

A lead is in **exactly one lifecycle state** at any time, while simultaneously carrying verification, suppression, and assignment dimensions.

---

## 2. Governing Principles

Extracted from Architecture v1.3 (§2 Principles, §29 Invariants). Each is an APPROVED ARCHITECTURE RULE.

| # | Principle | Architecture Source |
|---|---|---|
| P1 | PostgreSQL is the canonical source of operational lead state and history | §2 #1, §29 #1 |
| P2 | n8n owns orchestration and all policy gates; it does not qualify leads or send | §2 #3 |
| P3 | Lifecycle, verification, and suppression are three separate dimensions, never collapsed | §9, §16, §29 #19 |
| P4 | SUPPRESSED is a suppression state, not a lifecycle state | §16, §29 #19 |
| P5 | RETRY and REVIEW are workflow-processing states, not lifecycle states | §9 closing note |
| P6 | CRM/sales stages (MEETING_BOOKED, CLOSED_WON, CLOSED_LOST) are not cold-email lifecycle states; positive reply hands off downstream | §29 #21 |
| P7 | Ordinary negative reply is not automatic global suppression | §15, §16, §29 #17 |
| P8 | Suppressed contacts cannot bypass suppression through re-enrollment (pre-re-enrollment check is structural) | §15 #3, §29 #7 |
| P9 | Stale verification cannot bypass the freshness gate | §11, §29 #18 |
| P10 | Verification verdict ≠ aggregate observed bounce rate; no invented per-lead bounce-risk score | §10, §29 #6, #16 |
| P11 | Campaign conflict enforcement is contact-level, not company-level | §13, §29 #9 |
| P12 | `company_domain` is never a person identity key or campaign concurrency gate | §6, §29 #8 |
| P13 | Contacts may exist before email resolution | §6 |
| P14 | External identifiers are scoped to their source/provider | §6, §29 #22 |
| P15 | Historical lifecycle/suppression/verification/config records remain append-only and auditable | §2 #14, §29 #12 |
| P16 | Operating values are configurable policy, not architecture law | §2 #11, §21, §29 #13 |
| P17 | Failures must not silently disappear (workflow runs + DLQ) | §22, §29 #14 |
| P18 | Required personalization fails closed if missing/unapproved | §14, §29 #11 |
| P19 | PARKED ≠ SUPPRESSED (parked = not yet worth spend; suppressed = do not contact) | §8, §16 |
| P20 | Warmbly owns execution only; PostgreSQL remains canonical | §3, §17 |
| P21 | All transitions are logged with timestamps (append-only history) | §9 |

---

## 3. Lifecycle State Model

The EXACT 14 approved lifecycle states (Architecture §9; `lifecycle_status_enum` in Database Schema §4):

| State | Meaning | Entry Condition | Primary Writer | Primary Consumer | Normal Next State(s) |
|---|---|---|---|---|---|
| `DISCOVERED` | Contact discovered by OpenOutreach; raw record intake not yet processed | OpenOutreach discovery output accepted by n8n intake | n8n intake | n8n qualification processing | QUALIFIED, PARKED |
| `QUALIFIED` | OpenOutreach qualification verdict = A-Fit or B-Fit; passed intake/dedupe | Qualification verdict A/B-Fit | n8n (qualification processing) | Enrichment/verification orchestration | ENRICHMENT_PENDING, VERIFICATION_PENDING |
| `ENRICHMENT_PENDING` | Campaign-required fields missing; optional enrichment (Apollo) authorized | Eligibility requires fields not already present | n8n | Apollo enrichment call (optional) | ENRICHED |
| `ENRICHED` | Enrichment completed or determined unnecessary; required fields available | Enrichment done / not needed | n8n | Verification orchestration | VERIFICATION_PENDING |
| `VERIFICATION_PENDING` | Verification started or awaiting an acceptable verdict | Verification initiated; or reverification after stale result; or UNKNOWN/TEMPORARY_FAILURE retry | n8n | Verification provider call; freshness gate | VERIFIED, or remains (retry), or suppression overlay |
| `VERIFIED` | Current acceptable verification verdict within freshness window | Verdict VALID (or policy-acceptable) and gate-ready | n8n | Eligibility gate | CAMPAIGN_READY |
| `CAMPAIGN_READY` | ALL eligibility-gate checks passed (§11 eight checks) | Full eligibility gate PASS | n8n eligibility gate | Warmbly sync | IN_SEQUENCE |
| `IN_SEQUENCE` | Actively enrolled in a Warmbly campaign sequence | Warmbly enrollment confirmed | n8n (on Warmbly confirmation) | Warmbly execution | REPLIED_POSITIVE, REPLIED_NEGATIVE, UNSUBSCRIBED, BOUNCED, COMPLETED |
| `REPLIED_POSITIVE` | Positive reply received; handed off to downstream sales process | Positive reply classification | n8n (reply handling) | Downstream human/CRM sales process (outside this system's lifecycle) | Terminal for cold-email lifecycle |
| `REPLIED_NEGATIVE` | Negative reply received; sequence stop/exit per reply policy | Negative reply classification | n8n (reply handling) | Reply-policy evaluation (cooldown OPEN) | Holds; re-enrollment only via full gate |
| `UNSUBSCRIBED` | Explicit unsubscribe / do-not-contact received | Explicit unsubscribe event | n8n (event handling) | Suppression overlay (GLOBAL suppression activated) | Terminal for lifecycle; suppression dimension governs |
| `BOUNCED` | Hard bounce event received | Bounce event (hard) | n8n (event handling) | Bounce-suppression policy (configured) | Holds; suppression per policy |
| `COMPLETED` | Sequence exhausted with no reply | Sequence-completed signal from Warmbly | n8n (webhook processing) | Future re-enrollment evaluation | Holds; re-enrollable via full gate |
| `PARKED` | C-Fit: deferred — no enrichment/verification/enrollment spend | Qualification verdict C-Fit | n8n (qualification processing) | Revisit scheduler (configurable period — OPEN) | QUALIFIED (on revisit + fresh trigger), or remains PARKED |

**Explicitly NOT lifecycle states:**
- `RETRY`, `REVIEW` — workflow-processing states (§13);
- `SUPPRESSED` — suppression-dimension state (§12);
- `MEETING_BOOKED`, `CLOSED_WON`, `CLOSED_LOST` — downstream CRM sales stages (§29 #21).

**Rejected leads:** a qualification verdict of REJECT means the lead does not proceed through paid processing. It is retained per retention policy (retention itself is an Open Decision, Architecture §28 #2). Its lifecycle state remains `DISCOVERED` with `qualification_fit = 'REJECT'`; the fit verdict is the gate, not a lifecycle state. *(DERIVED: Architecture §9 does not assign a distinct lifecycle state to rejection; the transition table says "no paid processing; retained per retention policy".)*

---

## 4. End-to-End Lifecycle Flow

```mermaid
stateDiagram-v2
    "[*]" --> DISCOVERED: OpenOutreach discovery intake
    DISCOVERED --> QUALIFIED: qualification verdict A-Fit or B-Fit
    DISCOVERED --> PARKED: qualification verdict C-Fit
    DISCOVERED --> DISCOVERED: qualification verdict REJECT (no paid processing; retained per retention policy)
    PARKED --> QUALIFIED: revisit due AND fresh trigger -> new qualification verdict A/B-Fit
    PARKED --> PARKED: revisit due but verdict still C-Fit / no new trigger
    QUALIFIED --> ENRICHMENT_PENDING: campaign-required fields missing
    QUALIFIED --> VERIFICATION_PENDING: no enrichment needed
    ENRICHMENT_PENDING --> ENRICHED: enrichment done or not needed
    ENRICHED --> VERIFICATION_PENDING: verification started
    VERIFICATION_PENDING --> VERIFIED: verdict acceptable and gate-ready
    VERIFICATION_PENDING --> VERIFICATION_PENDING: UNKNOWN / TEMPORARY_FAILURE (bounded retry)
    VERIFIED --> CAMPAIGN_READY: full eligibility gate passes
    CAMPAIGN_READY --> IN_SEQUENCE: Warmbly enrollment confirmed
    IN_SEQUENCE --> REPLIED_POSITIVE: positive reply
    IN_SEQUENCE --> REPLIED_NEGATIVE: negative reply
    IN_SEQUENCE --> UNSUBSCRIBED: explicit unsubscribe
    IN_SEQUENCE --> BOUNCED: hard bounce
    IN_SEQUENCE --> COMPLETED: sequence exhausted, no reply
    COMPLETED --> COMPLETED: holds - re-enrollable only via full gate
    COMPLETED --> VERIFICATION_PENDING: re-enrollment gate - stale verification -> reverify [DERIVED, per Arch §11]
    COMPLETED --> VERIFIED: re-enrollment gate - fresh verification [DERIVED, per Arch §11]
    REPLIED_NEGATIVE --> VERIFICATION_PENDING: re-enrollment gate - stale verification -> reverify [DERIVED, per Arch §11]
    REPLIED_NEGATIVE --> VERIFIED: re-enrollment gate - fresh verification [DERIVED, per Arch §11]
    REPLIED_POSITIVE --> "[*]": hand off to downstream sales process
```

Re-entry note: COMPLETED / REPLIED_NEGATIVE may enter re-enrollment ONLY through the FULL re-enrollment gate (§14) — suppression, freshness, eligibility, concurrency, cooldown (OPEN), identity, config. Gate failure = no re-entry; re-entry is never unconditional. Freshness period and cooldown values remain OPEN/configurable.

**Annotations (separate dimensions — NOT lifecycle states in the diagram):**
- **Suppression overlay** (§12): a suppression event may activate the suppression dimension from ANY active state; lifecycle history is preserved, lifecycle state is NOT rewritten to a suppression value.
- **Workflow processing** (§13): RETRY/REVIEW apply to workflow RUNS; a lead in VERIFICATION_PENDING with a failing provider call is in a processing-retry situation while its lifecycle state remains VERIFICATION_PENDING.
- **Re-enrollment** (§14): COMPLETED / REPLIED_NEGATIVE / policy-permitted states re-enter the eligibility path via VERIFICATION_PENDING (stale verification) or VERIFIED (fresh) → CAMPAIGN_READY → IN_SEQUENCE, only through the full gate.

---

## 5. Transition Specification

Classification: **[D]** deterministic (event → transition, no discretion) · **[P]** policy-controlled (mechanism fixed, value/configurable policy decides) · **[X]** exceptional (failure/edge handling).

| From State | Event / Condition | Guard / Required Data | To State | Writer | Side Effect | Failure Handling |
|---|---|---|---|---|---|---|
| DISCOVERED | OpenOutreach intake accepted [D] | Valid OpenOutreach output contract fields (§7 contract); dedupe resolution per priority hierarchy (§6) | DISCOVERED (persisted) | n8n intake | lead row created; identity keys stored; source-scoped IDs | OpenOutreach output failure → workflow retry/DLQ (§13); ambiguous identity → manual review path, never auto-merge |
| DISCOVERED | Qualification verdict A-Fit [D] | qualification_fit = 'A_FIT'; reason + signals stored | QUALIFIED | n8n qualification processing | lifecycle_events row appended; signals + signals_schema_version persisted | Qualification output missing/invalid → retry/review |
| DISCOVERED | Qualification verdict B-Fit [D] | qualification_fit = 'B_FIT' | QUALIFIED | n8n qualification processing | lifecycle_events row appended | as above |
| DISCOVERED | Qualification verdict C-Fit [D] | qualification_fit = 'C_FIT' | PARKED | n8n qualification processing | lifecycle_events row appended; NO Apollo/verification/Warmbly spend | revisit scheduler tracks lead (configurable period — OPEN, Arch §28 #4) |
| DISCOVERED | Qualification verdict REJECT [D] | qualification_fit = 'REJECT' | DISCOVERED (no lifecycle move) — no paid processing | n8n qualification processing | retained per retention policy (retention OPEN, Arch §28 #2); audit trail preserved | n/a |
| PARKED | Revisit due + new trigger + fresh qualification verdict A/B-Fit [P] | Revisit period elapsed (value OPEN); new trigger evidence; FRESH qualification verdict (not stored reason) | QUALIFIED | n8n revisit/qualification | lifecycle_events row appended; requalification replaces stale signals | Revisit with verdict still C-Fit → remains PARKED |
| QUALIFIED | Campaign-required fields missing [D] | Required-fields comparison against campaign spec | ENRICHMENT_PENDING | n8n | lifecycle_events row appended | n/a |
| QUALIFIED | No enrichment required [D] | All required fields already present | VERIFICATION_PENDING | n8n | lifecycle_events row appended | n/a |
| ENRICHMENT_PENDING | Apollo enrichment completed [D] | Returned fields stored; double-buy guard evidence (`lead_enrichment.skipped` when Apollo not needed) | ENRICHED | n8n | lead_enrichment row; lifecycle_events row | Apollo API failure/credit exhaustion → bounded retry → review/DLQ; graceful degradation per architecture |
| ENRICHMENT_PENDING | Required data already available / double-buy guard skips Apollo [D] | Required fields present from OpenOutreach | ENRICHED | n8n | lead_enrichment row with `skipped=TRUE`; lifecycle_events row | n/a |
| ENRICHED | Verification initiated [D] | email resolved (email-less leads cannot reach verification — Architecture §11; DB §5.4 note) | VERIFICATION_PENDING | n8n | lifecycle_events row appended | Email-less lead attempting verification → workflow defect → DLQ + alert |
| VERIFICATION_PENDING | ZeroBounce verdict VALID [D] | verification_results row inserted (append-only); freshness computed at gate | VERIFIED | n8n verification processing | verification_results INSERT; leads.verification_status cache update (same transaction); lifecycle_events row | Provider failure → fallback policy (MillionVerifier) → retry policy |
| VERIFICATION_PENDING | Verdict INVALID / DISPOSABLE [D] | canonical verdict recorded | VERIFICATION_PENDING (lifecycle unchanged) + suppression dimension ACTIVATED (reason `invalid_email`) | n8n suppression enforcement | suppression_list INSERT (scope per configured policy — DB-D8 OPEN for coexistence/precedence); suppression_events ACTIVATED; leads.suppression_status cache sync (same transaction) | Must not be sent — fail-closed |
| VERIFICATION_PENDING | Verdict CATCH_ALL / RISKY [P] | verdict recorded; campaign verification policy consulted | VERIFICATION_PENDING (hold-for-review default) | n8n | verdict persisted; review path per campaign policy (policy value OPEN, Arch §28 #1) | Policy may later admit or hold; value is configurable |
| VERIFICATION_PENDING | Verdict UNKNOWN / TEMPORARY_FAILURE [P] | verdict recorded | VERIFICATION_PENDING (remains) | n8n | bounded retry per configured policy; fallback provider per policy | Exhausted retries → review/DLQ (§13); never silent |
| VERIFIED | Full eligibility gate passes [D] | All 8 gate checks (§11 Arch): fit, required fields, acceptable verification, freshness, not-suppressed, valid assignment, concurrency OK, approved personalization | CAMPAIGN_READY | n8n eligibility gate | lifecycle_events row appended | Any check fails → block (no transition); failures observable |
| VERIFIED | Freshness gate fails at (re-)enrollment evaluation [X][DERIVED, per Arch §11 freshness flow] | latest checked_at older than `verification_valid_for_days` (value OPEN) | VERIFICATION_PENDING (reverify) | n8n | NEW verification_results row on reverify (history never overwritten); consumes verification credit | Reverify provider failure → retry/fallback policy → review/DLQ; stale verification must NEVER be bypassed (Arch §29 #18) |
| CAMPAIGN_READY | Warmbly sync accepted / enrollment confirmed [D] | Approved signal keys validated fail-closed (Arch §14); Warmbly API success | IN_SEQUENCE | n8n | campaign_assignments row (active); lifecycle_events row | Warmbly sync failure → bounded retry → DLQ; signal-key validation failure → sync REJECTED + alert/review (fail-closed) |
| IN_SEQUENCE | Positive reply [D] | replies row classified 'positive' | REPLIED_POSITIVE | n8n reply handling | lifecycle_events row; reply record; sequence stop; downstream handoff/notify | n/a |
| IN_SEQUENCE | Negative reply [P] | replies row classified 'negative' | REPLIED_NEGATIVE | n8n reply handling | sequence stop/exit per reply policy; NO automatic global suppression (Arch §29 #17); cooldown value OPEN (§28 #5) | n/a |
| IN_SEQUENCE | Explicit unsubscribe [D] | reply/event classified 'explicit_unsubscribe' | UNSUBSCRIBED | n8n event handling | GLOBAL suppression ACTIVATED (reason `explicit_unsubscribe`); suppression_events row; cache sync | Global suppression has NO automatic expiry (Arch §15) |
| IN_SEQUENCE | Spam complaint [D] | complaint event | IN_SEQUENCE (lifecycle PRESERVED — no lifecycle rewrite; Arch §9/§16) + GLOBAL suppression ACTIVATED (reason `spam_complaint`) | n8n event handling | suppression_list + suppression_events; sequence/sending stopped; cache sync | n/a |
| IN_SEQUENCE | Hard bounce [P] | bounce event type=hard | BOUNCED | n8n event handling | suppression per approved bounce policy (reason `hard_bounce`; scope/policy configurable) | Soft bounce → per bounce policy; not lifecycle-terminal by itself |
| IN_SEQUENCE | Sequence exhausted, no reply [D] | Warmbly sequence-completed webhook | COMPLETED | n8n webhook processing | lifecycle_events row; assignment remains (exit handling per workflow spec) | n/a |
| Any active state | Suppression event (any approved trigger) [D] | approved trigger semantics (Arch §15) | lifecycle PRESERVED (no lifecycle rewrite); suppression dimension activated | n8n suppression enforcement | suppression_list + suppression_events (append-only) | n/a |
| COMPLETED / REPLIED_NEGATIVE / policy-permitted holds | Re-enrollment evaluation for future campaign [P][DERIVED entry, per Arch §11 freshness flow — re-entry gated per Arch §9/§11] | FULL re-enrollment gate (§14): suppression, freshness, eligibility, concurrency, cooldown (OPEN), history, identity, config | VERIFICATION_PENDING (if stale) or VERIFIED (if fresh) → CAMPAIGN_READY → IN_SEQUENCE | n8n eligibility gate | new campaign_assignments row (re-enrollment creates NEW row; exited rows never deleted) | Any gate failure → no re-enrollment; stale verification → reverify first (never silent bypass) |

**Forbidden transitions (never valid):**
- Any lifecycle state → SUPPRESSED (SUPPRESSED is not a lifecycle state; suppression is an overlay);
- Any lifecycle state → RETRY / REVIEW (workflow-processing states live in workflow_runs, not lifecycle);
- Any lifecycle state → MEETING_BOOKED / CLOSED_WON / CLOSED_LOST (CRM stages; positive reply hands off downstream);
- DISCOVERED → VERIFIED / CAMPAIGN_READY / IN_SEQUENCE (gates cannot be skipped);
- VERIFICATION_PENDING → CAMPAIGN_READY (eligibility gate requires VERIFIED first);
- Re-enrollment bypassing the suppression check or freshness gate;
- Silent auto-merge of ambiguous duplicate identities.

---

## 6. Lead Intake and Qualification

**Intake [APPROVED RULES]** — Architecture §6/§7:
- OpenOutreach delivers discovery + structured qualification output (identity, fit, reason, signals, optional email).
- Identity resolution priority: (1) `(source_system, external_lead_id)`; (2) normalized email; (3) `(source_system, external_person_id)`; (4) unresolved ambiguity → **manual/review path — never silent auto-merge** [P5 of workflow processing: REVIEW].
- Email is OPTIONAL at discovery — contacts may exist in DISCOVERED/QUALIFIED before email resolution (Architecture §6; DB `leads.email CITEXT NULL` + partial unique index among resolved emails).
- External IDs are source-scoped (DB partial unique indexes `uq_leads_source_lead`, `uq_leads_source_person`).
- `company_domain` is company-level enrichment-dedupe identity ONLY — never person identity, never a campaign gate (Arch §6, §13; DB §5.4 comment).
- Intake suppression check: suppression may exist BEFORE a lead exists (DB §5.9 identity contract) — intake must look up suppression by canonical email so a newly created lead cannot bypass existing suppression [APPROVED DB CONTRACT].

**Qualification [APPROVED]** — Architecture §7/§8:
- Fit verdicts: A-Fit, B-Fit, C-Fit, REJECT.
- Raw qualification `reason` = INTERNAL AUDIT ONLY — never outbound content (Arch §2 #12; DB `leads.reason` nullable for non-AI sources).
- Structured signals (`trigger_codes`, `signals`, `personalization_evidence`) stored with `signals_schema_version` contract (DB §5.4); only campaign-approved keys may later reach templates (§14 gate).
- **C-Fit → PARKED:** no Apollo spend, no verification spend, no Warmbly enrollment while parked. Revisit after a **configurable** C-Fit revisit period; requalification uses a FRESH qualification verdict, not the stored reason. Revisit period value = OPEN (Arch §28 #4). Do not hardcode any number of days.
- **REJECT:** no paid processing; retained per retention policy (retention = OPEN, Arch §28 #2).

---

## 7. Enrichment Flow

**Enrichment is OPTIONAL, not mandatory** (Architecture §4 — Apollo sits behind an explicit missing-fields decision; §2 #4 double-buy guard).

| Situation | Behavior |
|---|---|
| All campaign-required fields already present (OpenOutreach or prior data) | QUALIFIED → VERIFICATION_PENDING directly; Apollo NOT called |
| Required field(s) missing | QUALIFIED → ENRICHMENT_PENDING; Apollo invoked for the missing fields only |
| Apollo returns data | ENRICHMENT_PENDING → ENRICHED; returned fields stored; `lead_enrichment.returned_fields` records evidence |
| Double-buy guard fires (Apollo skips — data already available) | ENRICHMENT_PENDING → ENRICHED; `lead_enrichment.skipped = TRUE` (DB §5.5) |
| Partial enrichment (some fields returned) | Enriched with whatever was returned; eligibility gate later fails closed if a required field is still missing |
| Apollo API failure / credit exhaustion | Bounded retry per configured policy; exhausted → review/DLQ (Arch §22); lifecycle remains ENRICHMENT_PENDING during retry |
| Apollo credit alert threshold | Configurable alert (`apollo_credits_alert_pct` — registered key; value OPEN) |

Enrichment-provider state is NOT lead lifecycle. Apollo's internal job status lives in `lead_enrichment` rows; the lead's lifecycle dimension only records ENRICHMENT_PENDING → ENRICHED.

---

## 8. Verification Flow

**Providers [APPROVED]:** ZeroBounce primary; MillionVerifier fallback ONLY per configured retry/fallback policy (provider failure, designated uncertain outcomes) — never both by default (Arch §2 #6/#7, §10).

**Canonical verification statuses [APPROVED]** (Arch §10; DB `verification_status_enum`): `NOT_CHECKED, VALID, INVALID, CATCH_ALL, RISKY, UNKNOWN, DISPOSABLE, TEMPORARY_FAILURE`.

**Rules:**
- Per-lead verdict ≠ aggregate observed bounce rate. No numeric per-lead bounce-risk score is invented; provider scores (if any, with documented semantics) may be stored as provider metadata for analytics only — they do NOT feed the gate.
- Every verification result stores: provider, canonical result, provider raw metadata as required, `checked_at`. Append-only: reverification INSERTS a new history row; historical rows are never updated (DB §5.6, §7).
- Provider field-level status mapping (ZeroBounce status/sub_status → canonical concept) belongs to the API Integration Specification, not here.

**Verdict → lifecycle/suppression behavior:**

| Verdict | Lifecycle Effect | Suppression Effect |
|---|---|---|
| VALID | → VERIFIED (gate-ready) | none |
| INVALID | remains VERIFICATION_PENDING | suppression activated (reason `invalid_email`) — must not be sent |
| DISPOSABLE | remains VERIFICATION_PENDING | suppression activated (reason `invalid_email` per policy) — must not be sent |
| CATCH_ALL | remains VERIFICATION_PENDING | none; routes to review/hold path per campaign verification policy (default hold-for-review; policy value OPEN) |
| RISKY | remains VERIFICATION_PENDING | none; same configurable review/hold path |
| UNKNOWN | remains VERIFICATION_PENDING | none; bounded retry, fallback per policy; exhausted → review/DLQ |
| TEMPORARY_FAILURE | remains VERIFICATION_PENDING | none; bounded retry, fallback per policy |

**Freshness [APPROVED MECHANISM, OPEN VALUE]:**
```
latest verification result (latest row by checked_at) + verification_valid_for_days (configurable, OPEN)
        → fresh?
   YES → continue eligibility
   NO  → reverify before campaign admission (initial enrollment OR re-enrollment)
```
- Freshness is always derived from the latest relevant `verification_results.checked_at` + configured period — NOT solely from the `leads.verification_status` cache (DB §7 contract).
- Reverify creates NEW history and consumes verification credit; a stale result must block enrollment until re-verification completes (Arch §29 #18).
- Cache/history disagreement: canonical history lookup (latest `checked_at`) wins; cache repaired; disagreement must block, never permit (DB §7 fail-closed contract).

---

## 9. Eligibility and Campaign Assignment

The campaign eligibility gate (Architecture §11) — a lead reaches CAMPAIGN_READY only when ALL pass:

1. **Acceptable qualification fit** (A/B-Fit; PARKED and REJECT fail);
2. **Required campaign fields available** (per Campaign & ICP specification);
3. **Acceptable current verification result** (CATCH_ALL/RISKY handling per configurable campaign verification policy — Arch §12);
4. **Verification freshness** (§8 above);
5. **Not suppressed** — canonical suppression lookup by email (DB §10 contract); any active suppression blocks (coexistence/precedence = DB-D8 OPEN; fail-closed until defined);
6. **Valid campaign assignment** target;
7. **Campaign concurrency rules satisfied** (below);
8. **Approved personalization fields available where the campaign requires them** (fail-closed validation against `campaigns.signals_template_keys` — Arch §14).

**Campaign concurrency [APPROVED, CONTACT-LEVEL]** (Arch §13):
- One contact must not receive conflicting or overlapping active campaigns **unless explicitly permitted**.
- Multiple contacts at the same company may independently participate in different service campaigns (ABC India example: CFO→SVB, Compliance Head→BIS, Sustainability Head→EPR — all legitimate simultaneously).
- `company_domain` must NEVER be used as the concurrency gate.
- Implementation: DB model supports per-contact active-assignment uniqueness (`uq_assign_active_lead_campaign`) + `campaigns.conflict_group` (same non-NULL group = mutually exclusive per contact; NULL = independent). Conflict detection + explicit-permission path = workflow-level (n8n eligibility gate); conflict implementation details remain Arch §28 #7 OPEN. The DB intentionally has NO blanket one-active-campaign-per-contact constraint (DB §5.8).
- Re-enrollment supported: exit (active=FALSE + exited_at/exit_reason) → later re-enrollment creates a NEW assignment row; historical rows never deleted (DB §5.8, §8).

**Personalization evidence:** only approved structured signal keys reach outbound templates; missing/unapproved/invalid required keys REJECT the Warmbly sync (fail-closed) with logging + alert/review (Arch §14; DB `campaigns.signals_template_keys`).

---

## 10. Warmbly Enrollment and Sending Lifecycle

**Ownership split [APPROVED]** (Arch §3, §17, §29 #1/#3/#20):

| Aspect | Owner |
|---|---|
| Lead eligibility decision | n8n (eligibility gate) — NEVER Warmbly |
| Canonical lifecycle/suppression state | PostgreSQL — NEVER Warmbly |
| Campaign/sequence execution, follow-ups, pacing execution, mailbox rotation (where supported) | Warmbly |
| Outbound event/webhook production | Warmbly → n8n → PostgreSQL |
| Native suppression enforcement at its boundary | Warmbly (receives synced suppression state) |
| Transport | Google Workspace (no suppression/sequence/volume logic) |

**Flow [DERIVED sequencing from approved rules]:**
1. CAMPAIGN_READY lead + approved personalization fields → n8n performs Warmbly sync.
2. Signal-key validation fails → sync REJECTED (fail-closed), logged + alerted/reviewed; lead remains CAMPAIGN_READY for retry after data fix.
3. Warmbly API/sync failure → bounded retry → DLQ (Arch §22).
4. Warmbly enrollment confirmed → lead becomes IN_SEQUENCE; `campaign_assignments` row active.
5. Warmbly executes sequence/follow-ups via the mailbox pool; Google Workspace transports.
6. Warmbly produces outbound events (sent, delivered, bounce type, reply, unsubscribe, complaint) → n8n → PostgreSQL; events drive lifecycle, reply records, suppression, and health metrics.
7. PostgreSQL remains canonical throughout; Warmbly's internal execution state is never canonical.

**Event feedback loop:** Warmbly events/webhooks → n8n → PostgreSQL (Arch §4 return path, §20). Webhook silence alerts ONLY when activity was reasonably expected (context-aware silence rule, Arch §20).

---

## 11. Reply and Outcome Handling

Reply classification (`reply_class_enum`, DB §4): `positive`, `negative`, `explicit_unsubscribe`, `out_of_office`, `neutral`.

| Outcome | Lifecycle Effect | Suppression Effect | Sequence Effect | Handoff |
|---|---|---|---|---|
| **Positive reply** | IN_SEQUENCE → REPLIED_POSITIVE | none | Stop sequence | Hand off / notify downstream human/CRM sales process (Arch §9, §29 #21). NO CRM lifecycle states are created in this system |
| **Negative reply** | IN_SEQUENCE → REPLIED_NEGATIVE | **NO automatic global suppression** (Arch §29 #17). Any campaign-scoped temporary block would be an explicit, separately modeled scoped suppression record with an explicit reason — never conflated with negative replies (DB §10) | Stop/exit current sequence per reply policy | Cooldown before re-contact = configurable (value OPEN, Arch §28 #5) |
| **Explicit unsubscribe** | IN_SEQUENCE → UNSUBSCRIBED | GLOBAL suppression ACTIVATED (reason `explicit_unsubscribe`); no automatic expiry; removal requires explicitly authorized audited state change | Stop immediately | n/a |
| **Out-of-office** | lifecycle unchanged (remains IN_SEQUENCE) | none | Configurable pause/resume per reply policy | n/a |
| **Neutral / other** | lifecycle unchanged (remains IN_SEQUENCE) | none | Route per reply policy | n/a |
| **Spam complaint** | None — lifecycle PRESERVED (remains IN_SEQUENCE; no UNSUBSCRIBED transition; Arch §9/§16) | GLOBAL suppression ACTIVATED (reason `spam_complaint`); no automatic expiry | Stop immediately (no further sending) | n/a |
| **Hard bounce** | IN_SEQUENCE → BOUNCED | Suppression per approved bounce policy (reason `hard_bounce`; scope per configured policy) | Stop | n/a |
| **Soft bounce** | lifecycle unchanged (remains IN_SEQUENCE) | none (unless bounce policy escalates) | Per bounce policy | n/a |

**Key invariants:** explicit unsubscribe/do-not-contact → GLOBAL suppression (Arch §15); ordinary negative reply → sequence stop only (Arch §16); positive reply → downstream handoff, no CRM stage inflation (Arch §29 #21).

---

## 12. Suppression Overlay

**Suppression is orthogonal to lifecycle** [APPROVED] (Arch §16, §29 #19; DB §10):

- SUPPRESSED is a suppression-dimension state, NOT a lifecycle state. The 14-state lifecycle enumeration contains no SUPPRESSED.
- A lead can be, e.g., lifecycle `IN_SEQUENCE` while globally suppressed — lifecycle history shows the campaign activity; the suppression dimension independently blocks all sending.
- Suppression history never disappears when lifecycle changes; suppressed contacts cannot bypass suppression through re-enrollment (the pre-re-enrollment check is structural — Arch §15 point 3).
- **PARKED ≠ SUPPRESSED** — parked = "deferred, not yet worth optional spend"; suppressed = "do not contact."

**Scopes [APPROVED SCHEMA, OPEN POLICY]:**
- `GLOBAL` scope: `campaign_id IS NULL`; identity = email alone (`uq_supp_active_global`).
- `CAMPAIGN` scope: `campaign_id IS NOT NULL` (FK to campaigns); identity = (email, campaign) (`uq_supp_active_campaign`).
- Whether GLOBAL and CAMPAIGN suppressions may coexist for one contact, and any precedence — **OPEN (DB-D8)**. Until defined: gate logic treats ANY active suppression as blocking (fail-closed). This schema encodes scope identity, not precedence policy.
- Domain-wide suppression is NOT an architecture requirement and is not modeled.

**Triggers → behavior [APPROVED]** (Arch §15; DB `suppression_reason_enum` = `explicit_unsubscribe, spam_complaint, hard_bounce, invalid_email, manual_compliance_block, legal_or_policy_exclusion, manual`):

| Trigger | Behavior |
|---|---|
| Explicit unsubscribe / "do not contact me again" | GLOBAL suppression |
| Spam complaint | GLOBAL suppression |
| Hard bounce | Suppression according to approved bounce policy |
| Invalid email (verification) | Must not be sent (suppression reason `invalid_email`) |
| Ordinary negative reply | Stop/exit sequence per reply policy — NOT automatic global suppression |
| Legal/compliance/manual block | Suppression according to configured scope |

**No `negative_reply` reason exists in the enum** — by design (DB §4).

**Enforcement points [APPROVED]** (Arch §15): (1) lead intake; (2) pre-enrollment; (3) pre-re-enrollment; (4) Warmbly sync/execution gate; (5) event-driven updates.

**Removal/reactivation:** GLOBAL suppression has NO automatic expiry. Any removal/reactivation requires an explicitly authorized and audited state change (`suppression_events` DEACTIVATED row; UPDATE permitted on `suppression_list` for soft-deactivation; physical DELETE revoked at runtime — DB §5.9, §5.18). Suppression email/lead-mutation policy = **OPEN (DB-D7)**: workflows must NOT mutate `leads.email` in a way that could move a lead out from under an active suppression without an explicit suppression re-evaluation.

**Canonical lookup = email (CITEXT).** `leads.suppression_status` is a denormalized fast-gate cache maintained by a same-transaction application contract; on disagreement the canonical lookup wins and the cache must be repaired; disagreement must BLOCK, never permit (DB §5.9, §10).

---

## 13. Workflow Processing States

**RETRY and REVIEW are workflow-processing states — NOT lead lifecycle states** (Arch §9 closing note; DB lifecycle enum excludes them; they surface in `workflow_runs.status` / `dead_letter_events`).

| Processing State | Meaning | Typical Causes | Relation to Lifecycle |
|---|---|---|---|
| **RETRY (bounded, in-flight)** | A workflow run is re-executing a failed step under bounded retry policy | Provider API failure (Apollo/ZeroBounce/MillionVerifier), Warmbly sync failure, transient PostgreSQL failure | Lead lifecycle HOLDS at its current state (e.g., VERIFICATION_PENDING); no lifecycle transition occurs merely because a run is retrying |
| **REVIEW (manual review queue)** | A record requires human judgment | Ambiguous identity (dedupe priority #4), CATCH_ALL/RISKY hold-for-review, exhausted retries, signal-key validation failures, conflicting campaign assignment requiring explicit permission | Lead lifecycle HOLDS; the HOLD is a processing posture, not a lifecycle state |
| **DLQ (dead-letter)** | Exhausted failures parked for replay/inspection | Any exhausted failure class (Arch §22) | Lead lifecycle HOLDS; failure remains observable/replayable where safe |

**Rules:**
- Retry limits/backoff: bounded, values configurable unless already approved (Arch §22). No hardcoded retry counts are invented here.
- Successful processing simply resumes the normal lifecycle flow from the held state — no special "return transition" exists because the lifecycle never left it.
- Every failed run must be visible: `workflow_runs` (+ `dead_letter_events` for exhausted failures) — failures must not silently disappear (Arch §29 #14).

---

## 14. Re-enrollment Flow

**Re-enrollment = full gate, always** (Arch §9: "Re-enrollment for future campaigns is allowed only through the full eligibility gate (§11) and suppression checks (§15)").

**Re-enrollment gate (complete, in evaluation order):**

| # | Check | Source | Failure Behavior |
|---|---|---|---|
| 1 | Current suppression — canonical lookup by email (any active suppression blocks) | §12 / DB §10 | BLOCK; no bypass (Arch §29 #7) |
| 2 | Verification freshness — latest `checked_at` + `verification_valid_for_days` (value OPEN) | §8 / DB §7 | **Stale → reverify FIRST: new verification history row (consumes credit) → update result → re-evaluate gate.** Stale verification must NEVER silently allow enrollment (Arch §29 #18) |
| 3 | Campaign eligibility — required fields, acceptable verdict per campaign policy | §9 / campaign spec | BLOCK |
| 4 | Conflict/concurrency — contact-level conflict_group evaluation + explicit-permission path | §9 / Arch §13, §28 #7 | BLOCK unless explicitly permitted |
| 5 | Cooldown where applicable — e.g., negative-reply cooldown (value OPEN, Arch §28 #5) | §11 | BLOCK until elapsed |
| 6 | Prior campaign history — exited assignments preserved; re-enrollment creates NEW assignment row | DB §5.8 | n/a (history is evidence, not a blocker by itself) |
| 7 | Current email identity — email is the canonical suppression/verification lookup key; email-mutation policy = DB-D7 OPEN | §12 / DB §5.9 | Do not mutate email under active suppression without explicit re-evaluation |
| 8 | Current policy configuration — gate-affecting config values must be non-NULL (fail-closed on NULL; DB-D1) | DB §11 | BLOCK + alert if unresolved config encountered |

**Re-enrollment lifecycle path [DERIVED, consistent with Arch §9/§11]:** eligible prior participant → gate evaluation → (stale) VERIFICATION_PENDING → VERIFIED → CAMPAIGN_READY → IN_SEQUENCE, or (fresh) VERIFIED → CAMPAIGN_READY → IN_SEQUENCE. All transitions logged append-only.

---

## 15. State Ownership / Writer Matrix

PostgreSQL remains canonical (Arch §2 #1, §5, §29 #1).

| State / Dimension | Canonical Store | Primary Writer | Readers / Consumers |
|---|---|---|---|
| Lead lifecycle | `leads.lifecycle_status` + `lifecycle_events` (append-only history) | n8n | All gates, reporting, revisit scheduler |
| Verification (history — canonical) | `verification_results` (append-only; latest row by `checked_at`) | n8n (verification processing) | Freshness gate, eligibility gate, cache reconciliation |
| Verification (cache) | `leads.verification_status` | n8n (same transaction as history INSERT) | Fast gate reads (canonical wins on disagreement) |
| Suppression (current) | `suppression_list` (+ `leads.suppression_status` cache) | n8n (suppression enforcement) | Intake/pre-enrollment/pre-re-enrollment gates, Warmbly sync, fail-closed reconciliation |
| Suppression (history) | `suppression_events` (append-only) | n8n | Audit, compliance review |
| Qualification | `leads.qualification_fit`, `leads.reason` (audit), `leads.signals` + `signals_schema_version` | n8n (from OpenOutreach output) | Eligibility gate, template validation |
| Campaign assignment | `campaign_assignments` (+ `campaigns.conflict_group`) | n8n | Concurrency evaluation, re-enrollment history |
| Campaign definition | `campaigns` (required_fields, signals_template_keys, conflict_group) | Configuration/ops (via approved spec) | Eligibility gate, signal validation |
| Workflow processing | `workflow_runs`, `dead_letter_events` | n8n runtime | Monitoring/alerts, DLQ replay |
| Configuration | `policy_config` (current) + `config_history` (append-only audit) | ops/admin via audited change | All gates (runtime reads from policy_config ONLY, never config_history) |
| Warmbly/provider identifiers & events | `email_events` (idempotency_key UNIQUE), `replies`, `lead_enrichment` | n8n (from Warmbly webhooks / Apollo) | Reply handling, health metrics, lifecycle events |

---

## 16. Idempotency and Duplicate Event Handling

Derived from the approved schema (DB §5.11, §12) and Architecture §20:

| Duplicate Risk | Mechanism |
|---|---|
| Repeated discovery records (same source contact) | Source-scoped partial unique indexes (`uq_leads_source_lead`, `uq_leads_source_person`, `uq_leads_email_resolved`) prevent duplicate identity creation; unresolved ambiguity → manual review, never silent auto-merge |
| Duplicate verification callbacks/results | Verification is append-only by design — a recheck INSERTS a new row; the freshness gate reads the LATEST row by `checked_at`, so duplicate/late deliveries of the same check do not corrupt state; workflow-level dedupe of redundant provider calls is workflow-spec concern |
| Warmbly events/webhooks | `email_events.idempotency_key TEXT NOT NULL UNIQUE` — duplicate webhook deliveries must not double-count metrics (Arch §20; DB §5.11). When Warmbly supplies a stable event ID, `idempotency_key = warmbly_event_id`; otherwise a deterministic fallback key (composition = integration decision, DB-D4 OPEN) prevents silent duplicates |
| Reply events | Replies link to `email_events` via `event_id`; the event-level idempotency key governs; reply classification is idempotent per event |
| Suppression events | Active-state uniqueness is PostgreSQL-enforced (`uq_supp_active_global`, `uq_supp_active_campaign`) — a duplicate ACTIVATION for the same identity cannot create a second active row; history remains append-only (duplicate events are recorded but cannot create ambiguous current state) |
| Duplicate lifecycle transitions | Transitions are event-driven and append-only in `lifecycle_events`; workflows must evaluate current state before transitioning (no blind re-application of an already-applied transition) — enforcement is workflow-contract (n8n), not a DB constraint |

No database constraints beyond those in the approved schema are invented here.

---

## 17. Failure and Recovery Matrix

Failure classes per Architecture §22. Lifecycle impact, retry, review, and suppression columns are architecture-derived.

| Failure Scenario | Lifecycle Impact | Processing State | Retry? | Human Review? | Suppression Impact | Required Action |
|---|---|---|---|---|---|---|
| OpenOutreach input/output failure | Lead may not exist yet / intake incomplete | RETRY → DLQ | Yes (bounded) | On exhaustion | None | Retry intake; DLQ replay |
| OpenOutreach qualification output missing/invalid | HOLDS at DISCOVERED | RETRY → REVIEW | Yes | Yes | None | Re-request qualification output |
| Ambiguous duplicate identity | HOLDS at DISCOVERED (pre-qualification) | REVIEW | No | **Yes** (never auto-merge) | None | Manual identity resolution |
| Apollo API failure / credit exhaustion | HOLDS at ENRICHMENT_PENDING | RETRY → DLQ | Yes (bounded) | On exhaustion | None | Retry / check credits; graceful degradation per architecture |
| ZeroBounce failure | HOLDS at VERIFICATION_PENDING | RETRY | Yes | No | None | MillionVerifier fallback per policy |
| MillionVerifier fallback failure | HOLDS at VERIFICATION_PENDING | RETRY → DLQ | Yes | On exhaustion | None | Alert; replay |
| Stale verification at (re-)enrollment | VERIFIED → VERIFICATION_PENDING (reverify) | Normal processing | Yes (reverify) | On reverify failure | None | **reverify → consume verification credit → update result → re-evaluate gate** — never silently allow enrollment |
| CATCH_ALL / RISKY verdict | HOLDS at VERIFICATION_PENDING | REVIEW (default hold) | Per campaign policy | Yes (hold-for-review default) | None | Campaign verification policy decides admission (value OPEN) |
| UNKNOWN / TEMPORARY_FAILURE verdict | HOLDS at VERIFICATION_PENDING | RETRY | Yes (bounded) | On exhaustion | None | Retry / fallback per policy |
| INVALID / DISPOSABLE verdict | HOLDS at VERIFICATION_PENDING | Terminal for this email | No | Optional | **Suppression activated** (`invalid_email`) | Must not be sent |
| Warmbly sync failure | HOLDS at CAMPAIGN_READY | RETRY → DLQ | Yes | On exhaustion | None | Retry sync |
| Signal-key validation failure | HOLDS at CAMPAIGN_READY | REVIEW + alert | After data fix | **Yes** (fail-closed) | None | REJECT sync; fix/approve data; re-attempt |
| Webhook processing failure | Event not yet applied | RETRY → DLQ | Yes | On exhaustion | Potentially (e.g., missed unsubscribe) | Replay; context-aware webhook-silence alerting (Arch §20) |
| PostgreSQL failure | Processing halted | RETRY → DLQ | Yes | On exhaustion | None | Restore availability; replay |
| Mailbox/domain health event | None directly (sending infra) | n/a (health domain) | n/a | Per health policy | None | Context-aware escalation (Arch §19) |

---

## 18. Lifecycle Invariants

Implementation rules that MUST always remain true (derived from Architecture v1.3 §29 and Database Schema v1.2):

1. A lead is in exactly ONE of the 14 lifecycle states at any time; every change appends a `lifecycle_events` row (append-only).
2. Lifecycle, verification, and suppression remain three separate dimensions; no status column ever merges them.
3. SUPPRESSED is never a lifecycle state; suppression activates as an overlay while lifecycle history is preserved.
4. RETRY/REVIEW never appear in `leads.lifecycle_status`; they appear only in workflow processing records.
5. No CRM/sales stage (MEETING_BOOKED/CLOSED_WON/CLOSED_LOST) is ever written to the cold-email lifecycle; positive reply hands off downstream.
6. Ordinary negative reply never automatically creates GLOBAL suppression.
7. Explicit unsubscribe and spam complaint always activate GLOBAL suppression.
8. A suppressed contact can never be (re-)enrolled without an approved, audited suppression state change.
9. Stale verification (older than `verification_valid_for_days`) blocks initial enrollment AND re-enrollment until reverification produces a fresh result.
10. Historical verification results are never overwritten; reverification inserts new history.
11. Verification freshness is computed from `checked_at` + configured period, with the canonical history lookup winning over the cache.
12. No per-lead numeric bounce-risk score gates anything; provider verdict and aggregate bounce rate remain distinct.
13. Conflict enforcement is contact-level via `conflict_group` + explicit permission; `company_domain` is never used for person identity or concurrency.
14. Email-less leads cannot reach verification/campaign execution (workflow eligibility gate).
15. External identifiers are source-scoped; unresolved identity ambiguity goes to manual review, never silent auto-merge.
16. Only eligibility-gate-PASSED leads with fail-closed-validated approved signal keys reach Warmbly.
17. PostgreSQL remains canonical; Warmbly state is never canonical.
18. Raw qualification reasoning never reaches outbound content.
19. Operating values (freshness, revisit, cooldown, catch-all policy, sample sizes) remain configurable — never hardcoded as structure.
20. All failures remain observable (workflow_runs/DLQ); nothing silently disappears.

---

## 19. Open Decisions Affecting Lifecycle

Extracted from Architecture §28 and Database Schema §17. NONE are resolved by this document.

| Decision | Current Constraint | Why It Matters | Owner | Status |
|---|---|---|---|---|
| Catch-all campaign policy value (hold-for-review vs risk-cap) | Mechanism fixed (configurable hold/risk-cap); value OPEN (Arch §28 #1) | Determines when CATCH_ALL/RISKY leads may leave VERIFICATION_PENDING | User/architecture approval | OPEN |
| Verification freshness period (`verification_valid_for_days`) | Mechanism fixed; value OPEN (Arch §28 #3; DB-D1 seeding) | Gates initial enrollment and re-enrollment; stale results block | User/architecture approval | OPEN |
| C-Fit revisit period | Configurable revisit; value OPEN (Arch §28 #4) | PARKED → QUALIFIED revisit scheduling | User/architecture approval | OPEN |
| Negative-reply cooldown policy | Mechanism referenced; value OPEN (Arch §28 #5) | REPLIED_NEGATIVE → re-enrollment timing | User/architecture approval | OPEN |
| Campaign conflict / explicit-permission implementation | Contact-level rule fixed; implementation details downstream (Arch §28 #7) | Eligibility-gate conflict evaluation in n8n | n8n Workflow Specification (after approval) | OPEN |
| Mailbox assignment persistence/rotation | Pool model fixed; assignment details OPEN (Arch §28 #9; DB-D2) | Whether leads carry an assigned-mailbox pointer | User/architecture approval | OPEN |
| Data retention / PII cleanup | OPEN (Arch §28 #2) | REJECTED-lead retention, history retention | User/architecture approval | OPEN |
| Unresolved config values seeding (DB-D1) | Keys registered; values NULL + REQUIRED-CONFIGURATION note; fail-closed on NULL | All gate-affecting values above | User/architecture approval | OPEN |
| Suppression email/lead mutation (DB-D7) | Fail-closed recommendation recorded, not approved | Email correction under active suppression | User/architecture approval | OPEN |
| Suppression scope coexistence/precedence (DB-D8) | Scope identity encoded; coexistence/precedence OPEN; fail-closed until defined | Multi-scope suppression behavior | User/architecture approval | OPEN |
| Warmbly API/webhook capabilities (Arch §28 #8; DB-D4 idempotency fallback) | Architecture defines requirements; exact endpoints/behavior OPEN | Enrollment confirmation, event ingestion | API Integration Specification | OPEN |

---

## 20. Architecture / Database Traceability

| Lifecycle Requirement | Architecture Source | Database Object(s) | This Document Section |
|---|---|---|---|
| 14-state lifecycle enum | §9 | `lifecycle_status_enum` (DB §4) | §3 |
| Lifecycle transitions + append-only history | §9 | `lifecycle_events` (DB §5.13) | §4, §5 |
| Lead identity / 4-priority dedupe | §6 | `uq_leads_source_lead`, `uq_leads_source_person`, `uq_leads_email_resolved` (DB §5.4) | §6, §16 |
| Email optional at discovery | §6/§7 | `leads.email CITEXT NULL` (DB §5.4) | §6 |
| Source-scoped external IDs | §6, §29 #22 | partial unique indexes (DB §5.4) | §6 |
| Qualification fit A/B/C/Reject | §8 | `qualification_fit_enum`, `leads.qualification_fit` (DB §4/§5.4) | §6 |
| C-Fit PARKED + configurable revisit | §8, §28 #4 | PARKED state; `idx_leads_parked` (DB §5.4) | §6, §19 |
| Signals/internal-reason separation | §7, §14 | `leads.signals`, `signals_schema_version`, `leads.reason` (DB §5.4) | §6 |
| Enrichment optional / double-buy guard | §2 #4, §4 | `lead_enrichment` (`skipped`, `returned_fields`) (DB §5.5) | §7 |
| Verification canonical concepts | §10 | `verification_status_enum`, `verification_results` (DB §4/§5.6) | §8 |
| Verification append-only + freshness | §10, §11, §29 #18 | `verification_results.checked_at`, `idx_verif_lead_fresh`, `leads.verification_status` cache contract (DB §5.6/§7) | §8, §14 |
| Campaign eligibility gate (8 checks) | §11 | gates read `leads`, `suppression_list`, `verification_results`, `campaigns`, `campaign_assignments`, `policy_config` | §9 |
| Catch-all/review path | §12 | `catch_all_policy` config key (DB §5.14) | §8, §19 |
| Contact-level concurrency | §13, §29 #9 | `campaign_assignments` (`uq_assign_active_lead_campaign`), `campaigns.conflict_group` (DB §5.7/§5.8) | §9, §14 |
| Signals fail-closed | §14, §29 #11 | `campaigns.signals_template_keys` (DB §5.7) | §9, §10 |
| Suppression triggers/scopes | §15/§16 | `suppression_list` (scope CHECK, campaign_id FK, `uq_supp_active_global`, `uq_supp_active_campaign`), `suppression_events`, `suppression_reason_enum` (DB §4/§5.9/§5.10) | §12 |
| Suppression vs lifecycle separation | §16, §29 #19 | separate enums/tables (DB §4) | §1, §12 |
| Suppression cache/canonical contract | §15/§16 | `leads.suppression_status` denormalized + canonical precedence (DB §5.9/§10) | §12, §15 |
| Global suppression no auto-expiry | §15 | suppression soft-deactivation; DELETE revoked (DB §5.9/§5.18) | §12 |
| Warmbly execution boundaries | §17, §29 #1/#3 | `campaign_assignments`, `email_events` (DB §5.8/§5.11) | §10 |
| Mailbox pool | §18 | `sending_domains`, `mailboxes` (DB §5.1/§5.2) | §10 |
| Events/webhooks + idempotency | §20 | `email_events.idempotency_key UNIQUE`, `replies` (DB §5.11/§5.12/§12) | §10, §11, §16 |
| Reply classes | §15/§16 | `reply_class_enum`, `replies` (DB §4/§5.12) | §11 |
| Configuration scopes + audit | §21 | `policy_config` + `config_history` (DB §5.14/§5.15) | §14, §15, §19 |
| Retry/DLQ | §22, §29 #14 | `workflow_runs`, `dead_letter_events` (DB §5.16/§5.17) | §13, §17 |
| CRM stages excluded | §29 #21 | no sales_stage in DB (DB §17/DB-D3) | §3, §5 |
| Open decisions preserved | §28 | DB-D1..DB-D8 (DB §17) | §19 |

---

## 21. Implementation Handoff

The future **n8n Workflow Specification** must implement, from THIS document:

1. Intake/normalization/dedupe workflow implementing the 4-priority identity resolution and the manual-review path for ambiguity;
2. Qualification processing writing the lifecycle transitions DISCOVERED → QUALIFIED / PARKED (and REJECT retention);
3. PARKED revisit scheduler honoring the (OPEN) configurable revisit period with FRESH requalification;
4. Missing-fields decision + Apollo optional enrichment with double-buy guard;
5. Verification orchestration: ZeroBounce primary, policy-triggered MillionVerifier fallback, canonical mapping, append-only history writes, cache sync in the same transaction;
6. Freshness gate + full 8-check eligibility gate (including canonical suppression lookup and contact-level conflict evaluation);
7. Warmbly sync with fail-closed signal-key validation;
8. Event/webhook ingestion with `idempotency_key` enforcement, reply classification, and outcome-driven transitions (§11 table);
9. Suppression enforcement at all 5 approved enforcement points with same-transaction cache sync and fail-closed reconciliation;
10. Retry/review/DLQ wiring per §13/§17 with configurable bounds;
11. Configuration reads from `policy_config` only, failing closed on NULL gate-affecting values.

The n8n document will define node graphs, error branches, and credential handling; it must not redefine lifecycle semantics settled here.

---

## 22. Change Log

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-10-13 | Initial creation: implementation-ready lifecycle/status-flow specification derived from approved Architecture v1.3 and approved Database Schema v1.2 — 14-state model, transition matrix, five-dimension separation, suppression overlay, workflow-processing states, re-enrollment gate, idempotency, failure/recovery matrix, invariants, open decisions carried forward, traceability, implementation handoff. Status: Draft for review |
| 1.0 (patch) | 2026-10-13 | Review patch (no version increment): corrected spam-complaint handling to preserve lifecycle state while activating GLOBAL suppression and stopping sending (Arch §9/§16) — no UNSUBSCRIBED transition manufactured; aligned §4 Mermaid with the gated re-enrollment re-entry path for COMPLETED / REPLIED_NEGATIVE (full gate required, never unconditional); explicitly labeled the stale-verification VERIFIED → VERIFICATION_PENDING reverify transition and the COMPLETED/REPLIED_NEGATIVE re-enrollment entry as [DERIVED, per Arch §11 freshness flow]. Open decisions remain 11 unique rows, all unresolved. |
| 1.0 | 2026-10-13 | Approved — Final post-patch verification passed with no blockers, SHOULD FIX findings, regressions, architecture conflicts, or database alignment issues; Lead Lifecycle & Status Flow v1.0 approved as the lifecycle implementation specification of Architecture v1.3. |
