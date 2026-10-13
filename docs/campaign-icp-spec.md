# SKMC — Campaign & ICP Specification

**Version:** 0.1 | **Date:** 2026-10-08 | **Status:** Template — fill bracketed values
**Purpose:** Defines which prospects qualify for each SKMC service campaign. This is the rulebook the LLM (OpenOutreach) uses to qualify, the fields Apollo enriches, and the tags Warmbly personalizes with.

**Rule of use:** One campaign = one service = one ICP. Never mix services in one campaign — messaging and qualification diverge.

---

## 1. Campaign Registry (Master List)

| Campaign ID | Service Offered | Status | Lead Volume Target | Owner |
|-------------|-----------------|--------|--------------------|-------|
| `WPC-ETA-01` | WPC/ETA License (Bluetooth/WiFi devices) | 🟢 Active (first campaign) | 500 leads/mo | [owner] |
| `BIS-01` | BIS Certification (electronics) | 🟡 Planned — launch after WPC stabilizes | [target] | [owner] |
| `EPR-01` | EPR Compliance (plastic/e-waste) | ⚪ Backlog | [target] | [owner] |
| `CUSTOMS-01` | Customs Consulting (import classification) | ⚪ Backlog | [target] | [owner] |

> **Rule:** A company can appear in only ONE active campaign at a time. The dedupe check (n8n, Step 03) must also check active-campaign membership, not just raw email duplicates.

---

## 2. Campaign WPC-ETA-01 — Full Specification

### 2.1 Product/Service Description (`product.md` content)

> **Fill in real numbers — LLM uses these to write qualification reasons.**

```markdown
We help wireless device manufacturers get WPC/ETA (Equipment Type
Approval) certification in India — mandatory for any product with
Bluetooth, WiFi, or RF capabilities.

What we do end-to-end:
- RF testing coordination (accredited labs)
- Technical documentation preparation (test reports, user manual, RF datasheet)
- WPC portal filing and follow-up
- ETA approval in [X] weeks vs [Y]-month industry average

Proof points:
- [N] devices cleared across [categories]
- [Client type] clients — [result example]
- [Differentiator: e.g., pre-audit of documents reduces rejection to near zero]
```

### 2.2 Target Market Definition (`target.md` content)

#### A. Firmographics

| Attribute | Qualifying Value | Notes |
|-----------|------------------|-------|
| Industry | IoT, MedTech, Consumer Electronics, Telematics, Smart Home | Must manufacture/brand devices with BT/WiFi/RF |
| Company size | 10–500 employees | Below 10 → founder-led, still valid if funded |
| Stage | Seed → Series B, OR profitable bootstrapped | Enterprise (>1000 emp) has in-house compliance — **disqualify** |
| Geography | Selling INTO India (any HQ country) | "India entry" OR existing India ops launching new SKU |
| Role type | Manufacturer/brand owner | **Not** distributor, reseller, testing lab, or consultant |

#### B. Trigger Signals (buying intent — any ONE qualifies as "warm")

| # | Signal | Where detected | Weight |
|---|--------|----------------|--------|
| T1 | Announced "India launch" (press, LinkedIn, funding docs) | OpenOutreach scrape / Apollo | High |
| T2 | FDA/CE/FCC approval recently received (India is the next market) | Apollo, news | High |
| T3 | Hiring "Regulatory Affairs", "Compliance Manager", "Certification Engineer" | Apollo `job_postings` | High |
| T4 | New BLE/WiFi product on Indiegogo/Kickstarter/own site with "coming to India" | Web scrape | Medium |
| T5 | Existing India ops + new product SKU in pipeline | Apollo | Medium |
| T6 | Import of RF modules detected (customs data, if available) | — | Low (future) |

#### C. Decision Makers (who we email)

| Priority | Title patterns | Notes |
|----------|---------------|-------|
| 1 (companies < 50 emp) | Founder, CEO, Co-founder | They own certification decisions directly |
| 2 | VP Product, Head of Hardware, CTO | Own launch timeline |
| 3 | Regulatory Affairs Manager, Compliance Lead | If exists — strongest signal the pain is real |
| ❌ Never | HR, Sales, Marketing, Support | Waste of a send |

#### D. Disqualifiers (hard NO — LLM must reject, never export)

1. ❌ No wireless/RF product line at all
2. ❌ Already has in-house regulatory/compliance team > 2 people
3. ❌ Distributor, reseller, testing lab, or competing consultancy
4. ❌ Device category explicitly out of WPC scope (e.g., non-RF products)
5. ❌ Company is insolvent/shut down (check status)
6. ❌ Already an SKMC client (check CRM/suppression before export)

---

### 2.3 Qualification Scoring (for LLM + analytics)

**Minimum bar to buy an email (1 credit):** Firmographics A pass + at least ONE trigger signal from B.

| Score | Criteria | Action |
|-------|----------|--------|
| **A-fit** | A-pass + T1/T2/T3 (high trigger) + Decision Maker P1/P2 | Buy email, enter sequence |
| **B-fit** | A-pass + T4/T5/T6 OR high trigger with P3 decision maker | Buy email, lower-priority sequence variant |
| **C-fit** | A-pass, no trigger signals | Do NOT buy email. Keep in DB free, revisit in 60 days |
| **Reject** | Any disqualifier D | Never export, tag rejection reason |

> **Credit discipline:** `C-fit` leads never cost a credit. This is why tight ICP saves ~30–50% spend.

---

### 2.4 Anti-Patterns (LLM few-shot examples)

