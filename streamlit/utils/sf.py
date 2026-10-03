"""
Every Snowflake call the app makes.

Nothing here is simulated. Reads hit CANONICAL / ENGINE / CONFIG / RAW directly;
writes and AI go through the APP procedures. Parameters are bound rather than
interpolated, which matters because transcripts contain quotes and apostrophes.
"""
import json

import streamlit as st
from snowflake.snowpark.context import get_active_session

DB = "CUSTOMER_360_DB"


def session():
    return get_active_session()


# ── helpers ──────────────────────────────────────────────────────────────────
def _lit(v):
    """Single-quoted SQL literal with quotes escaped."""
    return "'" + str(v).replace("'", "''") + "'"


def _df(sql, params=None):
    return session().sql(sql, params=params).to_pandas()


def _scalar(sql, params=None):
    rows = session().sql(sql, params=params).collect()
    return rows[0][0] if rows else None


def _obj(sql, params=None):
    """Procedures declared RETURNS OBJECT come back as a JSON string."""
    raw = _scalar(sql, params)
    if raw is None:
        return {}
    return json.loads(raw) if isinstance(raw, str) else raw


# ── reference data (cached: it changes only when an analyst edits config) ─────
@st.cache_data(ttl=120, show_spinner=False)
def customers():
    return _df(f"""
        SELECT c.customer_id, c.full_name, c.domain,
               COALESCE(c.segment,'—') AS segment,
               COALESCE(c.region,'—')  AS region,
               c.credit_score,
               rv.relationship_value,
               cs.state_id, cs.state_name, cs.severity, cs.computed_score,
               ca.assigned_user, ca.assigned_team
        FROM {DB}.CANONICAL.CUSTOMER c
        LEFT JOIN {DB}.APP.V_RELATIONSHIP_VALUE rv
               ON rv.customer_id = c.customer_id AND rv.domain = c.domain
        LEFT JOIN {DB}.ENGINE.CUSTOMER_STATE cs
               ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
        LEFT JOIN {DB}.CONFIG.CUSTOMER_ASSIGNMENT ca
               ON ca.customer_id = c.customer_id AND ca.domain = c.domain
        ORDER BY cs.severity DESC NULLS LAST, rv.relationship_value DESC NULLS LAST
    """)


@st.cache_data(ttl=300, show_spinner=False)
def signal_definitions(domain):
    return _df(f"""
        SELECT signal_id, signal_name, signal_type, extraction_method,
               extraction_prompt, source_table, weight
        FROM {DB}.CONFIG.SIGNAL_DEFINITION
        WHERE domain_id = ? AND active = TRUE ORDER BY weight DESC
    """, [domain])


@st.cache_data(ttl=300, show_spinner=False)
def state_rules(domain):
    return _df(f"""
        SELECT rule_id, target_state_id, priority, rule_expression, description
        FROM {DB}.CONFIG.STATE_RULE
        WHERE domain_id = ? AND active = TRUE ORDER BY priority DESC
    """, [domain])


@st.cache_data(ttl=300, show_spinner=False)
def personas():
    return _df(f"""
        SELECT up.persona_id, up.persona_name, up.data_scope_type, up.can_approve,
               up.can_configure, up.max_approval_value AS config_limit,
               pl.max_approval_inr AS effective_limit, pl.note
        FROM {DB}.CONFIG.USER_PERSONA up
        JOIN {DB}.APP.PERSONA_LIMIT pl ON pl.persona_id = up.persona_id
        ORDER BY pl.max_approval_inr
    """)


@st.cache_data(ttl=300, show_spinner=False)
def scoring_weights():
    return _df(f"SELECT * FROM {DB}.APP.V_SCORING ORDER BY domain_id, persona")


@st.cache_data(ttl=60, show_spinner=False)
def effectiveness(domain=None):
    sql = f"""
        SELECT * FROM {DB}.APP.V_ACTION_EFFECTIVENESS
        {"WHERE domain_id = ?" if domain else ""}
        ORDER BY success_rate DESC
    """
    return _df(sql, [domain] if domain else None)


