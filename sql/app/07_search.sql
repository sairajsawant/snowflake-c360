-- =============================================================================
-- A Cortex Search service over the current customer book.
--
-- Built from CANONICAL.INTERACTION plus the live transcripts, tickets and
-- email, not from a hand-seeded document table — so it never drifts from the
-- real customer set. The corpus is a dynamic table, so a transcript injected
-- during a scenario run becomes searchable without anyone rebuilding anything.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

CREATE OR REPLACE DYNAMIC TABLE INTERACTION_CORPUS
  TARGET_LAG = '1 minute'
  WAREHOUSE = COMPUTE_WH
AS
SELECT
    'INT-' || i.customer_id || '-' || TO_VARCHAR(i.interaction_date, 'YYYYMMDDHH24MISS') AS doc_id,
    i.customer_id,
    c.full_name          AS customer_name,
    i.domain,
    UPPER(i.channel)          AS channel,
    UPPER(i.interaction_type) AS interaction_type,
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
JOIN CUSTOMER_360_DB.CANONICAL.CUSTOMER c ON c.customer_id = t.customer_id
UNION ALL
-- the written channel: each email is its own document so a thread can be
-- retrieved message by message, with the escalation visible in sequence
SELECT
    e.message_id,
    e.customer_id,
    c.full_name,
    c.domain,
    'EMAIL',
    CASE WHEN e.direction = 'INBOUND' THEN 'EMAIL_FROM_CUSTOMER' ELSE 'EMAIL_TO_CUSTOMER' END,
    e.subject,
    e.body,
    NULL,
    e.sent_at
FROM CUSTOMER_360_DB.RAW.EMAIL_MESSAGE e
JOIN CUSTOMER_360_DB.CANONICAL.CUSTOMER c ON c.customer_id = e.customer_id
UNION ALL
-- tickets, so "show me SLA breaches on claims" is answerable
SELECT
    t.ticket_id,
    t.customer_id,
    c.full_name,
    t.domain,
    t.channel,
    'SUPPORT_TICKET',
    t.subject,
    t.category || ' ticket, priority ' || t.priority || ', status ' || t.status
      || CASE WHEN t.sla_breached THEN '. SLA BREACHED.' ELSE '.' END
      || CASE WHEN t.reopen_count > 0 THEN ' Reopened ' || t.reopen_count::VARCHAR || ' time(s).' ELSE '' END
      || COALESCE(' Linked to claim ' || t.linked_claim_id || '.', '')
      || COALESCE(' Policy ' || t.linked_policy_id || '.', ''),
    NULL,
    t.opened_at
FROM CUSTOMER_360_DB.RAW.SUPPORT_TICKET t
JOIN CUSTOMER_360_DB.CANONICAL.CUSTOMER c ON c.customer_id = t.customer_id;

CREATE OR REPLACE CORTEX SEARCH SERVICE INTERACTION_SEARCH
  ON content
  ATTRIBUTES customer_id, customer_name, domain, channel, interaction_type, subject
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 minute'
AS
  SELECT doc_id, customer_id, customer_name, domain, channel,
         interaction_type, subject, content, interaction_date
  FROM CUSTOMER_360_DB.APP.INTERACTION_CORPUS;

GRANT SELECT ON DYNAMIC TABLE CUSTOMER_360_DB.APP.INTERACTION_CORPUS TO ROLE C360_JUDGE;
GRANT USAGE ON CORTEX SEARCH SERVICE CUSTOMER_360_DB.APP.INTERACTION_SEARCH TO ROLE C360_JUDGE;

SELECT 'APP search service created' AS status;
