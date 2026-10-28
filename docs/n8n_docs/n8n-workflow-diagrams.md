# SKMC Cold Email Automation — n8n Workflow Diagrams

**Version:** 1.0 | **Date:** 2026-10-17 | **Status:** Draft v1.0 — Pending Review. **Not approved.**

**Master references:** `n8n-workflow-spec.md` v1.1 (catalog §3, orchestration §4), `n8n-workflow-contracts.md` v1.0 (§4 contracts), `n8n-database-mapping.md` v1.0 (§3–§4 mappings).

**Derived from:** approved Architecture v1.3, Database Schema v1.2, Lifecycle v1.0, API Integration Spec v1.0, Verification & Suppression Rules v1.0 — plus the workflow contracts. **No new rules, lifecycle states, DB objects, or provider capabilities introduced here.**

---

## §1 Purpose

Visual representations of the approved orchestration: one end-to-end flowchart, 13 sequence diagrams (A–M), and the workflow dependency graph. Every diagram mirrors contract behavior exactly; where behavior is OPEN/TO VERIFY, the diagram marks it rather than assuming.

## §2 End-to-End Flowchart (single master)

```mermaid
flowchart TD
    OO[OpenOutreach<br/>discovery + verdict] --> WF01[WF-01 Lead Intake]
    WF01 --> L[(leads<br/>DISCOVERED)]
    L --> WF02[WF-02 Qualification Ingestion]
    WF02 -->|A_FIT / B_FIT| WF03[WF-03 Enrichment Orchestration<br/>conditional - Apollo optional]
    WF02 -->|C_FIT| P[leads PARKED]
    P -.cadence c_fit_revisit_days<br/>NULL = no-op.-> WF13[WF-13 PARKED/C-Fit Revisit<br/>scheduled]
    WF13 -.re-trigger.-> WF02
    WF02 -->|REJECT| REJ[terminal non-fit<br/>no paid processing]
    WF03 --> WF04[WF-04 Verification Orchestration<br/>ZeroBounce primary<br/>MV conditional fallback]
    WF04 -->|VALID + fresh| WF05[WF-05 Campaign Eligibility Gate<br/>incl. re-entry evaluation]
    WF04 -->|INVALID/DISPOSABLE| SUP1[(suppression<br/>invalid_email<br/>lifecycle remains VERIFICATION_PENDING)]
    WF04 -->|provider failure| HOLD1[HOLD at VERIFICATION_PENDING<br/>bounded retry / DLQ]
    WF05 -->|full gate pass| WF06[WF-06 Assignment + Warmbly Enrollment<br/>pre-enrollment recheck]
    WF06 -->|confirmed only| INSEQ[leads IN_SEQUENCE]
    WF06 -.Warmbly endpoints TO VERIFY.-> WB[Warmbly<br/>sequence execution]
    WB -->|webhooks| WF07[WF-07 Webhook Ingestion<br/>idempotency_key UNIQUE]
    WF07 --> EE[(email_events)]
    WF07 -->|REPLY| WF08[WF-08 Reply Processing]
    WF07 -->|bounce| WF09[WF-09 Bounce Processing]
    WF07 -->|UNSUBSCRIBE| WF10[WF-10 Unsubscribe Processing]
    WF07 -->|SPAM_COMPLAINT| WF11[WF-11 Spam Complaint Processing]
    WF07 -->|completed| WF12[WF-12 Sequence Completion]
    WF08 --> WF05B[WF-05 re-entry gate<br/>only via explicit approved trigger]
    WF12 --> WF05B
    WF10 --> SUP2[(suppression GLOBAL<br/>lifecycle UNSUBSCRIBED)]
    WF11 --> SUP3[(suppression GLOBAL<br/>lifecycle PRESERVED)]
    WF09 -->|hard| SUP4[(suppression per policy<br/>lifecycle BOUNCED)]
    WF05B --> WF05
    PG[(PostgreSQL outreach_db<br/>CANONICAL - all state)]
    SUP1 --> PG
    SUP2 --> PG
    SUP3 --> PG
    SUP4 --> PG
    EE --> PG
    L --> PG
    INSEQ --> PG
    P --> PG
    SCHED[WF-13/14/15/16<br/>scheduled: DLQ replay - reconciliation - health] -.safety re-checks.-> PG
```

PostgreSQL is canonical throughout; no provider mutates another provider's canonical state. All transitions shown are approved 14-state enum transitions or suppression-dimension changes.

## §3 Sequence Diagrams (A–M)

### A. Happy path — new qualified lead → verified

