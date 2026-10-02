"""
Every Snowflake call the v2 app makes.

Nothing here is simulated. Reads hit CANONICAL / ENGINE / CONFIG / RAW directly;
writes and AI go through the APP_V2 procedures. Parameters are bound rather than
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
        LEFT JOIN {DB}.APP_V2.V_RELATIONSHIP_VALUE rv
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
def live_signal_names():
    """Which configured signals actually produce rows — several still do not."""
    return set(_df(f"SELECT DISTINCT signal_name FROM {DB}.ENGINE.SIGNAL")["SIGNAL_NAME"])


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
        JOIN {DB}.APP_V2.PERSONA_LIMIT pl ON pl.persona_id = up.persona_id
        ORDER BY pl.max_approval_inr
    """)


@st.cache_data(ttl=300, show_spinner=False)
def scoring_weights():
    return _df(f"SELECT * FROM {DB}.APP_V2.V_SCORING ORDER BY domain_id, persona")


@st.cache_data(ttl=60, show_spinner=False)
def effectiveness(domain=None):
    sql = f"""
        SELECT ae.action_id, ad.action_name, ae.state_id, sd.state_name, ae.domain_id,
               ae.success_count, ae.total_count, ae.success_rate, ae.avg_uplift, ae.confidence
        FROM {DB}.ENGINE.ACTION_EFFECTIVENESS ae
        JOIN {DB}.CONFIG.ACTION_DEFINITION ad ON ad.action_id = ae.action_id
        JOIN {DB}.CONFIG.STATE_DEFINITION  sd ON sd.state_id  = ae.state_id
        {"WHERE ae.domain_id = ?" if domain else ""}
        ORDER BY ae.success_rate DESC
    """
    return _df(sql, [domain] if domain else None)


# ── per-customer reads ───────────────────────────────────────────────────────
def customer(cid):
    df = customers()
    hit = df[df["CUSTOMER_ID"] == cid]
    return None if hit.empty else hit.iloc[0]


def signals(cid, resolved_only=False):
    view = "APP_V2.V_SIGNAL_RESOLVED" if resolved_only else "ENGINE.SIGNAL"
    return _df(f"""
        SELECT s.signal_name, s.signal_value, s.numeric_value, s.confidence,
               s.evidence_ref, s.extracted_at, e.quote, e.model
        FROM {DB}.{view} s
        LEFT JOIN {DB}.APP_V2.SIGNAL_EVIDENCE e
               ON e.signal_instance_id = s.signal_instance_id
        WHERE s.customer_id = ?
        ORDER BY s.signal_name, s.extracted_at DESC
    """, [cid]) if not resolved_only else _df(f"""
        SELECT s.signal_name, s.signal_value, s.numeric_value, s.confidence,
               s.evidence_ref, s.extracted_at
        FROM {DB}.{view} s WHERE s.customer_id = ? ORDER BY s.signal_name
    """, [cid])


def resolved_wide(cid):
    return _df(f"SELECT * FROM {DB}.APP_V2.V_SIGNAL_WIDE WHERE customer_id = ?", [cid])


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


def queue(persona_scope, assigned_user="agent_rm_1", team="team_alpha"):
    where = "WHERE cs.is_current = TRUE AND cs.severity >= 2"
    params = []
    if persona_scope == "ASSIGNED":
        where += " AND ca.assigned_user = ?"
        params.append(assigned_user)
    elif persona_scope == "TEAM":
        where += " AND ca.assigned_team = ?"
        params.append(team)
    return _df(f"""
        SELECT c.customer_id, c.full_name, c.domain, COALESCE(c.segment,'—') AS segment,
               cs.state_name, cs.severity, rv.relationship_value,
               ca.assigned_user, ca.assigned_team
        FROM {DB}.CANONICAL.CUSTOMER c
        JOIN {DB}.ENGINE.CUSTOMER_STATE cs
             ON cs.customer_id = c.customer_id
        LEFT JOIN {DB}.APP_V2.V_RELATIONSHIP_VALUE rv
             ON rv.customer_id = c.customer_id AND rv.domain = c.domain
        LEFT JOIN {DB}.CONFIG.CUSTOMER_ASSIGNMENT ca
             ON ca.customer_id = c.customer_id AND ca.domain = c.domain
        {where}
        ORDER BY cs.severity DESC, rv.relationship_value DESC NULLS LAST
    """, params or None)


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
        JOIN {DB}.APP_V2.V_RELATIONSHIP_VALUE rv
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
    return _scalar(f"CALL {DB}.APP_V2.START_RUN(?, ?, ?)", [cid, persona, scenario])


