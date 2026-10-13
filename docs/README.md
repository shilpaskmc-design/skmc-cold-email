# SKMC Cold Email Automation — Documentation Index

**Last updated:** 2026-10-12 | Maintained so nobody has to guess which doc is what.

## Reading order / dependency

```
architecture.md (WHY/WHAT — system design, locked)
        ↓
implementation-plan-v1.3.md (HOW — build source of truth, approved)
        ↓
database-schema.md (DATA — lead data model, draft for review)
        ↓
campaign-icp-spec.md (WHO — first campaign definition, Oct 8, review pending)
        ↓
[TODO] n8n-workflow-spec.md  →  [TODO] api-integration-spec.md  →  [TODO] uat-test-plan.md
```

## Document registry

| File | Version | Status | Role | Last change |
|---|---|---|---|---|
| architecture.md | v1.2 | FINALIZED | System architecture: component responsibilities, gates, suppression enforcement (n8n/Warmbly, Gmail = transport only), lifecycle, infra topology, failure modes, security boundaries, open questions | 2026-10-12: header corrected 1.1→1.2 (cosmetic; matches change log) |
| implementation-plan-v1.3.md | v1.3 | APPROVED — build source of truth (subject to §30 Open Questions) | 12 n8n workflows (WF-01..12), verification freshness gate, min-sample-size health rules, context-aware escalation, contact-level campaign concurrency, signals/personalization_evidence schema, failure-mode matrix, parallel warm-up Gantt, security controls, Open Questions tracker (11 items) | 2026-10-12: created — merge of v1.2 plan + restored architecture details + 3 approved additions (WF-05 signal-key validation, stale-verification row, C-Fit/PARKED 0-credit economics) |
| database-schema.md | v1.0 | DRAFT — review pending | outreach_db DDL: 15 tables (14 planned + campaigns), enums, indexes, ZeroBounce/MillionVerifier field mapping (Open Q#2 resolved), seed config | 2026-10-12: created |
| campaign-icp-spec.md | — | Pre-existing (2026-10-08) | First campaign / ICP definition — feeds campaigns.icp_doc_ref | not touched this session |
| architecture.pdf | — | render artifact | architecture.md rendered | 2026-10-09 |
| _architecture_tmp.html | — | temp artifact | safe to delete | 2026-10-09 |

## Pending decisions (user-owned)

1. **database-schema.md approval** + confirm 3 seeded values: `verification_valid_for_days=30`, `c_fit_revisit_days=60`, `minimum_sample_size=200`
2. **Open Questions #1, #4, #5** (Warmbly plan tier, secondary domain names, alert channel) — see implementation-plan-v1.3.md §30 for full table
3. Decide pilot SKMC service (pairs with campaign-icp-spec.md)

## Session history (what happened when)

- **2026-10-08:** architecture v1.0 → v1.1 (external review); campaign-icp-spec.md created
- **2026-10-09:** architecture v1.2 (mermaid appendix); architecture.pdf rendered
- **2026-10-12 (this session):** implementation-plan v1.2 → v1.3 merged & approved; database-schema.md created; architecture.md header fix only
