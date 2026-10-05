# Simulation · life_event_upgrade · run UC-20261005-2055

Whole book (510 customers) through `APP.PACK_ENGINE`, the engine production serves from.

## Round 1 (designer's first playbook)
278 matched → 160 reached, 118 held back, 0 violations — but **3 conflicts with service_recovery**: customers with a pending fee-waiver for an unresolved service issue (`service_failure = MEDIUM`, `ticket_reopen = MEDIUM`). Sent back to the designer: guardrail both service signals at HIGH and MEDIUM (service > grow).

## Round 2 (final)

| Reach | |
|---|---|
| Customers matched | 278 |
| **Reached** | **157** |
| Held back | 121 |

| Held back because | Customers |
|---|---|
| Customer is in CRITICAL_CHURN_RISK — lead with retention before any upsell | 30 |
| Customer is in HIGH_CHURN_RISK — lead with retention before any upsell | 65 |
| Guardrail: Claim delayed or rejected — service recovery comes first | 10 |
| Guardrail: Owed a fix after an SLA breach — service recovery first | 11 |
| Guardrail: Recent poor service rating — no selling until recovered | 3 |
| Guardrail: Reopened ticket — service recovery first | 2 |

| Top offer | Customers |
|---|---|
| Maternity Cover Add-on | 13 |
| Senior Citizen Wellness Plan | 31 |
| Super Top-up Health Cover | 113 |

| Invariant (must be 0) | Value |
|---|---|
| non_deterministic | 0 |
| offer_to_guardrailed_customer | 0 |
| offer_to_high_risk_customer | 0 |
| ranking_gaps | 0 |

Conflicts with live packs: service_recovery = 0

Bounds: B0 PASS, B1 PASS, B2 PASS, B3 PASS, B4 PASS, B5 PASS, B6 PASS, B7 PASS, B8 PASS, B9 PASS

## Examples

| Customer | Offer | Because |
|---|---|---|
| INS-2380 Nandini Qureshi | Super Top-up Health Cover | cover_gap=HIGH, product_interest=super_topup_cover |
| INS-2001 Nikhil Chowdhury | Maternity Cover Add-on | life_event=pregnancy_or_newborn, product_interest=maternity_cover |
| INS-2009 Karthik Patel | Senior Citizen Wellness Plan | cover_gap=HIGH, product_interest=senior_wellness |

## Reach by relationship manager
Every RM book gets offers; rm1 (team_alpha, the demo persona) gets 3: INS-1009 Rohit Joshi, INS-1015, INS-1007 — all Super Top-up.

Artifact hash: `2ea6dcefecf6615ad1c368d926f93208`

**READY FOR G3** — 0 violations, 0 failed bounds, 0 conflicts.
