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


# ── personalization (product recommendation) ──────────────────────────────────
def recommend_product(cid):
    return _df(f"SELECT * FROM TABLE({DB}.APP.RECOMMEND_PRODUCT({_lit(cid)}))")


def extract_product_interest(cid):
    return _obj(f"CALL {DB}.APP.EXTRACT_PRODUCT_INTEREST(?)", [cid])


def record_product_outcome(cid, product_id, accepted):
    return _obj(f"CALL {DB}.APP.RECORD_PRODUCT_OUTCOME(?, ?, ?)", [cid, product_id, accepted])


def search_products(query, limit=5):
    payload = json.dumps({
        "query": query,
        "columns": ["PRODUCT_NAME", "PRODUCT_TYPE", "DOMAIN_ID", "CONTENT"],
        "limit": int(limit),
    })
    sql = f"""
        SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            '{DB}.APP.PRODUCT_SEARCH',
            '{payload.replace("'", "''")}')) AS r
    """
    try:
        raw = _scalar(sql)
        parsed = json.loads(raw) if isinstance(raw, str) else raw
        return parsed.get("results", [])
    except Exception as exc:
        return [{"error": str(exc)}]


def product_catalog(domain=None):
    sql = f"""
        SELECT product_id, domain_id, product_name, product_type, min_age, max_age,
               segment_fit, min_amount, max_amount, description
        FROM {DB}.CONFIG.PRODUCT_CATALOG
        WHERE active = TRUE {"AND domain_id = ?" if domain else ""}
        ORDER BY domain_id, product_name
    """
    return _df(sql, [domain] if domain else None)


# ── chat / agent-style orchestration ────────────────────────────────────────
def chat_get_customer_360(cid):
    return _df(f"SELECT * FROM TABLE({DB}.APP.GET_CUSTOMER_360({_lit(cid)}))")


def chat_summarize_customer(cid):
    return _scalar(f"CALL {DB}.APP.SUMMARIZE_CUSTOMER(?)", [cid])


def resolve_customer(mention):
    """Deterministic lookup — the model names who it thinks was meant; SQL decides who it actually is."""
    if not mention:
        return None
    df = _df(f"""
        SELECT customer_id, full_name FROM {DB}.CANONICAL.CUSTOMER
        WHERE UPPER(customer_id) = UPPER(?) OR full_name ILIKE '%' || ? || '%'
        ORDER BY IFF(UPPER(customer_id) = UPPER(?), 0, 1), full_name
        LIMIT 1
    """, [mention, mention, mention])
    return None if df.empty else df.iloc[0]["CUSTOMER_ID"]


def _history_block(history, max_turns=6):
    """
    Render the recent conversation as plain text for the classifier, so a
    follow-up like "what about his renewal?" can be resolved. Only the last
    few turns, and assistant answers are truncated — this exists to resolve
    pronouns and ellipsis, not to re-feed the model its own prose.
    """
    if not history:
        return ""
    lines = []
    for turn in history[-max_turns:]:
        who = "RM" if turn.get("role") == "user" else "ASSISTANT"
        text = str(turn.get("content") or "").strip().replace("\n", " ")
        if who == "ASSISTANT":
            text = text[:200]
        if turn.get("customer_id"):
            text += f"  [about customer {turn['customer_id']}]"
        lines.append(f"{who}: {text}")
    return "CONVERSATION SO FAR (oldest first):\n" + "\n".join(lines) + "\n\n"