```
✅ GOOD LEAD:
"MedTech Solutions — 45 emp, Series A $5M. FDA-cleared BLE blood
pressure monitor launching in India Q3. Hiring Regulatory Affairs
Manager. Decision maker: CEO Priya Mehta."
WHY: A-pass (IoT/BT device, right size/stage) + T2 (FDA done) +
T3 (RA hiring) + P1 decision maker. → A-fit, buy email.

✅ GOOD LEAD:
"SmartHome Devices Pvt Ltd — 120 emp, bootstrapped profitable.
Existing India operations, launching WiFi-enabled thermostat line.
Decision maker: VP Product."
WHY: A-pass + T5 (existing ops, new SKU). → B-fit, buy email.

❌ REJECT 1:
"Global Electronics Corp — 15,000 emp, Fortune 500. Full in-house
regulatory team of 12. Launching Bluetooth speaker in India."
WHY: D2 disqualifier (large in-house compliance) + enterprise size.
→ Reject, tag: in_house_compliance.

❌ REJECT 2:
"CircuitHub Distribution — authorized reseller of IoT modules."
WHY: D3 (distributor, not manufacturer). → Reject, tag: not_manufacturer.

❌ REJECT 3:
"CleanWater Tech — water purification IoT, no radio connectivity."
WHY: D1 (no wireless/RF product — WPC irrelevant). → Reject, tag: no_rf_product.
```

---

### 2.5 Enrichment Priority (Apollo fields for this campaign)

| Priority | Field | Used For |
|----------|-------|----------|
| Must-have | `email` (from OpenOutreach), `first_name`, `company`, `title` | Sequence + sending |
| Must-have | `tech_stack` | Personalization: reference their RF/BLE stack |
| Must-have | `funding_round`, `total_funding` | Trigger signal + message tone (funded = budget talk) |
| Should-have | `linkedin_url` | Social touch / vetting |
| Should-have | `employee_count` | ICP size validation post-scrape |
| Nice-to-have | `company_revenue` | Deep personalization in Email 3+ |
| Nice-to-have | `job_postings` (RA roles) | T3 trigger verification |

---

### 2.6 Warmbly Tag Mapping (derived from this ICP)

| Tag | Source Field | Example (Priya Mehta) |
|-----|--------------|----------------------|
| `{{first_name}}` | `first_name` | Priya |
| `{{company}}` | `company` | MedTech Solutions |
| `{{device_type}}` | [NEW — add to OpenOutreach `reason` extraction or Apollo] | BLE blood pressure monitor |
| `{{tech_stack}}` | `tech_stack` | BLE, ESP32 |
| `{{funding}}` | `funding_round` | Series A $5M |
| `{{launch_timing}}` | From `reason` parsing (Q3, Q4, "next quarter") | Q3 |
| `{{approval_signal}}` | From `reason` parsing (FDA/CE/FCC) | FDA-cleared |

> **Note:** `{{device_type}}`, `{{launch_timing}}`, `{{approval_signal}}` are NOT standard Apollo fields — they must be parsed from the OpenOutreach `reason` text during n8n normalization (Step 03), or the ICP doc must instruct OpenOutreach to include them. **Flag this to OpenOutreach output requirements.**

---

### 2.7 Sequence Configuration (per this campaign)

| Parameter | Value |
|-----------|-------|
| Sequence length | 5 emails (add 6th/7th only for A-fit tier) |
| Cadence | Day 0, 3, 7, 12, 18 |
| Email 1 angle | Value Prop — "WPC ETA in 6 weeks, not 6 months" |
| Email 2 angle | Case Study — same device category if possible |
| Email 3 angle | Pain Point — launch delay risk |
| Email 4 angle | 1-Question (reply-bait) |
| Email 5 angle | Breakup (A-fit only gets 2 more touches before this) |
| B-fit variant | Emails 1, 3, 5 only (shorter sequence) |
| Tracking | No pixels. CNAME tracking domain only if link needed (Email 2+) |

---

## 3. Per-Service ICP Variance Table (fill for other campaigns)

When launching `BIS-01`, `EPR-01`, etc., copy Section 2 and change ONLY:

| Section | What changes per service |
|---------|--------------------------|
| 2.1 Product description | Service specifics, proof points |
| 2.2-A Industry column | E.g., BIS → electronics/toys/firmware importers |
| 2.2-B Trigger signals | E.g., BIS → "mandatory registration list updated", CRS logo missing |
| 2.2-C Decision makers | Mostly same across services |
| 2.5 Enrichment must-haves | E.g., BIS → IS-standard number field |
| 2.7 Email angles | Pain point changes per regulation |

**Rule: firmographics skeleton stays stable; triggers + angles change.** This is why ICP doc and Campaign doc are one file — split them and they drift.

---

## 4. Review Cadence

| Review | When | What |
|--------|------|------|
| Qualification audit | Weekly, first 4 weeks | Sample 20 qualified leads — is `reason` actually convincing? |
| Trigger effectiveness | Monthly | Which trigger signals correlate with replies? Adjust weights |
| ICP refresh | Quarterly | Disqualifiers expand? New industries? |
| After 100 sends | — | `C-fit` leads that would have replied? Loosen/tighten scoring |

---

## 5. Open Questions

| # | Question | Blocks |
|---|----------|--------|
| 1 | Real numbers for product.md: how many devices cleared, actual turnaround weeks? | Section 2.1 — LLM quality depends on real proof points |
| 2 | Do we parse `device_type`/`launch_timing` from `reason`, or ask OpenOutreach to output structured fields? | Section 2.6 tag mapping + n8n spec |
| 3 | B-fit shorter sequence — confirmed 3 emails? | Section 2.7 |
| 4 | Suppression check against SKMC client CRM — where does client list live? | Disqualifier #6 enforcement |
