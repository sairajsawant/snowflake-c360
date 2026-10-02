-- =============================================================================
-- APP_V2 decisioning, action and learning.
--
-- RECOMMEND_ACTION here replaces the broken APP.RECOMMEND_ACTION. Differences
-- that matter:
--   * reads SCORING_CONFIG in its real long format via CUSTOMER_360_DB.APP_V2.V_SCORING,
--     falling back to the 'default' persona when a persona has no rows
--     (APP's CROSS JOIN ... LIMIT 1 returns zero rows for team_lead/analyst,
--      so it would silently recommend nothing);
--   * expected value uses the customer's real relationship value instead of a
--     hardcoded 50,000, so a ₹15.8 L corporate account and a ₹25,000 policy no
--     longer score identically;
--   * cost is normalised against a FIXED per-domain ceiling, so a modified
--     offer amount actually moves the ranking;
--   * cost weight is already negative in CONFIG, so it is ADDED, not subtracted
--     (APP subtracts it, which makes a more expensive action score higher).
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP_V2;

CREATE OR REPLACE PROCEDURE RECOMMEND_ACTION(
    P_CUSTOMER_ID VARCHAR, P_PERSONA VARCHAR, P_OFFER_AMOUNT FLOAT)
RETURNS TABLE (ACTION_ID VARCHAR, ACTION_NAME VARCHAR, ACTION_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, EFFECTIVENESS_RATE FLOAT, SAMPLE_SIZE NUMBER,
    EXPECTED_UPLIFT FLOAT, CONFIDENCE FLOAT, EXPECTED_VALUE FLOAT,
    TOTAL_COST FLOAT, REQUIRES_APPROVAL BOOLEAN, POLICY_STATUS VARCHAR,
    W_UPLIFT FLOAT, W_VALUE FLOAT, W_COST FLOAT, W_CONF FLOAT,
    PART_UPLIFT FLOAT, PART_VALUE FLOAT, PART_COST FLOAT, PART_CONF FLOAT,
    COST_CEILING FLOAT, RELATIONSHIP_VALUE FLOAT)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
        WITH ctx AS (
            SELECT cs.customer_id, cs.state_id, cs.domain,
                   rv.relationship_value, cc.cost_ceiling
            FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
            JOIN CUSTOMER_360_DB.APP_V2.V_RELATIONSHIP_VALUE rv
              ON rv.customer_id = cs.customer_id AND rv.domain = cs.domain
            JOIN CUSTOMER_360_DB.APP_V2.V_COST_CEILING cc ON cc.domain_id = cs.domain
            WHERE cs.customer_id = :P_CUSTOMER_ID AND cs.is_current = TRUE
        ),
        wts AS (   -- persona weights, else the domain default
            SELECT c.domain,
                COALESCE(p.w_uplift, d.w_uplift) AS w_uplift,
                COALESCE(p.w_value,  d.w_value)  AS w_value,
                COALESCE(p.w_cost,   d.w_cost)   AS w_cost,
                COALESCE(p.w_conf,   d.w_conf)   AS w_conf
            FROM ctx c
            LEFT JOIN CUSTOMER_360_DB.APP_V2.V_SCORING p ON p.domain_id = c.domain AND p.persona = :P_PERSONA
            LEFT JOIN CUSTOMER_360_DB.APP_V2.V_SCORING d ON d.domain_id = c.domain AND d.persona = 'default'
        ),
        cand AS (
            SELECT ad.action_id, ad.action_name, ad.action_type, ad.requires_approval,
                   ad.approval_threshold, ad.default_cost,
                   COALESCE(ae.success_rate, 0.30) AS eff_rate,
                   COALESCE(ae.total_count, 0)     AS sample_size,
                   COALESCE(ae.avg_uplift, 0.05)   AS uplift,
                   COALESCE(ae.confidence, 0.40)   AS conf,
                   c.relationship_value, c.cost_ceiling, c.domain,
                   ad.default_cost
                     + CASE WHEN ad.requires_approval THEN COALESCE(:P_OFFER_AMOUNT,0) ELSE 0 END AS total_cost
            FROM ctx c
            JOIN CUSTOMER_360_DB.CONFIG.ACTION_STATE_MAPPING asm
              ON asm.state_id = c.state_id AND asm.domain_id = c.domain AND asm.active = TRUE
            JOIN CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad
              ON ad.action_id = asm.action_id AND ad.active = TRUE
            LEFT JOIN CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS ae
              ON ae.action_id = ad.action_id AND ae.state_id = c.state_id AND ae.domain_id = c.domain
        ),
        norm AS (
            SELECT cand.*,
                cand.relationship_value * cand.eff_rate * cand.uplift AS ev,
                cand.uplift / NULLIF(MAX(cand.uplift) OVER (), 0) AS un,
                (cand.relationship_value * cand.eff_rate * cand.uplift)
                  / NULLIF(MAX(cand.relationship_value * cand.eff_rate * cand.uplift) OVER (), 0) AS vn,
                cand.total_cost / NULLIF(cand.cost_ceiling, 0) AS cn
            FROM cand
        ),
        scored AS (
            SELECT n.*, w.w_uplift, w.w_value, w.w_cost, w.w_conf,
                w.w_uplift * n.un AS part_uplift,
                w.w_value  * n.vn AS part_value,
                w.w_cost   * n.cn AS part_cost,
                w.w_conf   * n.conf AS part_conf,
                w.w_uplift * n.un + w.w_value * n.vn + w.w_cost * n.cn + w.w_conf * n.conf AS score
            FROM norm n CROSS JOIN wts w
        )
        SELECT action_id, action_name, action_type,
            ROW_NUMBER() OVER (ORDER BY score DESC) AS ranking,
            ROUND(score,4), eff_rate, sample_size, uplift, conf, ROUND(ev,0),
            total_cost, requires_approval,
            CASE
                WHEN NOT requires_approval AND default_cost < 8300 THEN 'AUTONOMOUS'
                WHEN NOT requires_approval THEN 'AUTONOMOUS_REVIEW'
                WHEN COALESCE(:P_OFFER_AMOUNT,0) > 415000 THEN 'VP_APPROVAL'
                ELSE 'REQUIRES_APPROVAL'
            END AS policy_status,
            w_uplift, w_value, w_cost, w_conf,
            ROUND(part_uplift,4), ROUND(part_value,4), ROUND(part_cost,4), ROUND(part_conf,4),
            cost_ceiling, relationship_value
        FROM scored ORDER BY score DESC
    );
    RETURN TABLE(res);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- POLICY_EVAL — every POLICY_RULE row for the domain, evaluated with the actual
