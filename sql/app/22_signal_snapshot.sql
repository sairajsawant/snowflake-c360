-- =============================================================================
-- 22_signal_snapshot.sql — materialise the signal layer so list views are fast.
--
-- ADDITIVE. APP.V_ALL_SIGNALS and APP.V_DERIVED_SIGNALS are untouched and
-- remain the definition of truth; every existing caller keeps using them.
-- Only the feed reads the snapshot.
--
-- WHY
-- Measured on the live account, the feed's cost was not the decision maths:
--
--   whole feed, one set-based statement .......... ~10 s
--     of which APP.V_ALL_SIGNALS ................. ~10 s
--       of which APP.V_DERIVED_SIGNALS ........... ~9.5 s
--     everything else (states, config, scoring) ... ~0.2 s
--
-- V_DERIVED_SIGNALS recomputes every derived signal for every customer from
-- RAW on every single read — date proximity, payment irregularity, ticket
-- friction. Filtering it doesn't help (10.8 s even when restricted to the six
-- signals product rules reference) because the derivation runs before the
-- filter. It has to be materialised, not optimised in place.
--
-- A Dynamic Table is the platform's existing idiom, but Snowflake rejects one
-- here: V_ALL_SIGNALS already reads the CANONICAL dynamic tables, and dynamic
-- tables can't be layered over dynamic tables without refresh-boundary
-- plumbing. So this uses the other mechanism already in the platform — a
-- scheduled task, on the same 1-minute cadence as the existing
-- EXTRACT_SIGNALS -> COMPUTE_STATES -> DETECT_TRANSITIONS DAG, so the
-- freshness contract the sidebar already advertises is unchanged.
--
-- Reactive path: a scenario run that injects new evidence must show up
-- immediately, not within a minute — so APP.REFRESH_SIGNAL_SNAPSHOT() is
-- callable directly and the feed's Refresh control invokes it before reading.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

CREATE TABLE IF NOT EXISTS APP.SIGNAL_SNAPSHOT (
    CUSTOMER_ID   VARCHAR(50),
    DOMAIN        VARCHAR(50),
    SIGNAL_NAME   VARCHAR(100),
    SIGNAL_VALUE  VARCHAR(100),
    NUMERIC_VALUE FLOAT,
    CONFIDENCE    FLOAT,
    EVIDENCE_REF  VARCHAR(500),
    ORIGIN        VARCHAR(20),
    REFRESHED_AT  TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE APP.REFRESH_SIGNAL_SNAPSHOT()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    -- Single atomic swap of contents; readers never see a half-built snapshot.
    CREATE OR REPLACE TEMPORARY TABLE tmp_sig AS
        SELECT customer_id, domain, signal_name, signal_value, numeric_value,
               confidence, evidence_ref, origin, CURRENT_TIMESTAMP() AS refreshed_at
        FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS;
    DELETE FROM CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT;
    INSERT INTO CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT
        SELECT * FROM tmp_sig;
    RETURN 'OK';
END;
$$;

CALL APP.REFRESH_SIGNAL_SNAPSHOT();

CREATE OR REPLACE TASK APP.TASK_REFRESH_SIGNAL_SNAPSHOT
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 minute'
AS
    CALL CUSTOMER_360_DB.APP.REFRESH_SIGNAL_SNAPSHOT();

ALTER TASK APP.TASK_REFRESH_SIGNAL_SNAPSHOT RESUME;

GRANT USAGE ON PROCEDURE APP.REFRESH_SIGNAL_SNAPSHOT() TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE APP.SIGNAL_SNAPSHOT TO ROLE C360_JUDGE;

SELECT 'Signal snapshot deployed' AS status, COUNT(*) AS rows_snapshotted
FROM APP.SIGNAL_SNAPSHOT;