def generate_transcript(cid, situation, intensity, channel):
    return _scalar(f"CALL {DB}.APP_V2.GENERATE_TRANSCRIPT(?, ?, ?, ?)",
                   [cid, situation, intensity, channel])


def inject_event(cid, transcript, run_id):
    return _scalar(f"CALL {DB}.APP_V2.INJECT_EVENT(?, ?, ?)", [cid, transcript, run_id])


def extract_signals(cid, transcript_id, run_id):
    """Run the extraction, then read the rows back through a table function."""
    session().sql(f"CALL {DB}.APP_V2.EXTRACT_SIGNALS_FOR(?, ?, ?)",
                  params=[cid, transcript_id, run_id]).collect()
    return _df(f"""SELECT * FROM TABLE({DB}.APP_V2.SIGNALS_FOR_TRANSCRIPT(
                       {_lit(cid)}, {_lit(transcript_id)}))""")


def compute_state(cid, run_id):
    """
    Recompute state and report what moved. Read before and after around the
    procedure rather than trusting its return shape.
    """
    before = _scalar(f"""SELECT state_name FROM {DB}.ENGINE.CUSTOMER_STATE
                         WHERE customer_id = ? AND is_current = TRUE""", [cid])
    session().sql(f"CALL {DB}.APP_V2.COMPUTE_STATE_FOR(?, ?)",
                  params=[cid, run_id]).collect()
    row = _df(f"""SELECT state_name, severity, computed_score
                  FROM {DB}.ENGINE.CUSTOMER_STATE
                  WHERE customer_id = ? AND is_current = TRUE""", [cid]).iloc[0]
    return {"previous": before, "new": row["STATE_NAME"],
            "severity": int(row["SEVERITY"]), "score": float(row["COMPUTED_SCORE"]),
            "changed": before != row["STATE_NAME"]}


def summarize(cid, run_id):
    return _scalar(f"CALL {DB}.APP_V2.SUMMARIZE_CUSTOMER(?, ?)", [cid, run_id])


def recommend(cid, persona, offer=0):
    return _df(f"""SELECT * FROM TABLE({DB}.APP_V2.RECOMMEND(
                       {_lit(cid)}, {_lit(persona)}, {float(offer)}::FLOAT))""")


def policy_eval(cid, action_id, persona, offer=0):
    return _df(f"""SELECT * FROM TABLE({DB}.APP_V2.POLICY_CHECK_TABLE(
                       {_lit(action_id)}, {_lit(persona)}, {float(offer)}::FLOAT))""")


def authority(action_id, persona, offer=0):
    return _obj(f"""SELECT {DB}.APP_V2.AUTHORITY_CHECK(
                        {_lit(action_id)}, {_lit(persona)}, {float(offer)}::FLOAT)""")


def execute_action(cid, action_id, persona, offer, notes, run_id):
    return _obj(f"CALL {DB}.APP_V2.EXECUTE_ACTION(?, ?, ?, ?, ?, ?)",
                [cid, action_id, persona, float(offer), notes, run_id])


def call_brief(cid, action_id, offer=0):
    return _scalar(f"CALL {DB}.APP_V2.CALL_BRIEF(?, ?, ?)", [cid, action_id, float(offer)])


def simulate_call(cid, action_id, offer, tone):
    return _obj(f"CALL {DB}.APP_V2.SIMULATE_CALL(?, ?, ?, ?)",
                [cid, action_id, float(offer), tone])


