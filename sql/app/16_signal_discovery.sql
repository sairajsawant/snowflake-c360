-- =============================================================================
-- 16_signal_discovery.sql — signal discovery, scheduled daily.
--
-- Every signal in this platform so far was hand-authored by a human looking
-- at a table and deciding what mattered (see 14_signal_completion.sql for
-- the last 3 done this way). This closes that gap: a procedure that looks
-- at RAW tables nothing has mined yet and proposes candidate signals —
-- deterministic SQL candidates from structured columns (dates, low-
-- cardinality status columns), AI-proposed candidates from free-text
-- columns — as DRAFT rows a human reviews and promotes, never auto-activates.
--
-- Three categories, deliberately few, so the UI stays scannable:
--   RISK        predicts churn/default/attrition
--   SERVICE     operational friction we caused
--   OPPORTUNITY relationship value / growth timing
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- ─── Category on existing signals, so the UI groups old and new the same way ──
ALTER TABLE CONFIG.SIGNAL_DEFINITION ADD COLUMN IF NOT EXISTS category VARCHAR(20) DEFAULT 'RISK';

UPDATE CONFIG.SIGNAL_DEFINITION SET category = 'SERVICE'
 WHERE signal_name IN ('service_failure', 'ticket_reopen', 'csat_low', 'unresolved_claim');

UPDATE CONFIG.SIGNAL_DEFINITION SET category = 'OPPORTUNITY'
 WHERE signal_name IN ('group_exposure', 'renewal_proximity');

-- everything else (churn_intent, grievance_filed, portability_intent,
-- negative_sentiment, coverage_downgrade, renewal_lateness,
-- payment_irregularity, email_escalation, claim_friction, delinquency,
-- hardship_intent, payment_risk, credit_deterioration) stays RISK, the
-- column default — which is also honest: most of what this platform
-- watches for is churn/default risk.