```mermaid
sequenceDiagram
    participant OO as OpenOutreach
    participant N8 as n8n (WF-01/02/04)
    participant DB as PostgreSQL (leads / verification_results / lifecycle_events)
    participant ZB as ZeroBounce
    OO->>N8: discovery event
    N8->>DB: identity lookup (uq_leads_source_lead/person/email_resolved)
    N8->>DB: INSERT leads (DISCOVERED) + lifecycle_events
    OO->>N8: qualification verdict A_FIT
    N8->>DB: UPDATE leads (qualification_fit, QUALIFIED) + lifecycle_events
    N8->>DB: suppression precheck (suppression_list by email)
    N8->>ZB: verify (freshness check passed - no cache hit)
    ZB-->>N8: VALID
    N8->>DB: INSERT verification_results + leads.verification_status=VALID (SAME transaction) + lifecycle_events (VERIFIED)
```

### B. Enrichment path — double-buy guard

```mermaid
sequenceDiagram
    participant N8 as n8n (WF-03)
    participant DB as PostgreSQL (lead_enrichment / leads)
    participant AP as Apollo
    N8->>DB: check existing enrichment for lead (guard)
    alt existing successful enrichment covers required fields
        N8->>DB: INSERT lead_enrichment (skipped=TRUE)
        Note over N8: no Apollo call - double-buy guard
    else enrichment needed
        N8->>AP: enrichment call (API §7 contract)
        AP-->>N8: response
        N8->>DB: INSERT lead_enrichment (returned_fields evidence) + leads cache update + ENRICHED
    end
```

### C. Verification fallback — ZeroBounce UNKNOWN → MillionVerifier

```mermaid
sequenceDiagram
    participant N8 as n8n (WF-04)
    participant DB as PostgreSQL (verification_results)
    participant ZB as ZeroBounce
    participant MV as MillionVerifier
    N8->>ZB: verify
    ZB-->>N8: UNKNOWN
    N8->>DB: INSERT verification_results (UNKNOWN, is_fallback=FALSE)
    Note over N8: bounded retry at ZB per policy
    N8->>ZB: retry
    ZB-->>N8: UNKNOWN (exhausted)
    N8->>MV: fallback per policy (is_fallback=TRUE)
    MV-->>N8: INVALID
    N8->>DB: INSERT verification_results (INVALID, is_fallback=TRUE) + suppression invalid_email per policy + lifecycle HOLDS at VERIFICATION_PENDING
```

### D. Suppressed lead blocked at gate

```mermaid
sequenceDiagram
    participant N8 as n8n (WF-05 gate)
    participant DB as PostgreSQL (suppression_list / leads)
    N8->>DB: canonical suppression lookup by email (CITEXT)
    DB-->>N8: active GLOBAL suppression exists
    N8-->>N8: POLICY_REJECTED - fail-closed
    Note over N8: NO verification spend, NO enrollment, NO lifecycle mutation
    N8->>DB: workflow_runs (gate rejection reason recorded)
```

### E. Re-entry with stale verification

```mermaid
sequenceDiagram
    participant OWNER as Owner (explicit approved trigger)
    participant N8 as n8n (WF-05 / WF-04)
    participant DB as PostgreSQL
    OWNER->>N8: re-entry request (never automatic)
    N8->>DB: suppression check (canonical email)
    N8->>DB: cooldown check (negative_reply_cooldown_days - NULL = fail-closed)
    N8->>DB: freshness: latest checked_at vs verification_valid_for_days (NULL = fail-closed)
    Note over N8: stale → reverify required
    N8->>DB: lifecycle VERIFIED → VERIFICATION_PENDING (approved transition)
    N8->>N8: WF-04 reverify (new history row, new credit)
    N8->>DB: fresh VALID → CAMPAIGN_READY → WF-06 full enrollment gate
```

### F. Race — suppression arrives during enrollment

```mermaid
sequenceDiagram
    participant N8 as n8n (WF-06)
    participant DB as PostgreSQL
    participant WB as Warmbly
    N8->>DB: pre-enrollment recheck (suppression / freshness / conflicts)
    N8->>DB: INSERT campaign_assignments (uq_assign_active_lead_campaign)
    N8->>WB: enrollment sync (TO VERIFY endpoints)
    par concurrent safety event
        DB-->>N8: UNSUBSCRIBE event arrives (via WF-07)
    end
    N8-->>N8: latest canonical SAFETY state wins
    N8->>DB: lifecycle IN_SEQUENCE → UNSUBSCRIBED + GLOBAL suppression
    N8->>WB: stop propagation (execution-only, idempotent)
    Note over N8: safety beats in-flight enrollment; unknown WB outcome = HOLD + reconcile, never assumed success
```

