-- =============================================================================
-- UniGo — Module D: Trust & Reputation
-- File: D1_triggers.sql
-- Description: All 5 triggers for trust management, seat sync, audit immutability
-- Database: Oracle 21c XE
-- Run order: 2nd — after A1_ddl.sql, before B1_views_and_proc.sql
--
-- Triggers delivered:
--   1. trg_seat_sync            — AFTER INSERT OR DELETE on Group_Members
--                                 Keeps seats_filled + total_luggage in sync
--   2. trg_trust_on_completion  — AFTER UPDATE OF status ON Ride_Groups
--                                 Awards +10 trust + 1 ride to all members
--   3. trg_trust_on_cancellation— AFTER DELETE on Group_Members
--                                 Deducts -15 trust (floor 0) on cancellation
--   4. trg_immutable_audit      — BEFORE UPDATE OR DELETE on Trust_Audit_Log
--                                 Blocks all modifications — audit log is write-only
--
-- Design note:
--   Triggers call log_trust_change() (D2_function.sql) instead of directly
--   writing to Trust_Audit_Log. This is the correct cross-module pattern —
--   Module D triggers don't bypass the procedure contract.
-- =============================================================================


-- =============================================================================
-- TRIGGER 1: trg_seat_sync
-- Fires AFTER every INSERT or DELETE on Group_Members.
-- Recomputes seats_filled and total_luggage from actual membership count.
--
-- Why recompute instead of +1/-1?
--   Computing from scratch is idempotent — if data ever drifts (manual fix,
--   bulk load), the trigger self-corrects rather than compounding the error.
--
-- luggage_count comes from the student's OPEN trip request for that destination.
-- If no trip request found, defaults to 0 (student booked directly).
-- =============================================================================
-- Compound trigger avoids the ORA-04091 mutating table error.
-- Row-level section captures which group was affected.
-- Statement-level section runs AFTER all rows are processed,
-- at which point GROUP_MEMBERS is stable and can be queried.
CREATE OR REPLACE TRIGGER trg_seat_sync
FOR INSERT OR DELETE ON Group_Members
COMPOUND TRIGGER

    -- Package-level variable shared between sections
    v_group_id  NUMBER;

    AFTER EACH ROW IS
    BEGIN
        IF INSERTING THEN
            v_group_id := :NEW.group_id;
        ELSE
            v_group_id := :OLD.group_id;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_filled   NUMBER;
        v_luggage  NUMBER;
        v_dest_id  NUMBER;
    BEGIN
        -- Get destination for luggage lookup
        SELECT destination_id INTO v_dest_id
        FROM Ride_Groups
        WHERE group_id = v_group_id;

        -- Count members — safe here, statement is complete
        SELECT COUNT(*) INTO v_filled
        FROM Group_Members
        WHERE group_id = v_group_id;

        -- Sum luggage from each member's open trip request
        SELECT NVL(SUM(
            (SELECT NVL(tr.luggage_count, 0)
             FROM Trip_Requests tr
             WHERE tr.student_id     = gm.student_id
               AND tr.destination_id = v_dest_id
               AND tr.status         = 'OPEN'
               AND ROWNUM            = 1)
        ), 0) INTO v_luggage
        FROM Group_Members gm
        WHERE gm.group_id = v_group_id;

        -- Update the denormalised columns
        UPDATE Ride_Groups
        SET seats_filled  = v_filled,
            total_luggage = v_luggage
        WHERE group_id = v_group_id;

    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20001,
                'trg_seat_sync failed for group ' || v_group_id || ': ' || SQLERRM);
    END AFTER STATEMENT;

END trg_seat_sync;
/


