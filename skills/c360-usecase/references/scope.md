# Scope — what this studio builds, and where everything else goes

## Builds (in scope)

| Request shape | Mode | Example |
|---|---|---|
| Customer-level offer/action chosen from the catalog | NEW pack | "Offer the right cover upgrade when a policyholder's life changes" |
| A new signal from records (SQL) or from what customers said (AI_LABEL) | part of a pack | "flag policyholders whose sum insured no longer fits" |
| Change rules, weights, candidates or add guardrails to a live GENERIC pack | MODIFY | "only offer super top-up when the cover gap is HIGH" |

## Routes elsewhere (record, explain in two lines, offer the in-scope alternative)

| Request | Why not here | Offer instead |
|---|---|---|
| Auto-approve / adjudicate claims | not a customer offer decision; regulated, high-risk | a service-recovery guardrail or a claims-triage view for human review |
| Credit, underwriting or pricing decisions | regulated pricing/credit, needs model governance | signals that inform the human underwriter |
| Tune `churn_retention` or `personalization` | LEGACY engines with bespoke scoring | Analyst / Domain Expert edits `CONFIG.SCORING_CONFIG` in the app |
| Forecast volumes (renewals, lapses) | portfolio time series, not a pack | `SNOWFLAKE.ML.FORECAST` (renewals due are computed from policy dates, not forecast) |
| Train a propensity model | needs ≥200 labelled outcomes; packs collect them via `RECORD_DECISION_OUTCOME` | rules now, `SNOWFLAKE.ML.CLASSIFICATION` later |
| Onboard a new raw source | needs mapping into CANONICAL first | `$c360-signal-onboarding` once the source is mapped |
| Message customers, change consent | outside decisioning | — |

When in doubt, read `STUDIO.CAPABILITY` and recommend the simplest tool that
meets the success metric.