### G. Duplicate webhook

```mermaid
sequenceDiagram
    participant WB as Warmbly
    participant N8 as n8n (WF-07)
    participant DB as PostgreSQL (email_events)
    WB->>N8: event delivery (idempotency_key K)
    N8->>DB: INSERT email_events (raw_payload, processed_at NULL)
    WB->>N8: SAME event redelivered (key K)
    N8->>DB: idempotency_key UNIQUE violation
    Note over N8: DUPLICATE_EVENT - original row untouched, NO business effect repeated
    N8-->>WB: 2xx ack (idempotent)
```

### H. Malformed / unknown webhook event → DLQ

```mermaid
sequenceDiagram
    participant WB as Warmbly
    participant N8 as n8n (WF-07)
    participant DB as PostgreSQL
    WB->>N8: non-JSON payload
    Note over N8: raw_payload is JSONB NOT NULL - cannot store in email_events
    N8->>DB: INSERT dead_letter_events (payload_ref, unparseable)
    WB->>N8: valid JSON, unknown event_type / missing identifiers
    N8->>DB: dead_letter_events (mapping unknown / identity unresolved) - no invented event types
    N8-->>WB: ack per verified provider contract (TO VERIFY)
```

### I. Bounce handling — hard vs soft

```mermaid
sequenceDiagram
    participant WB as Warmbly
    participant N8 as n8n (WF-09)
    participant DB as PostgreSQL
    WB->>N8: HARD_BOUNCE (bounce_type=hard)
    N8->>DB: lifecycle IN_SEQUENCE → BOUNCED + suppression (hard_bounce reason, scope per configured policy - OPEN)
    WB->>N8: SOFT_BOUNCE (bounce_type=soft)
    Note over N8: lifecycle unchanged (not lifecycle-terminal by itself); escalation ONLY via bounce policy (threshold NULL = fail-closed)
    N8->>DB: email_events evidence only
    Note over N8: observed bounce ≠ verification status (no bounce_risk_score; Arch §29 #6)
```

### J. Unsubscribe

```mermaid
sequenceDiagram
    participant WB as Warmbly
    participant N8 as n8n (WF-10)
    participant DB as PostgreSQL
    WB->>N8: UNSUBSCRIBE event
    N8->>DB: suppression_list INSERT (GLOBAL, explicit_unsubscribe, source_event_id) + suppression_events (ACTIVATED)
    N8->>DB: lifecycle IN_SEQUENCE → UNSUBSCRIBED (the ONLY event producing UNSUBSCRIBED)
    N8->>WB: sequence stop (execution-only)
    Note over N8: GLOBAL suppression has NO automatic expiry; removal = explicitly authorized audited DEACTIVATED event only
```

### K. Spam complaint — suppression WITHOUT lifecycle rewrite

```mermaid
sequenceDiagram
    participant WB as Warmbly
    participant N8 as n8n (WF-11)
    participant DB as PostgreSQL
    WB->>N8: SPAM_COMPLAINT event (email_events type - NOT a reply classification)
    N8->>DB: suppression_list INSERT (GLOBAL, spam_complaint) + suppression_events (ACTIVATED)
    Note over N8: lifecycle PRESERVED - remains IN_SEQUENCE; MUST NOT become UNSUBSCRIBED
    Note over N8: NO lifecycle_events row for preservation (approved behavior - do not "fix")
    N8->>WB: stop sequence + future sending
    Note over N8: complaint never conflated with unsubscribe (WF-10/WF-11 structurally distinct)
```

### L. Enrollment timeout / unknown outcome

```mermaid
sequenceDiagram
    participant N8 as n8n (WF-06)
    participant DB as PostgreSQL
    participant WB as Warmbly
    N8->>DB: assignment INSERT committed
    N8->>WB: enrollment sync
    WB--xN8: timeout - outcome unknown
    Note over N8: external action is NEVER DB-atomic; success never assumed
    N8->>DB: NO lifecycle transition (no IN_SEQUENCE without confirmed enrollment)
    N8->>DB: workflow_runs failed + dead_letter_events after bounded retry
    N8->>N8: WF-15 reconciliation (Warmbly state queries TO VERIFY)
    Note over N8: replay re-checks ALL safety gates before any re-sync
```

### M. DLQ controlled replay

