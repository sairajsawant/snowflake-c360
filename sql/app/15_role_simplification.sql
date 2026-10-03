-- =============================================================================
-- 15_role_simplification.sql — one approval tier, two named relationship
-- managers, full ownership coverage.
--
-- 1. VP Executive is removed. Team Lead becomes the single, top approval
--    tier and absorbs the VP's corrected ceiling (was 2,075,000, now
--    8,300,000) and its 'override' permission. One tier instead of two.
-- 2. The single generic "Relationship Manager" persona is replaced by two
--    named ones, RM1 and RM2, each with a real, non-empty ASSIGNED-scope
--    slice of the book — so the scope demo is honest instead of always
--    resolving to one hardcoded identity regardless of who's "Acting as".
-- 3. CONFIG.CUSTOMER_ASSIGNMENT is fully backfilled — all 30 customers get
--    an owner (previously only 6 did), split across RM1/RM2, all in one
--    team so Team Lead's existing TEAM scope now covers the whole book
--    (replacing what VP's ALL scope used to be responsible for).
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

-- ─── CONFIG.USER_PERSONA ──────────────────────────────────────────────────
-- Team Lead absorbs the VP's ceiling and its one extra permission.
UPDATE CONFIG.USER_PERSONA
   SET max_approval_value = 100000,
       allowed_actions = PARSE_JSON('["view_customer","execute_autonomous","approve_action","reject_action","override"]')
 WHERE persona_id = 'team_lead';

DELETE FROM CONFIG.USER_PERSONA WHERE persona_id = 'vp_executive';
DELETE FROM CONFIG.USER_PERSONA WHERE persona_id = 'relationship_manager';

INSERT INTO CONFIG.USER_PERSONA
    (persona_id, persona_name, default_view, allowed_actions, data_scope_type,
     can_approve, can_configure, max_approval_value, created_at)
SELECT 'rm1', 'Relationship Manager 1', 'Decision Queue',
       PARSE_JSON('["view_customer","execute_autonomous","request_approval"]'),
       'ASSIGNED', FALSE, FALSE, 0, CURRENT_TIMESTAMP()
UNION ALL
SELECT 'rm2', 'Relationship Manager 2', 'Decision Queue',
       PARSE_JSON('["view_customer","execute_autonomous","request_approval"]'),
       'ASSIGNED', FALSE, FALSE, 0, CURRENT_TIMESTAMP();

-- ─── CONFIG.SCORING_CONFIG ────────────────────────────────────────────────
-- VP's weight profile (more cost-sensitive, less uplift-driven) moves to
-- Team Lead rather than being deleted — "who's asking changes the answer"
-- still holds, just between RM and Team Lead now instead of RM and VP.
UPDATE CONFIG.SCORING_CONFIG
   SET persona = 'team_lead',
       description = REPLACE(description, 'VP persona', 'Team Lead persona')
 WHERE persona = 'vp_executive';

-- relationship_manager's weight profile is shared by both RMs — same job,
-- different book. Duplicate the 4 factor rows for rm2, then rename the
-- originals to rm1.
INSERT INTO CONFIG.SCORING_CONFIG (scoring_id, domain_id, persona, factor_name, weight, description, active, created_at)
SELECT scoring_id || '_rm2', domain_id, 'rm2', factor_name, weight,
       REPLACE(description, 'RM persona', 'RM2 persona'), active, CURRENT_TIMESTAMP()
FROM CONFIG.SCORING_CONFIG WHERE persona = 'relationship_manager';

UPDATE CONFIG.SCORING_CONFIG
   SET persona = 'rm1',
       description = REPLACE(description, 'RM persona', 'RM1 persona')
 WHERE persona = 'relationship_manager';

-- ─── CONFIG.CUSTOMER_ASSIGNMENT ───────────────────────────────────────────
-- Full rebuild: every customer gets an owner, split round-robin across
-- RM1/RM2, all in one team so Team Lead sees the whole book.
DELETE FROM CONFIG.CUSTOMER_ASSIGNMENT;

INSERT INTO CONFIG.CUSTOMER_ASSIGNMENT (customer_id, assigned_user, assigned_team, domain, created_at)
SELECT customer_id,
       CASE WHEN MOD(ROW_NUMBER() OVER (ORDER BY customer_id), 2) = 1 THEN 'rm1' ELSE 'rm2' END,
       'team_alpha',
       domain,
       CURRENT_TIMESTAMP()
FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER;

SELECT 'Role simplification applied: VP removed, RM1/RM2 introduced, all 30 customers owned' AS status;