def chat_classify(question, history=None):
    """
    Route a free-text question to the narrowest tool, mirroring the deployed
    Agent's own orchestration instructions. The model only classifies and
    extracts a raw name/ID mention — it never picks the final answer; a
    deterministic tool call always does that.

    `history` lets a follow-up inherit the subject of the conversation
    ("what product suits him?"). It only ever widens what the model can
    resolve a mention to — the intent vocabulary stays the same fixed list,
    and whoever it names is still resolved against the customer table by SQL.
    """
    prompt = (
        _history_block(history) +
        "Classify this question from a relationship manager about a customer-360 "
        "insurance/lending platform. Pick exactly one intent from this fixed list:\n"
        "PROFILE - a plain request for a customer's profile/demographics/current state, nothing more\n"
        "SUMMARY - asks to summarize a customer or catch up on their history\n"
        "ACTION_RECOMMEND - asks what retention/servicing action to take for an at-risk customer\n"
        "PRODUCT_RECOMMEND - asks what product/offer/upsell/renewal personalization fits a customer\n"
        "SERVICE_RECOVERY - asks how to make good on a service failure, complaint, stuck or unresolved claim, repeated ticket, or a customer we have let down\n"
        "PRODUCT_SEARCH - asks about a product's features, terms or price, not tied to one customer\n"
        "INTERACTION_SEARCH - asks to find past calls, tickets or emails about a topic\n"
        "DECISION_QUEUE - asks who needs attention across the portfolio, not one customer\n"
        "UNKNOWN - none of the above fit\n\n"
        "Also extract any specific customer name or ID mentioned, verbatim. If the question refers "
        "to a customer only by a pronoun or shorthand (\"he\", \"her\", \"that customer\", \"them\") "
        "and the conversation above was about a specific customer, return THAT customer's id or "
        "name. If no specific customer is identifiable from either the question or the "
        "conversation, return JSON null (not the string \"null\") for customer_mention. Also "
        "extract a cleaned search phrase if the intent is a search, else JSON null for "
        "search_query. ALWAYS include all three keys — intent, customer_mention, search_query — "
        "in the output, even when a value is null.\n\n"
        f"QUESTION: {question}"
    )
    # customer_mention/search_query must be in `required` — otherwise the model
    # is free to omit them from the JSON entirely (confirmed: it reliably drops
    # customer_mention even when a customer ID is explicitly in the question).
    # `type: [string, null]` is needed since they're genuinely nullable fields.
    sql = f"""
        SELECT AI_COMPLETE(
            model => 'llama3.3-70b',
            prompt => ?,
            response_format => {{'type':'json','schema':{{'type':'object','properties':{{
                'intent':{{'type':'string'}},'customer_mention':{{'type':['string','null']}},
                'search_query':{{'type':['string','null']}}}},
                'required':['intent','customer_mention','search_query']}}}}
        ) AS out
    """
    # Structured-output generation (response_format) has a real, sometimes
    # input-specific failure rate — some questions reliably return NULL no
    # matter how clean the prompt is, confirmed by testing the same question
    # 3 times in a row. Retrying the SAME approach doesn't fix that, so after
    # retries, fall through to a plain-text completion with no schema
    # constraint — a different generation path, proven more robust — before
    # ever giving up to UNKNOWN.
    parsed = None
    for _attempt in range(2):
        raw = _scalar(sql, [prompt])
        if raw is None:
            continue
        try:
            parsed = json.loads(raw) if isinstance(raw, str) else raw
        except (json.JSONDecodeError, TypeError):
            parsed = None
        if isinstance(parsed, dict):
            break

    if not isinstance(parsed, dict):
        plain_prompt = prompt + (
            "\n\nRespond with EXACTLY three lines, nothing else:\n"
            "Line 1: the intent word from the list above\n"
            "Line 2: any specific customer name or ID mentioned, or the word NONE\n"
            "Line 3: a cleaned search phrase if the intent is a search, or the word NONE"
        )
        plain = _scalar("SELECT AI_COMPLETE('llama3.3-70b', ?)", [plain_prompt])
        # The model sometimes emits the answer as a quoted string with literal
        # backslash-n escapes instead of real newlines (e.g. '"ACTION_RECOMMEND\nX\nY"')
        # rather than actual line breaks — normalize both before splitting.
        plain_clean = (plain or '').strip()
        if len(plain_clean) > 1 and plain_clean[0] == '"' and plain_clean[-1] == '"':
            plain_clean = plain_clean[1:-1]
        plain_clean = plain_clean.replace('\\n', '\n')
        lines = [ln.strip() for ln in plain_clean.split('\n') if ln.strip()]
        parsed = {
            'intent': lines[0] if len(lines) > 0 else 'UNKNOWN',
            'customer_mention': lines[1] if len(lines) > 1 else None,
            'search_query': lines[2] if len(lines) > 2 else None,
        }

    # Generic placeholder phrases the model sometimes extracts as if they were
    # a name — rejected independently of the prompt, same "guard in two
    # places" principle used for the product-interest vocabulary.
    GENERIC_MENTIONS = {
        'a customer', 'the customer', 'this customer', 'that customer',
        'customers', 'someone', 'a client', 'the client', 'any customer',
    }

    def _clean(v):
        v = (v or '').strip()
        if v == '' or v.lower() in ('null', 'none') or v.lower() in GENERIC_MENTIONS:
            return None
        return v

    valid = {'PROFILE','SUMMARY','ACTION_RECOMMEND','PRODUCT_RECOMMEND','SERVICE_RECOVERY',
             'PRODUCT_SEARCH','INTERACTION_SEARCH','DECISION_QUEUE','UNKNOWN'}
    intent = str(parsed.get('intent', 'UNKNOWN')).upper()
    if intent not in valid:
        intent = 'UNKNOWN'
    return {
        'intent': intent,
        'customer_mention': _clean(parsed.get('customer_mention')),
        'search_query': _clean(parsed.get('search_query')),
    }