# ── per-customer reads ───────────────────────────────────────────────────────
def customer(cid):
    df = customers()
    hit = df[df["CUSTOMER_ID"] == cid]
    return None if hit.empty else hit.iloc[0]


def signals(cid, resolved_only=False):
    view = "APP.V_SIGNAL_RESOLVED" if resolved_only else "ENGINE.SIGNAL"
    return _df(f"""
        SELECT s.signal_name, s.signal_value, s.numeric_value, s.confidence,
               s.evidence_ref, s.extracted_at, e.quote, e.model
        FROM {DB}.{view} s
        LEFT JOIN {DB}.APP.SIGNAL_EVIDENCE e
               ON e.signal_instance_id = s.signal_instance_id
        WHERE s.customer_id = ?
        ORDER BY s.signal_name, s.extracted_at DESC
    """, [cid]) if not resolved_only else _df(f"""
        SELECT s.signal_name, s.signal_value, s.numeric_value, s.confidence,
               s.evidence_ref, s.extracted_at
        FROM {DB}.{view} s WHERE s.customer_id = ? ORDER BY s.signal_name
    """, [cid])


def resolved_wide(cid):
    return _df(f"SELECT * FROM {DB}.APP.V_SIGNAL_WIDE WHERE customer_id = ?", [cid])


def products(cid, domain):
    if domain == "insurance":
        return _df(f"""
            SELECT policy_id AS id, policy_type AS type, policy_status AS status,
                   premium_amount AS premium, coverage_amount AS cover, renewal_date AS renews
            FROM {DB}.RAW.INSURANCE_POLICIES WHERE customer_id = ? ORDER BY policy_id
        """, [cid])
    return _df(f"""
        SELECT loan_id AS id, loan_type AS type, loan_status AS status,
               outstanding_balance AS outstanding, monthly_payment AS emi, maturity_date AS matures
        FROM {DB}.RAW.LENDING_LOANS WHERE customer_id = ? ORDER BY loan_id
    """, [cid])


def claims(cid):
    return _df(f"""
        SELECT claim_id, claim_type, claim_status, claim_amount, filed_date,
               DATEDIFF(day, filed_date, CURRENT_DATE()) AS age_days
        FROM {DB}.RAW.INSURANCE_CLAIMS WHERE customer_id = ? ORDER BY filed_date DESC
    """, [cid])


def transcripts(cid, domain, limit=6):
    t = "INSURANCE_CALL_TRANSCRIPTS" if domain == "insurance" else "LENDING_CALL_TRANSCRIPTS"
    return _df(f"""
        SELECT transcript_id, transcript_text, call_date
        FROM {DB}.RAW.{t} WHERE customer_id = ? ORDER BY call_date DESC LIMIT {int(limit)}
    """, [cid])


def state_history(cid):
    return _df(f"""
        SELECT state_name, severity, computed_score, effective_from, effective_to, is_current
        FROM {DB}.ENGINE.CUSTOMER_STATE WHERE customer_id = ?
        ORDER BY effective_from DESC LIMIT 20
    """, [cid])


def summary(cid):
    return _scalar(f"""
        SELECT summary_text FROM {DB}.ENGINE.INTERACTION_SUMMARY
        WHERE customer_id = ? ORDER BY generated_at DESC LIMIT 1
    """, [cid])


def queue(persona_scope, assigned_user="rm1", team="team_alpha"):
    """What needs attention — the rule (severity >= 2 + scope) lives in APP.DECISION_QUEUE."""
    return _df(f"""SELECT * FROM TABLE({DB}.APP.DECISION_QUEUE(?, ?, ?))""",
               [persona_scope, assigned_user or "", team or ""])


def pending_approvals(persona_scope, persona, assigned_user="rm1", team="team_alpha"):
    """Every customer in scope with a top candidate that needs sign-off — Snowpark proc."""
    return _df(f"""CALL {DB}.APP.PENDING_APPROVALS(?, ?, ?, ?)""",
               [persona_scope, assigned_user or "", team or "", persona])


