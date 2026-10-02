-- =============================================================================
-- A Cortex Search service over the CURRENT customer book.
--
-- SEARCH.INTERACTION_DOCUMENTS still holds the 60 pre-migration documents
-- (C1023 "Sarah Chen" and friends), so SEARCH.CUSTOMER_INTERACTION_SEARCH
-- returns customers who no longer exist. Rather than overwrite a table the
-- original app also reads, v2 builds its own corpus from CANONICAL.INTERACTION
-- and the live transcripts, and searches that.
--
-- The corpus is a dynamic table, so a transcript injected during a scenario run
-- becomes searchable without anyone rebuilding anything.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP_V2;

CREATE OR REPLACE DYNAMIC TABLE INTERACTION_CORPUS
  TARGET_LAG = '1 minute'
  WAREHOUSE = COMPUTE_WH
AS
SELECT
    'INT-' || i.customer_id || '-' || TO_VARCHAR(i.interaction_date, 'YYYYMMDDHH24MISS') AS doc_id,
    i.customer_id,
    c.full_name          AS customer_name,
    i.domain,
    i.channel,
    i.interaction_type,
    COALESCE(i.subject, 'Interaction') AS subject,
    COALESCE(i.notes, i.subject, '')   AS content,
    i.sentiment_score,
    i.interaction_date
FROM CUSTOMER_360_DB.CANONICAL.INTERACTION i
JOIN CUSTOMER_360_DB.CANONICAL.CUSTOMER c
  ON c.customer_id = i.customer_id AND c.domain = i.domain
UNION ALL
SELECT
    t.transcript_id AS doc_id,
    t.customer_id,
    c.full_name,
    'insurance',
    'PHONE',
    'CALL_TRANSCRIPT',
    'Call transcript ' || t.transcript_id,
    t.transcript_text,
    NULL,
    t.call_date
FROM CUSTOMER_360_DB.RAW.INSURANCE_CALL_TRANSCRIPTS t
JOIN CUSTOMER_360_DB.CANONICAL.CUSTOMER c ON c.customer_id = t.customer_id
UNION ALL
SELECT
    t.transcript_id,
    t.customer_id,
    c.full_name,
    'lending',
    'PHONE',
    'CALL_TRANSCRIPT',
    'Call transcript ' || t.transcript_id,
    t.transcript_text,
    NULL,
    t.call_date
FROM CUSTOMER_360_DB.RAW.LENDING_CALL_TRANSCRIPTS t
JOIN CUSTOMER_360_DB.CANONICAL.CUSTOMER c ON c.customer_id = t.customer_id;

CREATE OR REPLACE CORTEX SEARCH SERVICE INTERACTION_SEARCH_V2
  ON content
  ATTRIBUTES customer_id, customer_name, domain, channel, interaction_type, subject
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 minute'
AS
  SELECT doc_id, customer_id, customer_name, domain, channel,
         interaction_type, subject, content, interaction_date
  FROM CUSTOMER_360_DB.APP_V2.INTERACTION_CORPUS;

GRANT SELECT ON DYNAMIC TABLE CUSTOMER_360_DB.APP_V2.INTERACTION_CORPUS TO ROLE C360_JUDGE;
GRANT USAGE ON CORTEX SEARCH SERVICE CUSTOMER_360_DB.APP_V2.INTERACTION_SEARCH_V2 TO ROLE C360_JUDGE;

SELECT 'APP_V2 search service created' AS status;