def _last_customer(history):
    """Most recent customer the conversation was actually about."""
    for turn in reversed(history or []):
        if turn.get("customer_id"):
            return turn["customer_id"]
    return None


def run_chat(question, persona, history=None):
    """
    The single entry point the chat UI calls. Classifies, resolves the
    customer deterministically, dispatches to the one tool that intent
    maps to, and composes a grounded answer. Returns everything the UI
    needs to show both the narrative and the raw data it came from.

    `history` makes the chat a conversation rather than a series of
    unrelated questions. It is used in exactly two places, both narrow:
    the classifier sees the recent turns so it can resolve "him"/"them",
    and if a customer-scoped intent still comes back without a customer,
    we fall back to whoever the conversation was last about. Everything
    downstream — the tool call, the data, the grounding — is unchanged.
    """
    route = chat_classify(question, history)
    intent = route['intent']
    cid = resolve_customer(route['customer_mention'])

    # Deterministic carry-over: a follow-up that names nobody is about
    # whoever we were just discussing. Done here rather than trusted to the
    # model, so it holds even when the model misses the pronoun.
    carried = False
    if intent in ('PROFILE', 'SUMMARY', 'ACTION_RECOMMEND', 'PRODUCT_RECOMMEND', 'SERVICE_RECOVERY') and not cid:
        prior = _last_customer(history)
        if prior:
            cid, carried = prior, True

    result = {'intent': intent, 'customer_id': cid, 'tool': None, 'data': None,
              'answer': None, 'carried_context': carried}

    if intent in ('PROFILE', 'SUMMARY', 'ACTION_RECOMMEND', 'PRODUCT_RECOMMEND', 'SERVICE_RECOVERY') and not cid:
        if route['customer_mention']:
            result['answer'] = (f"I couldn't find anyone matching \"{route['customer_mention']}\". "
                                 "Try a customer ID like INS-1011, or the full name.")
        else:
            result['answer'] = ("Which customer is this about? Give me an ID like INS-1011, or "
                                 "their full name.")
        return result

    if intent == 'PROFILE':
        result['tool'] = 'get_customer_360'
        df = chat_get_customer_360(cid)
        result['data'] = df.to_dict('records')
        result['answer'] = chat_compose(question, intent, result['data'], history)

    elif intent == 'SUMMARY':
        result['tool'] = 'summarize_customer'
        text = chat_summarize_customer(cid)
        result['data'] = {'summary': text}
        result['answer'] = text

    elif intent == 'ACTION_RECOMMEND':
        result['tool'] = 'recommend_action'
        df = recommend(cid, persona, 0)
        result['data'] = df.to_dict('records')
        result['answer'] = chat_compose(question, intent, result['data'], history)

    elif intent == 'PRODUCT_RECOMMEND':
        result['tool'] = 'recommend_product'
        df = recommend_product(cid)
        result['data'] = df.to_dict('records')
        result['answer'] = chat_compose(question, intent, result['data'], history)

    elif intent == 'SERVICE_RECOVERY':
        result['tool'] = 'recommend_service'
        df = recommend_service(cid)
        result['data'] = df.to_dict('records')
        result['answer'] = chat_compose(question, intent, result['data'], history)

    elif intent == 'PRODUCT_SEARCH':
        result['tool'] = 'search_products'
        res = search_products(route['search_query'] or question, limit=5)
        result['data'] = res
        result['answer'] = chat_compose(question, intent, res, history)

    elif intent == 'INTERACTION_SEARCH':
        result['tool'] = 'interaction_search'
        res = search_interactions(route['search_query'] or question, limit=5)
        result['data'] = res
        result['answer'] = chat_compose(question, intent, res, history)

    elif intent == 'DECISION_QUEUE':
        result['tool'] = 'get_decision_queue'
        df = queue('ALL')
        result['data'] = df.to_dict('records')
        result['answer'] = chat_compose(question, intent, result['data'], history)

    else:
        result['answer'] = (
            "I can look up a customer's profile, summarise their history, recommend a retention "
            "action or a product, search past calls and emails, or show who needs attention "
            "today. Try something like \"summarise INS-1011\" or \"what product fits LND-2010 "
            "at renewal?\"")

    return result