@st.cache_data(ttl=60, show_spinner=False)
def trust_flags():
    """Conflicting-evidence / thin-sample flags, computed for every customer."""
    return _df(f"SELECT * FROM {DB}.APP.V_TRUST_FLAGS")


@st.cache_data(ttl=120, show_spinner=False)
def ownership_gap():
    """How many customers have no owner — they appear in no scoped queue."""
    return _df(f"""
        SELECT COUNT(*) AS total, COUNT(ca.customer_id) AS owned
        FROM {DB}.CANONICAL.CUSTOMER c
        LEFT JOIN {DB}.CONFIG.CUSTOMER_ASSIGNMENT ca
               ON ca.customer_id = c.customer_id AND ca.domain = c.domain
    """).iloc[0]


def portfolio():
    return _df(f"""
        SELECT cs.domain, cs.state_name, cs.severity, COUNT(*) AS customers,
               SUM(rv.relationship_value) AS total_value
        FROM {DB}.ENGINE.CUSTOMER_STATE cs
        JOIN {DB}.APP.V_RELATIONSHIP_VALUE rv
             ON rv.customer_id = cs.customer_id AND rv.domain = cs.domain
        WHERE cs.is_current = TRUE
        GROUP BY cs.domain, cs.state_name, cs.severity
        ORDER BY cs.domain, cs.severity DESC
    """)


def recent_activity(limit=25):
    return _df(f"""
        SELECT e.executed_at, e.customer_id, c.full_name, e.action_name,
               e.execution_type, e.executed_by, o.outcome_type, o.success
        FROM {DB}.ENGINE.ACTION_EXECUTION e
        JOIN {DB}.CANONICAL.CUSTOMER c ON c.customer_id = e.customer_id
        LEFT JOIN {DB}.ENGINE.ACTION_OUTCOME o ON o.execution_id = e.execution_id
        ORDER BY e.executed_at DESC LIMIT {int(limit)}
    """)


def pipeline_health():
    scored = _scalar(f"SELECT COUNT(*) FROM {DB}.ENGINE.CUSTOMER_STATE WHERE is_current = TRUE")
    total = _scalar(f"SELECT COUNT(*) FROM {DB}.CANONICAL.CUSTOMER")
    return {"scored": scored, "total": total}


# ── procedure calls: the write and AI paths ───────────────────────────────────
def start_run(cid, persona, scenario):
    return _scalar(f"CALL {DB}.APP.START_RUN(?, ?, ?)", [cid, persona, scenario])


def generate_transcript(cid, situation, intensity, channel):
    return _scalar(f"CALL {DB}.APP.GENERATE_TRANSCRIPT(?, ?, ?, ?)",
                   [cid, situation, intensity, channel])


def inject_event(cid, transcript, run_id):
    return _scalar(f"CALL {DB}.APP.INJECT_EVENT(?, ?, ?)", [cid, transcript, run_id])


def extract_signals(cid, transcript_id, run_id):
    """Run the extraction, then read the rows back through a table function."""
    session().sql(f"CALL {DB}.APP.EXTRACT_SIGNALS_FOR(?, ?, ?)",
                  params=[cid, transcript_id, run_id]).collect()
    return _df(f"""SELECT * FROM TABLE({DB}.APP.SIGNALS_FOR_TRANSCRIPT(
                       {_lit(cid)}, {_lit(transcript_id)}))""")


def compute_state(cid, run_id):
    """
    Recompute state and report what moved. Read before and after around the
    procedure rather than trusting its return shape.
    """
    before_df = _df(f"""SELECT state_name, severity FROM {DB}.ENGINE.CUSTOMER_STATE
                        WHERE customer_id = ? AND is_current = TRUE""", [cid])
    before = before_df.iloc[0]["STATE_NAME"] if len(before_df) else None
    before_sev = int(before_df.iloc[0]["SEVERITY"]) if len(before_df) else 0
    session().sql(f"CALL {DB}.APP.COMPUTE_STATE_FOR(?, ?)",
                  params=[cid, run_id]).collect()
    row = _df(f"""SELECT state_name, severity, computed_score
                  FROM {DB}.ENGINE.CUSTOMER_STATE
                  WHERE customer_id = ? AND is_current = TRUE""", [cid]).iloc[0]
    return {"previous": before, "previous_severity": before_sev, "new": row["STATE_NAME"],
            "severity": int(row["SEVERITY"]), "score": float(row["COMPUTED_SCORE"]),
            "changed": before != row["STATE_NAME"]}