```mermaid
sequenceDiagram
    participant N8 as n8n (WF-14)
    participant DB as PostgreSQL (dead_letter_events)
    participant N8P as n8n (proper processor)
    N8->>DB: read OPEN dead_letter_events (scheduled/manual)
    N8->>DB: classify item (retryable-now / needs-fix / discard)
    N8->>DB: safety re-checks for replayed op (canonical suppression / verification freshness / config)
    alt safe to replay
        N8->>DB: status → REPLAYED, attempt_count++
        N8->>N8P: replay via original contract (same correlation id - idempotent)
    else unsafe / suppressed / outdated
        N8->>DB: status → RESOLVED / DISCARDED (no effect)
    end
    Note over N8: replay never bypasses current suppression/freshness/config state
```

## §4 Workflow Dependency Graph

Catalog totals (consistent with master spec §3): **16 workflows — event-driven 12 (WF-01…WF-12), scheduled 4 (WF-13, WF-14, WF-15, WF-16; WF-14 additionally manual-capable).**

```mermaid
flowchart LR
    subgraph EventDriven[Event-driven 12]
        WF01 --> WF02 --> WF03 --> WF04 --> WF05 --> WF06
        WF07 --> WF08
        WF07 --> WF09
        WF07 --> WF10
        WF07 --> WF11
        WF07 --> WF12
    end
    subgraph Reentry[Explicit approved re-entry]
        WF08 -.positive/terminal path.-> WF05
        WF12 -.no auto re-enroll.-> WF05
    end
    subgraph Scheduled[Scheduled 4]
        WF13 -.due PARKED leads.-> WF02
        WF14 -.replay via proper processor.-> WF04
        WF14 -.replay.-> WF06
        WF15 -.cache repairs.-> DB2[(canonical caches)]
        WF16[WF-16 Health/Alert Evaluation] -.reads workflow_runs / email_events / DLQ / health.-> DB2
    end
    WF05 -.gate pass.-> WF06
    WF06 -.webhook feedback.-> WF07
```

- **Event-driven chain:** WF-01 → WF-02 → (WF-03) → WF-04 → WF-05 → WF-06 → WF-07 → {WF-08…WF-12}.
- **Unguarded cycles: NONE.** The only cycle-shaped edges are (a) WF-13 → WF-02 re-qualification (cadence-gated, `c_fit_revisit_days` NULL = no-op) and (b) re-entry into WF-05 — which requires an explicit approved trigger and passes the full gate (suppression, cooldown, verification existence/freshness/reverification, campaign eligibility, conflict, enrollment gate — Doc 6 §21). No direct COMPLETED → IN_SEQUENCE edge exists anywhere.
- **No unsafe sending path:** every edge into WF-06 passes WF-05's full gate plus WF-06's own pre-enrollment recheck; every DLQ replay re-checks all gates before any effect that could send.

## §5 Diagram–Contract Consistency Notes & Carried OPEN Items

- All diagrams reflect contracts v1.0 §4 exactly; no new behavior introduced.
- **TO VERIFY placeholders preserved in-diagram:** Warmbly endpoints/auth/event names/ordering (WF-06/07/08/09/10/11, §F/§H/§I/§J/§K/§L); WF-15 Warmbly state queries (§L).
- **OPEN configs shown as fail-closed:** `c_fit_revisit_days`, `verification_valid_for_days`, `negative_reply_cooldown_days`, `catch_all_policy`, bounce threshold/scope, `minimum_sample_size`, alert channel — NULL = no-op/block/no-alert as applicable.
- **Mapping gaps — RESOLVED per owner decision (2026-10-17):** `sending_domains`/`mailboxes` health ownership = authorized administrators control warmup/pause; WF-15 updates health indicators only with provider evidence + approved mapping; no automatic unpause/sending-enablement/unsupported HEALTHY assignment; all changes auditable. `companies` INSERT/UPDATE now explicit in contracts v1.1 (WF-01/WF-03). See `n8n-database-mapping.md` §3.1–§3.3.
- DB-D4 (idempotency-key composition) remains OPEN — §G shows the mechanism, not the composition.

## §6 Change Log

- v1.0 (2026-10-17): initial diagrams draft — 1 end-to-end flowchart, 13 sequence diagrams (A–M), dependency graph — derived from contracts v1.0 and approved sources. Status: Draft v1.0 — Pending Review. NOT approved.
- v1.0r (2026-10-17): §5 mapping-gap note updated to RESOLVED status per owner decision (health ownership = administrators + evidence-gated WF-15; companies explicit in contracts v1.1). Diagrams unchanged.