-- substituted values, plus the persona authority check against the corrected
-- INR ceiling. Returns one row per policy so the UI can show the workings.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE POLICY_EVAL(
    P_CUSTOMER_ID VARCHAR, P_ACTION_ID VARCHAR, P_PERSONA VARCHAR, P_OFFER_AMOUNT FLOAT)
RETURNS TABLE (POLICY_ID VARCHAR, POLICY_NAME VARCHAR, POLICY_TYPE VARCHAR,
    RULE_EXPRESSION VARCHAR, SUBSTITUTED VARCHAR, VERDICT VARCHAR, ENFORCEMENT VARCHAR)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (
        WITH a AS (
            SELECT ad.action_id, ad.action_name, ad.action_type, ad.default_cost,
                   ad.requires_approval, ad.approval_threshold, ad.domain_id
            FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad WHERE ad.action_id = :P_ACTION_ID
        )
        SELECT pr.policy_id, pr.policy_name, pr.policy_type, pr.rule_expression,
            CASE pr.policy_type
                WHEN 'AUTO_EXECUTE' THEN 'action_type=''' || a.action_type
                     || ''', action_cost=' || TO_VARCHAR(a.default_cost)
                WHEN 'VALUE_LIMIT'  THEN 'offer_amount=' || TO_VARCHAR(COALESCE(:P_OFFER_AMOUNT,0))
                WHEN 'APPROVAL_GATE' THEN 'offer_amount=' || TO_VARCHAR(COALESCE(:P_OFFER_AMOUNT,0))
                ELSE 'not applicable to this action'
            END AS substituted,
            CASE
                WHEN pr.policy_type = 'AUTO_EXECUTE' THEN
                    CASE WHEN a.action_type = 'AUTONOMOUS' AND a.default_cost < 8300
                         THEN 'ALLOW' ELSE 'SKIP' END
                WHEN pr.policy_type = 'VALUE_LIMIT' AND pr.policy_id = 'pol_ins_1' THEN
                    CASE WHEN NOT a.requires_approval THEN 'SKIP'
                         WHEN COALESCE(:P_OFFER_AMOUNT,0) <= 415000 THEN 'PASS' ELSE 'BLOCK' END
                WHEN pr.policy_type = 'APPROVAL_GATE' AND pr.policy_id = 'pol_ins_3' THEN
                    CASE WHEN NOT a.requires_approval THEN 'SKIP'
                         WHEN COALESCE(:P_OFFER_AMOUNT,0) > 415000 THEN 'REQUIRE_APPROVAL' ELSE 'PASS' END
                ELSE 'SKIP'
            END AS verdict,
            pr.enforcement
        FROM a
        JOIN CUSTOMER_360_DB.CONFIG.POLICY_RULE pr ON pr.domain_id = a.domain_id AND pr.active = TRUE
        ORDER BY pr.policy_id
    );
    RETURN TABLE(res);
END;
$$;

-- Authority check as a scalar, so the UI can gate buttons cheaply.
CREATE OR REPLACE FUNCTION AUTHORITY_CHECK(P_ACTION_ID VARCHAR, P_PERSONA VARCHAR, P_OFFER_AMOUNT FLOAT)
RETURNS OBJECT
AS
$$
    SELECT OBJECT_CONSTRUCT(
        'requires_approval', ad.requires_approval,
        'needed',            GREATEST(COALESCE(P_OFFER_AMOUNT,0), ad.approval_threshold),
        'persona_limit',     pl.max_approval_inr,
        'config_limit',      up.max_approval_value,
        'authorised',        CASE WHEN NOT ad.requires_approval THEN TRUE
                                  WHEN pl.max_approval_inr >= GREATEST(COALESCE(P_OFFER_AMOUNT,0), ad.approval_threshold)
                                  THEN TRUE ELSE FALSE END,
        'authorised_under_config', CASE WHEN NOT ad.requires_approval THEN TRUE
                                  WHEN up.max_approval_value >= GREATEST(COALESCE(P_OFFER_AMOUNT,0), ad.approval_threshold)
                                  THEN TRUE ELSE FALSE END
    )
    FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad
    CROSS JOIN CUSTOMER_360_DB.APP_V2.PERSONA_LIMIT pl
    CROSS JOIN CUSTOMER_360_DB.CONFIG.USER_PERSONA up
    WHERE ad.action_id = P_ACTION_ID AND pl.persona_id = P_PERSONA AND up.persona_id = P_PERSONA
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- EXECUTE_ACTION — writes the recommendation and the execution, performs a real
-- side effect in the system of record, and logs the notification. These are the
-- five ENGINE tables that have never held a row.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE EXECUTE_ACTION(
    P_CUSTOMER_ID VARCHAR, P_ACTION_ID VARCHAR, P_PERSONA VARCHAR,
    P_OFFER_AMOUNT FLOAT, P_NOTES VARCHAR, P_RUN_ID VARCHAR)
RETURNS OBJECT LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_state VARCHAR; v_state_name VARCHAR; v_name VARCHAR;
    v_action_name VARCHAR; v_needs BOOLEAN; v_stamp VARCHAR;
    v_rec VARCHAR; v_exec VARCHAR; v_log VARCHAR;
    v_claim VARCHAR; v_msg VARCHAR; v_side VARCHAR := 'none'; v_prev_state VARCHAR;
    v_auth OBJECT;
BEGIN
    v_stamp := TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');
    v_dom        := (SELECT domain     FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE WHERE customer_id=:P_CUSTOMER_ID AND is_current LIMIT 1);
    v_state      := (SELECT state_id   FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE WHERE customer_id=:P_CUSTOMER_ID AND is_current LIMIT 1);
    v_state_name := (SELECT state_name FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE WHERE customer_id=:P_CUSTOMER_ID AND is_current LIMIT 1);
    v_name       := (SELECT full_name  FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER    WHERE customer_id=:P_CUSTOMER_ID LIMIT 1);
    v_action_name:= (SELECT action_name FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION WHERE action_id=:P_ACTION_ID);
    v_needs      := (SELECT requires_approval FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION WHERE action_id=:P_ACTION_ID);
    v_prev_state := (SELECT state_name FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
                     WHERE customer_id = :P_CUSTOMER_ID AND is_current = FALSE
                     ORDER BY effective_to DESC LIMIT 1);
    v_auth := CUSTOMER_360_DB.APP_V2.AUTHORITY_CHECK(:P_ACTION_ID, :P_PERSONA, :P_OFFER_AMOUNT);

    IF (v_auth:authorised::BOOLEAN = FALSE) THEN
        RETURN OBJECT_CONSTRUCT('status','BLOCKED',
            'reason','Persona ' || :P_PERSONA || ' may approve up to ' ||
                     TO_VARCHAR(v_auth:persona_limit::FLOAT) || ' but this needs ' ||
                     TO_VARCHAR(v_auth:needed::FLOAT),
            'authority', v_auth);
    END IF;

    -- recommendation row (what we decided, and why)
    v_rec := 'rec-v2-' || :P_CUSTOMER_ID || '-' || :v_stamp;
    INSERT INTO CUSTOMER_360_DB.ENGINE.ACTION_RECOMMENDATION (recommendation_id, customer_id, queue_id, action_id,
        action_name, domain, score, effectiveness_rate, expected_uplift, expected_value,
        action_cost, confidence, ranking, requires_approval, status, created_at)
    SELECT :v_rec, :P_CUSTOMER_ID,
        (SELECT queue_id FROM CUSTOMER_360_DB.ENGINE.DECISION_QUEUE WHERE customer_id=:P_CUSTOMER_ID
           AND status='PENDING' ORDER BY created_at DESC LIMIT 1),
        :P_ACTION_ID, :v_action_name, :v_dom,
        COALESCE(ae.success_rate,0.3), COALESCE(ae.success_rate,0.3), COALESCE(ae.avg_uplift,0.05),
        (SELECT relationship_value FROM CUSTOMER_360_DB.APP_V2.V_RELATIONSHIP_VALUE
           WHERE customer_id=:P_CUSTOMER_ID AND domain=:v_dom) * COALESCE(ae.success_rate,0.3) * COALESCE(ae.avg_uplift,0.05),
        ad.default_cost + CASE WHEN ad.requires_approval THEN COALESCE(:P_OFFER_AMOUNT,0) ELSE 0 END,
        COALESCE(ae.confidence,0.4), 1, ad.requires_approval, 'EXECUTED', CURRENT_TIMESTAMP()
    FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad
    LEFT JOIN CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS ae
      ON ae.action_id=ad.action_id AND ae.state_id=:v_state AND ae.domain_id=:v_dom
    WHERE ad.action_id = :P_ACTION_ID;

    -- execution row
    v_exec := 'exec-v2-' || :P_CUSTOMER_ID || '-' || :v_stamp;
    INSERT INTO CUSTOMER_360_DB.ENGINE.ACTION_EXECUTION (execution_id, recommendation_id, customer_id, action_id,
        action_name, domain, execution_type, executed_by, approved_by, execution_notes, status, executed_at)
    VALUES (:v_exec, :v_rec, :P_CUSTOMER_ID, :P_ACTION_ID, :v_action_name, :v_dom,
        CASE WHEN :v_needs THEN 'APPROVED' ELSE 'AUTONOMOUS' END,
        :P_PERSONA, CASE WHEN :v_needs THEN :P_PERSONA ELSE NULL END,
        COALESCE(:P_NOTES,'') || CASE WHEN COALESCE(:P_OFFER_AMOUNT,0) > 0
            THEN ' | offer INR ' || TO_VARCHAR(:P_OFFER_AMOUNT) ELSE '' END,
        'COMPLETED', CURRENT_TIMESTAMP());

    -- real side effect in the system of record, which the pipeline can then see
    IF (P_ACTION_ID = 'ins_claim_escalation') THEN
        v_claim := (SELECT claim_id FROM CUSTOMER_360_DB.RAW.INSURANCE_CLAIMS
                    WHERE customer_id=:P_CUSTOMER_ID AND claim_status='PENDING'
                    ORDER BY filed_date LIMIT 1);
        IF (v_claim IS NOT NULL) THEN
            UPDATE CUSTOMER_360_DB.RAW.INSURANCE_CLAIMS SET claim_status='PRIORITY', updated_at=CURRENT_TIMESTAMP()
            WHERE claim_id = :v_claim;
            v_side := 'claim ' || :v_claim || ' set to PRIORITY';
            INSERT INTO CUSTOMER_360_DB.APP_V2.RUN_ARTIFACT (run_id, object_type, object_id, detail)
            VALUES (:P_RUN_ID,'CLAIM_STATUS', :v_claim, 'PENDING -> PRIORITY');
        END IF;
    END IF;

    -- notification, rendered from the configured template
    v_msg := (SELECT REPLACE(REPLACE(REPLACE(REPLACE(nr.message_template,
                   '{{customer_name}}', :v_name),
                   '{{new_state}}',     :v_state_name),
                   '{{old_state}}',     COALESCE(:v_prev_state,'none')),
                   '{{top_action}}',    :v_action_name)
              FROM CUSTOMER_360_DB.CONFIG.NOTIFICATION_RULE nr
              WHERE nr.domain_id=:v_dom AND nr.active=TRUE ORDER BY nr.rule_id LIMIT 1);
    v_log := 'log-v2-' || :P_CUSTOMER_ID || '-' || :v_stamp;
    INSERT INTO CUSTOMER_360_DB.ENGINE.NOTIFICATION_LOG (log_id, channel_id, channel_type, event_type,
        customer_id, domain, message, status, sent_at)
    VALUES (:v_log, 'ch_email', 'EMAIL', 'ACTION_EXECUTED', :P_CUSTOMER_ID, :v_dom,
        COALESCE(:v_msg, :v_action_name || ' executed for ' || :v_name), 'RENDERED', CURRENT_TIMESTAMP());

    INSERT INTO CUSTOMER_360_DB.APP_V2.RUN_ARTIFACT (run_id, object_type, object_id, detail)
      VALUES (:P_RUN_ID,'RECOMMENDATION', :v_rec, :v_action_name);
    INSERT INTO CUSTOMER_360_DB.APP_V2.RUN_ARTIFACT (run_id, object_type, object_id, detail)
      VALUES (:P_RUN_ID,'EXECUTION', :v_exec, :v_side);
    INSERT INTO CUSTOMER_360_DB.APP_V2.RUN_ARTIFACT (run_id, object_type, object_id, detail)
      VALUES (:P_RUN_ID,'NOTIFICATION', :v_log, NULL);

    RETURN OBJECT_CONSTRUCT('status','EXECUTED','execution_id',:v_exec,
        'recommendation_id',:v_rec,'notification_id',:v_log,
        'side_effect',:v_side,'message',:v_msg,'authority',v_auth);
END;
$$;

SELECT 'APP_V2 decisioning procedures created' AS status;