def summarize(cid, run_id):
    return _scalar(f"CALL {DB}.APP.SUMMARIZE_CUSTOMER(?, ?)", [cid, run_id])


def recommend(cid, persona, offer=0):
    return _df(f"""SELECT * FROM TABLE({DB}.APP.RECOMMEND(
                       {_lit(cid)}, {_lit(persona)}, {float(offer)}::FLOAT))""")


def policy_eval(cid, action_id, persona, offer=0):
    return _df(f"""SELECT * FROM TABLE({DB}.APP.POLICY_CHECK_TABLE(
                       {_lit(action_id)}, {_lit(persona)}, {float(offer)}::FLOAT))""")


def authority(action_id, persona, offer=0):
    return _obj(f"""SELECT {DB}.APP.AUTHORITY_CHECK(
                        {_lit(action_id)}, {_lit(persona)}, {float(offer)}::FLOAT)""")


def execute_action(cid, action_id, persona, offer, notes, run_id):
    return _obj(f"CALL {DB}.APP.EXECUTE_ACTION(?, ?, ?, ?, ?, ?)",
                [cid, action_id, persona, float(offer), notes, run_id])


def call_brief(cid, action_id, offer=0):
    return _scalar(f"CALL {DB}.APP.CALL_BRIEF(?, ?, ?)", [cid, action_id, float(offer)])


def simulate_call(cid, action_id, offer, tone):
    return _obj(f"CALL {DB}.APP.SIMULATE_CALL(?, ?, ?, ?)",
                [cid, action_id, float(offer), tone])


def record_outcome(cid, action_id, outcome, state_after, run_id):
    return _obj(f"CALL {DB}.APP.RECORD_OUTCOME(?, ?, ?, ?, ?)",
                [cid, action_id, outcome, state_after, run_id])


def undo_run(run_id):
    return _scalar(f"CALL {DB}.APP.UNDO_RUN(?)", [run_id])


def open_runs():
    return _df(f"""
        SELECT run_id, customer_id, persona, scenario, started_at
        FROM {DB}.APP.RUN_LOG WHERE status = 'OPEN' ORDER BY started_at DESC
    """)


def run_artifacts(run_id):
    return _df(f"""
        SELECT object_type, object_id, detail, created_at
        FROM {DB}.APP.RUN_ARTIFACT WHERE run_id = ? ORDER BY created_at
    """, [run_id])


def search_interactions(query, limit=5):
    """
    Cortex Search over the interaction corpus.

    The search payload is a JSON *string*, so a bind placeholder inside it is
    never substituted — the query has to be embedded, with quotes escaped.
    """
    payload = json.dumps({
        "query": query,
        "columns": ["CUSTOMER_NAME", "SUBJECT", "CONTENT", "CUSTOMER_ID"],
        "limit": int(limit),
    })
    sql = f"""
        SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            '{DB}.APP.INTERACTION_SEARCH',
            '{payload.replace("'", "''")}')) AS r
    """
    try:
        raw = _scalar(sql)
        parsed = json.loads(raw) if isinstance(raw, str) else raw
        return parsed.get("results", [])
    except Exception as exc:
        return [{"error": str(exc)}]


def clear_caches():
    st.cache_data.clear()


# ── profile, timeline and the new sources ────────────────────────────────────
def profile(cid):
    """One row with everything the engine reasons over for this customer."""
    df = _df(f"SELECT * FROM {DB}.APP.V_CUSTOMER_PROFILE WHERE customer_id = ?", [cid])
    return None if df.empty else df.iloc[0]


def why_this_state(cid):
    """Every signal behind the current state, with what each one contributes."""
    return _df(f"SELECT * FROM TABLE({DB}.APP.WHY_THIS_STATE({_lit(cid)}))")


