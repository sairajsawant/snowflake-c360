# Playbook · life_event_upgrade · run UC-20261005-2055

## Offers (catalog only, catalog fit copied)
| Candidate | Catalog ref | Fit |
|---|---|---|
| leu_maternity — Maternity Cover Add-on | ins_prod_maternity | age 21–45 |
| leu_supertopup — Super Top-up Health Cover | ins_prod_supertopup | age 18–65 |
| leu_senior — Senior Citizen Wellness Plan | ins_prod_senior | Senior Citizen, age 60–80 |

## Rules (weights within 0.05–2.0)
| Offer | Signal = value | Weight | Role |
|---|---|---|---|
| Maternity | life_event = pregnancy_or_newborn | 1.0 | primary trigger |
| Maternity | product_interest = maternity_cover | 0.5 | corroboration |
| Super top-up | cover_gap = HIGH | 1.0 | primary trigger |
| Super top-up | cover_gap = MEDIUM | 0.5 | weaker trigger |
| Super top-up | life_event = pregnancy_or_newborn | 0.4 | a bigger family needs more cover |
| Super top-up | product_interest = super_topup_cover | 0.5 | corroboration |
| Super top-up | renewal_proximity = HIGH | 0.2 | timing nudge |
| Senior plan | product_interest = senior_wellness | 1.0 | primary trigger |
| Senior plan | cover_gap = HIGH | 0.4 | a senior on low cover |

No marriage rule: the label exists but no customer has it today (would be a dead rule).

## Guardrails (each cited) — customer is offered nothing if any matches
| Id | Signal = value | Reason | Citation |
|---|---|---|---|
| leu_g1 | grievance_filed = HIGH | open grievance — resolve first | IRDAI (Protection of Policyholders' Interests) Regulations, 2017 — grievance redressal |
| leu_g2 | claim_friction = HIGH | claim delayed or rejected — service recovery first | Platform priority policy (protect > retain > service > grow) |
| leu_g3 | portability_intent = HIGH | porting — retention owns it | IRDAI health insurance portability provisions |
| leu_g4 | csat_low = HIGH | recent poor service — no selling | Internal needs-based selling policy |

Plus, built into the engine: nobody at HIGH/CRITICAL churn risk is offered anything.

## Priority
GROW: below retention and service recovery.

## Catalog requests (not invented as offers)
1. **Add a member to the family floater** (new spouse or newborn as a dependant) — endorsement product.
2. **Parents' health cover for a non-senior policyholder** — the Senior Citizen Wellness Plan only fits policyholders aged 60+.

Bounds: B0–B9 all PASS.