-- ─── Candidate storage ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS SIGNAL_CANDIDATE (
    candidate_id        VARCHAR(100) PRIMARY KEY,
    domain_id            VARCHAR(50),
    signal_name          VARCHAR(100),
    category              VARCHAR(20),
    extraction_method    VARCHAR(20),   -- SQL | INTENT
    extraction_prompt    VARCHAR(2000), -- NULL for SQL candidates
    source_table          VARCHAR(100),
    source_column        VARCHAR(100),
    rationale              VARCHAR(500),  -- why it might matter + how it'd be computed, one sentence
    priority                VARCHAR(10),   -- HIGH | MEDIUM | LOW
    trigger_rate          FLOAT,         -- % of rows that would actually flag, where known
    status                  VARCHAR(20) DEFAULT 'NEW',  -- NEW | PROMOTED | DISMISSED
    discovered_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    reviewed_at            TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS DISCOVERY_RUN (
    run_id                  VARCHAR(60) PRIMARY KEY,
    run_at                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    tables_scanned        VARCHAR(500),
    candidates_found    NUMBER,
    ai_summary              VARCHAR(2000)
);

-- =============================================================================
-- DISCOVER_SIGNALS() — Snowpark Python. Genuinely needs iteration: for each
-- un-mined RAW table, for each column, branch on data type, and for
-- free-text columns make a per-column AI_COMPLETE call — not a single SQL
-- statement's shape.
-- =============================================================================
CREATE OR REPLACE PROCEDURE DISCOVER_SIGNALS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
DB = "CUSTOMER_360_DB"

SKIP_COLUMNS = {
    'created_at', 'updated_at', 'domain', 'customer_id',
}

RISK_WORDS = ['grievance', 'complaint', 'escalat', 'delinq', 'default',
              'breach', 'downgrade', 'reject', 'fail', 'overdue']
SERVICE_WORDS = ['sla', 'reopen', 'csat', 'resolution', 'response']
OPPORTUNITY_WORDS = ['maturity', 'renewal', 'upsell', 'join', 'tenure', 'exposure', 'role']


def _lit(v):
    if v is None:
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def _category(table, column):
    s = (table + " " + column).lower()
    if any(w in s for w in RISK_WORDS):
        return 'RISK'
    if any(w in s for w in SERVICE_WORDS):
        return 'SERVICE'
    if any(w in s for w in OPPORTUNITY_WORDS):
        return 'OPPORTUNITY'
    return 'RISK'


def _infer_domain(session, table):
    row = session.sql(f"""
        SELECT customer_id FROM {DB}.RAW.{table}
        WHERE customer_id IS NOT NULL LIMIT 1
    """).collect()
    if row and str(row[0][0]).startswith('LND'):
        return 'lending'
    return 'insurance'


def run(session):
    covered_rows = session.sql(f"""
        SELECT DISTINCT UPPER(REGEXP_REPLACE(source_table, '^RAW\\\\.', '')) AS t
        FROM {DB}.CONFIG.SIGNAL_DEFINITION WHERE source_table ILIKE 'RAW.%'
    """).collect()
    covered = {r['T'] for r in covered_rows}

    all_tables = session.sql(f"""
        SELECT table_name FROM {DB}.INFORMATION_SCHEMA.TABLES
        WHERE table_schema = 'RAW' AND table_type = 'BASE TABLE'
    """).collect()
    targets = [r['TABLE_NAME'] for r in all_tables if r['TABLE_NAME'] not in covered]

    existing_cand = session.sql(f"""
        SELECT source_table, source_column FROM {DB}.APP.SIGNAL_CANDIDATE
        WHERE status IN ('NEW', 'PROMOTED')
    """).collect()
    seen = {(r['SOURCE_TABLE'], r['SOURCE_COLUMN']) for r in existing_cand}

    fresh = []

    for tbl in targets:
        domain = _infer_domain(session, tbl)
        cols = session.sql(f"""
            SELECT column_name, data_type, character_maximum_length
            FROM {DB}.INFORMATION_SCHEMA.COLUMNS
            WHERE table_schema = 'RAW' AND table_name = {_lit(tbl)}
            ORDER BY ordinal_position
        """).collect()

        for c in cols:
            col = c['COLUMN_NAME']
            lcol = col.lower()
            if lcol in SKIP_COLUMNS or lcol.endswith('_id') or lcol == tbl.lower() + '_id':
                continue
            if (tbl, col) in seen:
                continue

            dtype = c['DATA_TYPE']
            cat = _category(tbl, col)

            if dtype in ('DATE', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ'):
                near = session.sql(f"""
                    SELECT COUNT_IF({col} BETWEEN CURRENT_DATE() AND DATEADD(day, 90, CURRENT_DATE())) AS near,
                           COUNT_IF({col} IS NOT NULL) AS total
                    FROM {DB}.RAW.{tbl}
                """).collect()[0]
                total = near['TOTAL'] or 0
                if total == 0:
                    continue
                rate = float(near['NEAR']) / total
                priority = 'HIGH' if rate >= 0.20 else ('MEDIUM' if rate >= 0.05 else 'LOW')
                signal_name = f"{tbl.lower()}_{lcol}_proximity"
                rationale = (f"{col} on {tbl} — proximity to today. "
                             f"{rate*100:.0f}% of rows fall within 90 days now; "
                             f"SQL: DATEDIFF(day, CURRENT_DATE(), {col}) thresholded at 30/90 days.")
                fresh.append(dict(domain=domain, signal_name=signal_name, category=cat,
                                   method='SQL', prompt=None, table=tbl, column=col,
                                   rationale=rationale, priority=priority, rate=rate))

            elif dtype in ('VARCHAR', 'TEXT', 'STRING'):
                maxlen = c['CHARACTER_MAXIMUM_LENGTH'] or 0
                if maxlen and maxlen >= 200:
                    sample = session.sql(f"""
                        SELECT {col} FROM {DB}.RAW.{tbl}
                        WHERE {col} IS NOT NULL ORDER BY RANDOM() LIMIT 8
                    """).collect()
                    if len(sample) < 3:
                        continue
                    text_blob = "\n---\n".join(str(r[0])[:600] for r in sample)
                    raw = session.sql(f"""
                        SELECT AI_COMPLETE('llama3.3-70b',
                            'These are sample values from column {col} in table {tbl} at an '
                            || 'insurance/lending company. In one sentence, propose a NEW customer '
                            || 'risk-or-opportunity signal this text could support, not already '
                            || 'covered by churn intent, sentiment, grievances, portability, service '
                            || 'failures, claim friction, coverage downgrades, renewal lateness, group '
                            || 'exposure, payment irregularity, or email escalation. If nothing new is '
                            || 'justified, respond with exactly NONE.\\n\\nSAMPLES:\\n' || {_lit(text_blob)}
                        ) AS out
                    """).collect()[0]['OUT']
                    if not raw or raw.strip().upper().startswith('NONE'):
                        continue
                    signal_name = f"{tbl.lower()}_{lcol}_signal"
                    fresh.append(dict(domain=domain, signal_name=signal_name, category=cat,
                                       method='INTENT', prompt=raw.strip(), table=tbl, column=col,
                                       rationale=raw.strip()[:490], priority='MEDIUM', rate=None))
                else:
                    card_row = session.sql(f"""
                        SELECT COUNT(*) AS card, SUM(c) AS total, MAX(c) AS top_count
                        FROM (SELECT {col}, COUNT(*) AS c FROM {DB}.RAW.{tbl}
                              WHERE {col} IS NOT NULL GROUP BY {col})
                    """).collect()[0]
                    card = card_row['CARD'] or 0
                    total = card_row['TOTAL'] or 0
                    if card < 2 or card > 8 or total == 0:
                        continue
                    top_share = float(card_row['TOP_COUNT']) / total if total else 1.0
                    priority = 'HIGH' if top_share < 0.8 else 'MEDIUM'
                    signal_name = f"{tbl.lower()}_{lcol}_flag"
                    rationale = (f"{col} on {tbl} — {card} distinct values, no single value dominates "
                                 f"({top_share*100:.0f}% max share). SQL: flag on the minority value(s).")
                    fresh.append(dict(domain=domain, signal_name=signal_name, category=cat,
                                       method='SQL', prompt=None, table=tbl, column=col,
                                       rationale=rationale, priority=priority, rate=1 - top_share))

    for cand in fresh:
        session.sql(f"""
            INSERT INTO {DB}.APP.SIGNAL_CANDIDATE
                (candidate_id, domain_id, signal_name, category, extraction_method,
                 extraction_prompt, source_table, source_column, rationale, priority,
                 trigger_rate, status, discovered_at)
            SELECT 'cand-' || {_lit(cand['table'].lower())} || '-' || {_lit(cand['column'].lower())}
                     || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
                   {_lit(cand['domain'])}, {_lit(cand['signal_name'])}, {_lit(cand['category'])},
                   {_lit(cand['method'])}, {_lit(cand['prompt'])},
                   {_lit('RAW.' + cand['table'])}, {_lit(cand['column'])},
                   {_lit(cand['rationale'])}, {_lit(cand['priority'])},
                   {cand['rate'] if cand['rate'] is not None else 'NULL'}, 'NEW', CURRENT_TIMESTAMP()
        """).collect()

    run_id = session.sql("SELECT 'run-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3')").collect()[0][0]

    if fresh:
        names = ", ".join(c['signal_name'] for c in fresh)
        summary = session.sql(f"""
            SELECT AI_COMPLETE('llama3.3-70b',
                'In 2-3 plain sentences for a product analyst, summarize these newly discovered '
                || 'candidate customer-intelligence signals, naming the single most actionable one '
                || 'first: ' || {_lit(names)} || '. Context for each: '
                || {_lit(' | '.join(c['rationale'] for c in fresh))}
            )
        """).collect()[0][0]
    else:
        summary = ("No new signal candidates today — every RAW table either already backs a "
                    "configured signal or produced nothing meeting the discovery bar.")

    tables_str = ", ".join(targets) if targets else "none"
    session.sql(f"""
        INSERT INTO {DB}.APP.DISCOVERY_RUN (run_id, run_at, tables_scanned, candidates_found, ai_summary)
        SELECT {_lit(run_id)}, CURRENT_TIMESTAMP(), {_lit(tables_str)}, {len(fresh)}, {_lit(summary)}
    """).collect()

    return summary
$$;

-- =============================================================================
-- Promote / dismiss — a human decision, never automatic.
-- Promoting an SQL candidate adds the CONFIG row (visible, scored) but — same
-- honesty as the rest of this platform's extensibility story — a SQL-method
-- signal still needs its UNION ALL branch added to V_DERIVED_SIGNALS to
-- actually produce rows; an INTENT-method one needs an extraction hook. This
-- marks it "approved to implement," not "now live."
-- =============================================================================
CREATE OR REPLACE PROCEDURE PROMOTE_SIGNAL_CANDIDATE(P_CANDIDATE_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO :v_exists FROM CUSTOMER_360_DB.APP.SIGNAL_CANDIDATE
    WHERE candidate_id = :P_CANDIDATE_ID AND status = 'NEW';
    IF (:v_exists = 0) THEN
        RETURN 'Candidate not found or already reviewed.';
    END IF;

    INSERT INTO CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION
        (signal_id, domain_id, signal_name, signal_type, extraction_method,
         extraction_prompt, source_table, weight, active, category, created_at)
    SELECT 'disc-' || SUBSTR(MD5(candidate_id), 1, 12), domain_id, signal_name, 'discovered', extraction_method,
           extraction_prompt, source_table, 0.15, TRUE, category, CURRENT_TIMESTAMP()
    FROM CUSTOMER_360_DB.APP.SIGNAL_CANDIDATE WHERE candidate_id = :P_CANDIDATE_ID;

    UPDATE CUSTOMER_360_DB.APP.SIGNAL_CANDIDATE
       SET status = 'PROMOTED', reviewed_at = CURRENT_TIMESTAMP()
     WHERE candidate_id = :P_CANDIDATE_ID;

    RETURN 'Promoted to CONFIG.SIGNAL_DEFINITION — implement the extraction to make it live.';
END;
$$;

CREATE OR REPLACE PROCEDURE DISMISS_SIGNAL_CANDIDATE(P_CANDIDATE_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
BEGIN
    UPDATE CUSTOMER_360_DB.APP.SIGNAL_CANDIDATE
       SET status = 'DISMISSED', reviewed_at = CURRENT_TIMESTAMP()
     WHERE candidate_id = :P_CANDIDATE_ID;
    RETURN 'Dismissed.';
END;
$$;

-- =============================================================================
-- Daily task. A Stream-triggered variant (fire only when RAW gains a table)
-- is the natural next step — this cron is the pragmatic MVP.
-- =============================================================================
CREATE OR REPLACE TASK TASK_DISCOVER_SIGNALS
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 3 * * * UTC'
AS
    CALL CUSTOMER_360_DB.APP.DISCOVER_SIGNALS();

ALTER TASK TASK_DISCOVER_SIGNALS RESUME;

GRANT SELECT ON TABLE APP.SIGNAL_CANDIDATE TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE APP.DISCOVERY_RUN TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE APP.DISCOVER_SIGNALS() TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE APP.PROMOTE_SIGNAL_CANDIDATE(VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE APP.DISMISS_SIGNAL_CANDIDATE(VARCHAR) TO ROLE C360_JUDGE;

SELECT 'Signal discovery deployed — daily task scheduled' AS status;