def all_signals(cid):
    return _df(f"""
        SELECT signal_name, signal_value, numeric_value, confidence, evidence_ref, origin
        FROM {DB}.APP.V_ALL_SIGNALS WHERE customer_id = ?
        ORDER BY origin, signal_name
    """, [cid])


def tickets(cid, limit=40):
    return _df(f"""
        SELECT ticket_id, opened_at, channel, category, priority, subject, status,
               sla_target_hours, sla_breached, reopen_count, csat_score,
               linked_claim_id, resolved_at,
               DATEDIFF(hour, opened_at, COALESCE(resolved_at, CURRENT_TIMESTAMP())) AS age_hours
        FROM {DB}.RAW.SUPPORT_TICKET WHERE customer_id = ?
        ORDER BY opened_at DESC LIMIT {int(limit)}
    """, [cid])


def email_threads(cid):
    return _df(f"""
        SELECT ticket_id, thread_position, direction, from_address, to_address,
               subject, body, sent_at
        FROM {DB}.RAW.EMAIL_MESSAGE WHERE customer_id = ?
        ORDER BY sent_at DESC, thread_position
    """, [cid])


def policy_versions(cid):
    return _df(f"""
        SELECT policy_id, version_no, effective_from, change_type, renewal_status,
               days_late, sum_insured, premium, no_claim_bonus_pct, riders
        FROM {DB}.RAW.POLICY_VERSION WHERE customer_id = ?
        ORDER BY policy_id, version_no
    """, [cid])


def grievances(cid):
    return _df(f"""
        SELECT grievance_id, igms_token, filed_date, category, status,
               escalated_to_ombudsman, description
        FROM {DB}.RAW.GRIEVANCE WHERE customer_id = ? ORDER BY filed_date DESC
    """, [cid])


def portability(cid):
    return _df(f"""
        SELECT request_id, requested_date, target_insurer, current_premium,
               quoted_premium, stage, status, notes
        FROM {DB}.RAW.PORTABILITY_REQUEST WHERE customer_id = ? ORDER BY requested_date DESC
    """, [cid])


def timeline(cid, limit=60):
    """Every dated record for this customer, one stream, newest first."""
    return _df(f"""
        SELECT * FROM TABLE({DB}.APP.CUSTOMER_TIMELINE({_lit(cid)}))
        ORDER BY when_at DESC LIMIT {int(limit)}
    """)


# ── signal discovery ──────────────────────────────────────────────────────────
def discovery_candidates(status="NEW"):
    return _df(f"""
        SELECT candidate_id, domain_id, signal_name, category, extraction_method,
               extraction_prompt, source_table, source_column, rationale, priority,
               trigger_rate, discovered_at
        FROM {DB}.APP.SIGNAL_CANDIDATE WHERE status = ?
        ORDER BY CASE priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, signal_name
    """, [status])


def discovery_latest_run():
    df = _df(f"""
        SELECT run_id, run_at, tables_scanned, candidates_found, ai_summary
        FROM {DB}.APP.DISCOVERY_RUN ORDER BY run_at DESC LIMIT 1
    """)
    return None if df.empty else df.iloc[0]


def run_discovery():
    return _scalar(f"CALL {DB}.APP.DISCOVER_SIGNALS()")


def promote_candidate(candidate_id):
    return _scalar(f"CALL {DB}.APP.PROMOTE_SIGNAL_CANDIDATE(?)", [candidate_id])


def dismiss_candidate(candidate_id):
    return _scalar(f"CALL {DB}.APP.DISMISS_SIGNAL_CANDIDATE(?)", [candidate_id])


def signals_by_category(domain=None):
    sql = f"""
        SELECT signal_id, domain_id, signal_name, category, extraction_method,
               source_table, weight
        FROM {DB}.CONFIG.SIGNAL_DEFINITION
        WHERE active = TRUE {"AND domain_id = ?" if domain else ""}
        ORDER BY category, domain_id, signal_name
    """
    return _df(sql, [domain] if domain else None)
