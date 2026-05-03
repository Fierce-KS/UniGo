-- =============================================================================
-- UniGo — Module D: Trust & Reputation
-- File: D2_function.sql
-- Description: calculate_travel_risk PL/SQL Function
-- Database: Oracle 21c XE
-- =============================================================================

-- =============================================================================
-- FUNCTION: calculate_travel_risk
--
-- Purpose:
--   Evaluates whether a student with a connecting flight/train has enough
--   time buffer between their estimated arrival and their connection departure.
--
-- Parameters:
--   p_connection_time_hrs  — Hours available before the student's connection
--   p_destination_id       — FK to Destinations table (to look up avg_travel_hours)
--   p_buffer_factor        — Safety multiplier (default 1.3 = 30% buffer)
--
-- Returns:
--   'SAFE'                — Gap >= 2 hours (comfortable buffer)
--   'RISKY'               — Gap >= 0 but < 2 hours (tight but possible)
--   'CRITICAL'            — Gap < 0 hours (will likely miss connection)
--   'UNKNOWN_DESTINATION' — Destination ID not found in table
--   'ERROR: ...'          — Any unexpected error with message
--
-- Used By:
--   Module B (find_travel_buddies) to flag risky matches for PriorityGo students
--   Module E (Frontend) to display risk assessment in the Travel Risk Calculator
-- =============================================================================
CREATE OR REPLACE FUNCTION calculate_travel_risk (
    p_connection_time_hrs   IN NUMBER,
    p_destination_id        IN NUMBER,
    p_buffer_factor         IN NUMBER DEFAULT 1.3
) RETURN VARCHAR2 AS
    v_avg_travel    NUMBER;
    v_required      NUMBER;
    v_gap           NUMBER;
BEGIN
    -- Look up average travel hours for the destination
    SELECT avg_travel_hours INTO v_avg_travel
    FROM Destinations
    WHERE destination_id = p_destination_id;

    -- Calculate required time with safety buffer
    v_required := v_avg_travel * p_buffer_factor;

    -- Calculate the gap between available time and required time
    v_gap := p_connection_time_hrs - v_required;

    -- Return risk classification
    IF v_gap >= 2 THEN
        RETURN 'SAFE';
    ELSIF v_gap >= 0 THEN
        RETURN 'RISKY';
    ELSE
        RETURN 'CRITICAL';
    END IF;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'UNKNOWN_DESTINATION';
    WHEN OTHERS THEN
        RETURN 'ERROR: ' || SQLERRM;
END calculate_travel_risk;
/

-- =============================================================================
-- FUNCTION: check_priority_eligibility
--
-- Purpose:
--   Determines if a student qualifies for PriorityGo (pay-first guaranteed
--   ride). Eligibility is based on trust score — students who consistently
--   follow through on commitments (trust >= 90) earn this privilege.
--
-- Parameters:
--   p_student_id — FK to Students table
--
-- Returns:
--   'ELIGIBLE'              — Student trust >= 90, can use PriorityGo
--   'NOT_ELIGIBLE:XX'       — Trust score XX is below 90 threshold
--   'STUDENT_NOT_FOUND'     — Student ID does not exist
-- =============================================================================
CREATE OR REPLACE FUNCTION check_priority_eligibility (
    p_student_id IN NUMBER
) RETURN VARCHAR2 AS
    v_trust   Students.trust_score%TYPE;
BEGIN
    SELECT trust_score INTO v_trust
    FROM Students
    WHERE student_id = p_student_id;

    IF v_trust >= 90 THEN
        RETURN 'ELIGIBLE';
    ELSE
        RETURN 'NOT_ELIGIBLE:' || v_trust;
    END IF;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'STUDENT_NOT_FOUND';
END check_priority_eligibility;
/

-- =============================================================================
-- PROCEDURE: log_trust_change
--
-- Purpose:
--   Inserts a trust audit record. This is called by Module C triggers to
--   avoid direct cross-module writes to Trust_Audit_Log.
-- =============================================================================
CREATE OR REPLACE PROCEDURE log_trust_change (
    p_student_id IN NUMBER,
    p_old_score  IN Trust_Audit_Log.old_score%TYPE,
    p_new_score  IN Trust_Audit_Log.new_score%TYPE,
    p_reason     IN Trust_Audit_Log.reason%TYPE
) AS
BEGIN
    INSERT INTO Trust_Audit_Log (
        audit_id, 
        student_id,
        old_score, 
        new_score, 
        reason, 
        changed_at
    ) VALUES (
        trust_audit_seq.NEXTVAL, 
        p_student_id, 
        p_old_score, 
        p_new_score, 
        p_reason, 
        SYSTIMESTAMP
    );
END log_trust_change;
/

-- =============================================================================
-- End of D2_function.sql
-- =============================================================================
