# Bounds — what any change is allowed to do

Enforced by `STUDIO.VALIDATE_RUN` (and therefore by `SIMULATE` and `RELEASE_RUN`).
A run with any FAIL cannot be released. WARN is shown at the gate and needs the
expert to accept it.

| Id | Bound | Level | Why |
|---|---|---|---|
| B0 | Pack is complete: one domain, ≥1 candidate, ≥1 rule | FAIL | nothing half-built ships |
| B1 | Only GENERIC packs change through a release; LEGACY engines are tuned in the app | FAIL | churn scoring and approval ceilings are bespoke |
| B2 | Every rule reads a registered signal | FAIL | no rule on a signal that doesn't exist |
| B3 | Every rule value occurs in the data | WARN | a dead rule is usually a typo or a label nobody has |
| B4 | Rule weights within [0.05, 2.0] | FAIL | one rule can't dominate a pack |
| B5 | Every offer exists in the action/product catalog | FAIL | packs can't invent products; raise a catalog request |
| B6 | GROW packs carry ≥1 guardrail | FAIL | no upsell pack without a "don't" |
| B7 | Every guardrail is cited | FAIL | compliance can trace every rule to its source |
| B8 | No live guardrail is removed by a MODIFY | FAIL | guardrails only get stricter through this path |
| B9 | Every new signal is materialized with coverage > 0 | FAIL | no rule on an empty signal |

## Simulation invariants (must all be 0)

| Invariant | Meaning |
|---|---|
| offer_to_guardrailed_customer | nobody matching a guardrail is offered anything |
| offer_to_high_risk_customer | nobody at HIGH/CRITICAL churn risk is upsold (retention first) |
| ranking_gaps | every customer's offers are ranked 1..n |
| non_deterministic | running the engine twice gives the identical result |

## Signal quality gate (AI_LABEL)

Precision is measured by an independent AI pass over every positive.
Pass when the **lower bound of the Wilson 95% interval ≥ 0.70**. Below that, the
signal builder tightens the label definitions (it may iterate twice on its own)
and shows the before/after numbers.

## Priority between packs

`PROTECT > RETAIN > SERVICE > GROW`. Built into the engine: a SIGNAL_MATCHED pack
never offers anything to a customer at HIGH/CRITICAL churn risk. Conflicts with
service recovery are reported by the simulator; the usual fix is a guardrail on
the service signal (`claim_friction`, `service_failure`, `csat_low`).