def chat_compose(question, intent, facts, history=None):
    """
    Turn a tool's structured output into a short natural-language answer,
    strictly grounded — the facts dict/list is the only source of truth
    the model is given, so it cannot add a recommendation that isn't there.
    """
    prompt = (
        "Answer this relationship-manager question in 2-4 sentences, using ONLY the facts given. "
        "Never state a number, product, or action that is not present in the facts. If the facts "
        "are empty, say plainly that nothing matched rather than guessing. Write for a busy "
        "relationship manager: plain English, no jargon, no database or system names. The "
        "conversation is shown only so your reply reads as a natural follow-up — every figure "
        "you state must still come from the facts below.\n\n"
        + _history_block(history, max_turns=4) +
        f"QUESTION: {question}\n\nINTENT: {intent}\n\nFACTS (JSON):\n{json.dumps(facts, default=str)[:4000]}"
    )
    for _attempt in range(2):
        answer = _scalar("SELECT AI_COMPLETE('llama3.3-70b', ?)", [prompt])
        if answer:
            # The model sometimes returns the whole reply wrapped in quote marks;
            # strip them so the chat bubble doesn't read like a quotation.
            answer = str(answer).strip()
            if len(answer) > 1 and answer[0] == '"' and answer[-1] == '"':
                answer = answer[1:-1].strip()
            return answer
    return "Here's what matched, shown below — the summary didn't generate this time."


# ── unified persona feed ─────────────────────────────────────────────────────
@st.cache_data(ttl=300, show_spinner=False)
def unified_feed(persona_scope, persona, assigned_user="rm1", team="team_alpha", limit=12):
    """
    One ranked list per persona: retention actions for HIGH/CRITICAL customers,
    product opportunities for everyone else — never both for the same customer.

    Computed set-based in a single statement (~1s) rather than by looping every
    customer through a scoring call (~47s). ELIGIBLE_TOTAL reports how many
    customers qualified in total, so the UI can say plainly when the list is
    showing the top slice rather than everything.
    """
    return _df(f"""SELECT * FROM TABLE({DB}.APP.UNIFIED_FEED_FAST(?, ?, ?, ?, ?))""",
               [persona_scope, assigned_user or "", team or "", persona, float(limit)])


def recommend_service(cid):
    """
    Service recovery — what we owe a customer we failed. Served by the generic
    decision engine from config rows alone; there is no service-specific
    scoring function to call.
    """
    return _df(f"""SELECT * FROM TABLE({DB}.APP.RECOMMEND_GENERIC('service_recovery', ?))""", [cid])


def refresh_signal_snapshot():
    """Force the signal layer up to date — used after a scenario injects new evidence."""
    return _scalar(f"CALL {DB}.APP.REFRESH_SIGNAL_SNAPSHOT()")