def record_outcome(cid, action_id, outcome, state_after, run_id):
    return _obj(f"CALL {DB}.APP_V2.RECORD_OUTCOME(?, ?, ?, ?, ?)",
                [cid, action_id, outcome, state_after, run_id])


def undo_run(run_id):
    return _scalar(f"CALL {DB}.APP_V2.UNDO_RUN(?)", [run_id])


def open_runs():
    return _df(f"""
        SELECT run_id, customer_id, persona, scenario, started_at
        FROM {DB}.APP_V2.RUN_LOG WHERE status = 'OPEN' ORDER BY started_at DESC
    """)


def run_artifacts(run_id):
    return _df(f"""
        SELECT object_type, object_id, detail, created_at
        FROM {DB}.APP_V2.RUN_ARTIFACT WHERE run_id = ? ORDER BY created_at
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
            '{DB}.APP_V2.INTERACTION_SEARCH_V2',
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
    df = _df(f"SELECT * FROM {DB}.APP_V2.V_CUSTOMER_PROFILE WHERE customer_id = ?", [cid])
    return None if df.empty else df.iloc[0]


def why_this_state(cid):
    """Every signal behind the current state, with what each one contributes."""
    return _df(f"SELECT * FROM TABLE({DB}.APP_V2.WHY_THIS_STATE({_lit(cid)}))")


def all_signals(cid):
    return _df(f"""
        SELECT signal_name, signal_value, numeric_value, confidence, evidence_ref, origin
        FROM {DB}.APP_V2.V_ALL_SIGNALS WHERE customer_id = ?
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
        SELECT * FROM (
            SELECT effective_from::TIMESTAMP_NTZ AS when_at, 'Policy' AS source,
                   change_type AS what,
                   policy_id || ' · cover ' || TO_VARCHAR(sum_insured)
                     || ' · premium ' || TO_VARCHAR(premium)
                     || CASE WHEN renewal_status='LATE'
                             THEN ' · renewed ' || days_late::VARCHAR || ' days late' ELSE '' END AS detail
            FROM {DB}.RAW.POLICY_VERSION WHERE customer_id = ?
            UNION ALL
            SELECT opened_at, 'Ticket', category,
                   subject || CASE WHEN sla_breached THEN ' · SLA BREACHED' ELSE '' END
                           || CASE WHEN reopen_count>0 THEN ' · reopened ' || reopen_count::VARCHAR ELSE '' END
            FROM {DB}.RAW.SUPPORT_TICKET WHERE customer_id = ?
            UNION ALL
            SELECT sent_at, 'Email',
                   CASE WHEN direction='INBOUND' THEN 'From customer' ELSE 'To customer' END,
                   subject
            FROM {DB}.RAW.EMAIL_MESSAGE WHERE customer_id = ?
            UNION ALL
            SELECT filed_date::TIMESTAMP_NTZ, 'Claim', claim_status,
                   claim_id || ' · ' || claim_type || ' · ' || TO_VARCHAR(claim_amount)
            FROM {DB}.RAW.INSURANCE_CLAIMS WHERE customer_id = ?
            UNION ALL
            SELECT filed_date::TIMESTAMP_NTZ, 'Grievance', status,
                   'IRDAI ' || igms_token || ' · ' || category
            FROM {DB}.RAW.GRIEVANCE WHERE customer_id = ?
            UNION ALL
            SELECT requested_date::TIMESTAMP_NTZ, 'Portability', stage,
                   target_insurer || ' quoted ' || TO_VARCHAR(quoted_premium)
                     || ' against ' || TO_VARCHAR(current_premium)
            FROM {DB}.RAW.PORTABILITY_REQUEST WHERE customer_id = ?
            UNION ALL
            SELECT interaction_date, 'Interaction', UPPER(interaction_type), subject
            FROM {DB}.CANONICAL.INTERACTION WHERE customer_id = ?
        ) ORDER BY when_at DESC LIMIT {int(limit)}
    """, [cid] * 7)