-- =============================================================================
-- TRIGGER 2: trg_trust_on_completion
-- Fires AFTER UPDATE OF status on Ride_Groups.
-- Only activates when status transitions TO 'COMPLETED'.
-- Awards every current member: trust_score + 10, total_rides + 1.
-- Logs each change via log_trust_change().
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_completion
AFTER UPDATE OF status ON Ride_Groups
FOR EACH ROW
WHEN (NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED')
DECLARE
    CURSOR c_members IS
        SELECT student_id FROM Group_Members
        WHERE group_id = :NEW.group_id;

    v_old_trust     Students.trust_score%TYPE;
    v_new_trust     Students.trust_score%TYPE;
BEGIN
    FOR rec IN c_members LOOP
        -- Read current trust
        SELECT trust_score INTO v_old_trust
        FROM Students
        WHERE student_id = rec.student_id;

        -- Cap at 200 (CHECK constraint upper bound)
        v_new_trust := LEAST(v_old_trust + 10, 200);

        -- Apply trust reward and ride count increment
        UPDATE Students
        SET trust_score = v_new_trust,
            total_rides = total_rides + 1
        WHERE student_id = rec.student_id;

        -- Write audit entry via the Module D procedure
        log_trust_change(
            p_student_id => rec.student_id,
            p_old_score  => v_old_trust,
            p_new_score  => v_new_trust,
            p_reason     => 'Ride completed — group ' || :NEW.group_id || ' (+10 trust)'
        );
    END LOOP;

EXCEPTION
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20002,
            'trg_trust_on_completion failed for group ' || :NEW.group_id || ': ' || SQLERRM);
END trg_trust_on_completion;
/


-- =============================================================================
-- TRIGGER 3: trg_trust_on_cancellation
-- Fires AFTER DELETE on Group_Members.
-- Deducts 15 trust points (floored at 0) when a student leaves a group.
-- Logs the change via log_trust_change().
--
-- Note: This fires on ANY delete from Group_Members — including cascades.
-- The -15 penalty is intentional: cancellation hurts the group.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_cancellation
AFTER DELETE ON Group_Members
FOR EACH ROW
DECLARE
    v_old_trust     Students.trust_score%TYPE;
    v_new_trust     Students.trust_score%TYPE;
BEGIN
    -- Read current trust score
    SELECT trust_score INTO v_old_trust
    FROM Students
    WHERE student_id = :OLD.student_id;

    -- Floor at 0 — trust cannot go negative
    v_new_trust := GREATEST(v_old_trust - 15, 0);

    -- Apply penalty
    UPDATE Students
    SET trust_score = v_new_trust
    WHERE student_id = :OLD.student_id;

    -- Write audit entry
    log_trust_change(
        p_student_id => :OLD.student_id,
        p_old_score  => v_old_trust,
        p_new_score  => v_new_trust,
        p_reason     => 'Booking cancelled — group ' || :OLD.group_id || ' (-15 trust)'
    );

EXCEPTION
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20003,
            'trg_trust_on_cancellation failed for student ' || :OLD.student_id || ': ' || SQLERRM);
END trg_trust_on_cancellation;
/


-- =============================================================================
-- TRIGGER 4: trg_immutable_audit
-- Fires BEFORE any UPDATE or DELETE on Trust_Audit_Log.
-- Raises an application error — the audit log is permanently write-only.
-- Even DBA-level manual corrections go through log_trust_change(), never direct edits.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_immutable_audit
BEFORE UPDATE OR DELETE ON Trust_Audit_Log
FOR EACH ROW
BEGIN
    RAISE_APPLICATION_ERROR(-20004,
        'Trust_Audit_Log is immutable. Records cannot be modified or deleted.');
END trg_immutable_audit;
/


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these after loading triggers to confirm they compiled correctly.
-- =============================================================================

-- Confirm all 4 triggers exist and are ENABLED
SELECT trigger_name, status, triggering_event, trigger_type
FROM user_triggers
WHERE table_name IN ('GROUP_MEMBERS', 'RIDE_GROUPS', 'TRUST_AUDIT_LOG')
ORDER BY table_name, trigger_name;

-- =============================================================================
-- End of D1_triggers.sql
-- =============================================================================