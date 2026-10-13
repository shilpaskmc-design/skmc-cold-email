# SKMC Global — Target Market Definition

> **File purpose:** Direct input for OpenOutreach (`--target-docs target.md`).
> **Status:** Ready-to-use. Bracketed values are defaults — adjust from first-run data.

## Who qualifies

Companies (any HQ country) that **manufacture or brand-owner** physical
devices containing Bluetooth / WiFi / Zigbee / any RF transmitter, and are
**bringing them to the Indian market** — first entry or a new SKU in an
existing India operation.

## Firmographics

| Attribute | Qualify if | Disqualify if |
|-----------|-----------|---------------|
| Industry | IoT, MedTech/HealthTech, Consumer Electronics, Smart Home, Wearables, Telematics/Asset Tracking, POS/FinTech hardware, Drones | No RF product line; pure software; distributors/resellers; testing labs; competing consultancies |
| Company size | 10–500 employees | <10 with no funding AND no launch signal (too early); >500 employees (in-house compliance likely) |
| Stage | Seed to Series B funded, OR profitable bootstrapped | Pre-product idea stage (no physical device) |
| Geography | Any HQ — the qualifying act is selling into India | Products never intended for India |
| Device type | BT/WiFi/RF consumer or industrial device | Non-radio devices (wired-only, passive) |

## Trigger signals (any ONE = warm lead)

| # | Signal | Detection hint | Weight |
|---|--------|----------------|--------|
| T1 | Announced India launch / India market entry | Press releases, LinkedIn posts, funding announcements, "launching in India" on website | HIGH |
| T2 | Recently received FDA / CE / FCC approval for the device | News, regulatory pages — India is typically the next market after these | HIGH |
| T3 | Hiring for Regulatory Affairs / Compliance Manager / Certification Engineer | Job postings (LinkedIn, careers page) — strongest practical signal: they have the pain AND the budget line | HIGH |
| T4 | BLE/WiFi product on crowdfunding (Indiegogo/Kickstarter) or own site with India shipping/launch hint | Product pages | MEDIUM |
| T5 | Existing India operations (India entity, India office) + new device SKU pipeline | Apollo org data | MEDIUM |
| T6 | Previously failed/delayed WPC attempt (mentioned in blogs, forums) | Long-tail signal | LOW |

## Decision makers (who we email)

| Priority | Titles | Why |
|----------|--------|-----|
| P1 | Founder, CEO, Co-founder, Managing Director | Own certification decisions directly at this company size |
| P2 | VP Product, Head of Hardware, CTO, Engineering Director | Own the launch timeline |
| P3 | Regulatory Affairs Manager, Compliance Lead, Certification Manager | Strongest pain signal — their role exists because of this exact problem |
| NEVER | HR, Sales, Marketing, Support, Finance | Zero decision authority; wasted send |

## Disqualifiers (hard NO)

1. **No RF product** — device has no Bluetooth/WiFi/Zigbee/cellular radio
2. **In-house regulatory team > 2 people** — they don't outsource this
3. **Not a manufacturer/brand owner** — distributor, reseller, testing lab,
   or a competing compliance consultancy
4. **Device out of WPC ETA scope** — non-radio products (WPC handles RF
   equipment approval only)
5. **Company defunct/insolvent** — check company status
6. **Already an SKMC client** — check client/suppression list before export
7. **Telecom service operators** (need service licenses, not equipment ETA)

## Anti-patterns (examples for the LLM)

**GOOD LEAD:**
"MedTech Solutions — 45 employees, Series A ($5M), Singapore HQ.
FDA-cleared BLE blood pressure monitor launching in India Q3.
Currently hiring a Regulatory Affairs Manager. Decision maker: CEO Priya Mehta."
→ A-pass (device ✅, size ✅, stage ✅) + T2 + T3 + P1 decision maker.

**GOOD LEAD:**
"SmartHome Devices Pvt Ltd — 120 employees, profitable bootstrapped,
Bengaluru. Existing India operations; launching a WiFi thermostat line
next quarter. Decision maker: VP Product."
→ A-pass + T5 + P2.

**REJECT 1:**
"Global Electronics Corp — 15,000 employees, Fortune 500. In-house
regulatory team of 12 people. Launching Bluetooth speaker in India."
→ Size + in-house team = D2. They don't outsource.

**REJECT 2:**
"CircuitHub Distribution — authorized reseller of IoT modules."
→ D3 — reseller, not manufacturer. The manufacturer is our client, not them.

**REJECT 3:**
"CleanWater Tech — IoT water-quality monitors. No radio connectivity
(wired sensor mesh)."
→ D1 — no RF, WPC ETA irrelevant.

## Enrichment priority (what Apollo must add)

| Priority | Field | Use |
|----------|-------|-----|
| Must | email (already bought via OpenOutreach), first_name, company, title | Sending |
| Must | tech_stack | Personalization: reference their radio stack (BLE, ESP32, nRF) |
| Must | funding_round / total_funding | Trigger verification + message tone |
| Should | linkedin_url | Vetting + social touch |
| Should | employee_count | Post-scrape ICP validation |
| Nice | company_revenue | Deep personalization (Email 3+) |
| Nice | job_postings (RA/compliance roles) | T3 verification |

## Sourcing note for OpenOutreach

Search emphasis: US/EU/Israel/Singapore/Korea device startups (most India
entries come from these), plus Indian IoT manufacturers. Keywords that
worked historically: "FDA cleared", "CE marked", "Bluetooth", "IoT",
"wearable", "medical device", "smart home". Avoid keyword-stuffed titles
like "Regulatory consultant" — that's a competitor, not a client.
