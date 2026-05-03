-- =============================================================================
-- UniGo - Module D: Trust & Reputation
-- File: D1_triggers.sql
-- Description: Triggers owned by Module C (Group_Members, Ride_Groups).
--              Cross-module updates are done via procedure calls.
-- Database: Oracle 21c XE
-- =============================================================================
-- Required procedures (to be implemented by owning modules):
--   Module A:
--     apply_trust_delta(
--       p_student_id IN NUMBER,
--       p_delta IN NUMBER,
--       p_old OUT NUMBER,
--       p_new OUT NUMBER,
--       p_add_ride IN NUMBER DEFAULT 0
--     )
--     -- Updates Students.trust_score (cap 0..200) and increments total_rides
--     -- when p_add_ride = 1.
--
--   Module D:
--     log_trust_change(
--       p_student_id IN NUMBER,
--       p_old IN NUMBER,
--       p_new IN NUMBER,
--       p_reason IN VARCHAR2
--     )
--     -- Inserts into Trust_Audit_Log.
--
-- Required table and sequence (Module C):
--   group_log_seq
--   Ride_Group_Log(
--     log_id NUMBER(10) PK,
--     group_id NUMBER(10) FK -> Ride_Groups,
--     event VARCHAR2(30),
--     detail VARCHAR2(200),
--     created_at DATE
--   )
-- =============================================================================

-- =============================================================================
-- TRIGGER 1: trg_trust_on_join
-- Fires AFTER INSERT on Group_Members
-- Awards +5 trust to the joining student and logs the change.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_join
AFTER INSERT ON Group_Members
FOR EACH ROW
DECLARE
    v_old_score   Students.trust_score%TYPE;
    v_new_score   Students.trust_score%TYPE;
BEGIN
    apply_trust_delta(:NEW.student_id, 5, v_old_score, v_new_score, 0);
    log_trust_change(
        :NEW.student_id,
        v_old_score,
        v_new_score,
        'JOINED group ' || :NEW.group_id
    );
END trg_trust_on_join;
/

-- =============================================================================
-- TRIGGER 2: trg_trust_on_cancel
-- Fires AFTER DELETE on Group_Members
-- Penalizes -15 trust to the cancelling student and logs the change.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_cancel
AFTER DELETE ON Group_Members
FOR EACH ROW
DECLARE
    v_old_score   Students.trust_score%TYPE;
    v_new_score   Students.trust_score%TYPE;
BEGIN
    apply_trust_delta(:OLD.student_id, -15, v_old_score, v_new_score, 0);
    log_trust_change(
        :OLD.student_id,
        v_old_score,
        v_new_score,
        'CANCELLED from group ' || :OLD.group_id
    );
END trg_trust_on_cancel;
/

-- =============================================================================
-- TRIGGER 3: trg_seats_on_join
-- Fires AFTER INSERT on Group_Members
-- Increments seats_filled by 1 and total_luggage by the student's luggage_count
-- on the parent Ride_Groups row.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_seats_on_join
AFTER INSERT ON Group_Members
FOR EACH ROW
DECLARE
    v_luggage   Trip_Requests.luggage_count%TYPE;
    v_prev_seats Ride_Groups.seats_filled%TYPE;
BEGIN
    SELECT seats_filled INTO v_prev_seats
    FROM Ride_Groups
    WHERE group_id = :NEW.group_id;

    BEGIN
        SELECT tr.luggage_count INTO v_luggage
        FROM Trip_Requests tr
        JOIN Ride_Groups rg ON rg.destination_id = tr.destination_id
        WHERE tr.student_id = :NEW.student_id
          AND rg.group_id  = :NEW.group_id
          AND tr.status     = 'ACTIVE'
          AND ROWNUM        = 1;

        UPDATE Ride_Groups
        SET seats_filled = seats_filled + 1,
            total_luggage = total_luggage + v_luggage
        WHERE group_id = :NEW.group_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            UPDATE Ride_Groups
            SET seats_filled = seats_filled + 1
            WHERE group_id = :NEW.group_id;
    END;

    IF v_prev_seats < 3 AND v_prev_seats + 1 >= 3 THEN
        INSERT INTO Ride_Group_Log (
            log_id,
            group_id,
            event,
            detail,
            created_at
        ) VALUES (
            group_log_seq.NEXTVAL,
            :NEW.group_id,
            'THRESHOLD_REACHED',
            'Group reached minimum size of 3',
            SYSDATE
        );
    END IF;
END trg_seats_on_join;
/

-- =============================================================================
-- TRIGGER 4: trg_seats_on_leave
-- Fires AFTER DELETE on Group_Members
-- Decrements seats_filled by 1 and total_luggage by the student's luggage_count
-- on the parent Ride_Groups row.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_seats_on_leave
AFTER DELETE ON Group_Members
FOR EACH ROW
DECLARE
    v_luggage   Trip_Requests.luggage_count%TYPE;
BEGIN
    SELECT tr.luggage_count INTO v_luggage
    FROM Trip_Requests tr
    JOIN Ride_Groups rg ON rg.destination_id = tr.destination_id
    WHERE tr.student_id = :OLD.student_id
      AND rg.group_id  = :OLD.group_id
      AND ROWNUM        = 1;

    UPDATE Ride_Groups
    SET seats_filled  = GREATEST(seats_filled - 1, 0),
        total_luggage = GREATEST(total_luggage - v_luggage, 0)
    WHERE group_id = :OLD.group_id;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        UPDATE Ride_Groups
        SET seats_filled = GREATEST(seats_filled - 1, 0)
        WHERE group_id = :OLD.group_id;
END trg_seats_on_leave;
/

-- =============================================================================
-- TRIGGER 5: trg_trust_on_completion
-- Fires AFTER UPDATE on Ride_Groups
-- When status changes to 'COMPLETED', awards +10 trust and +1 total_rides
-- to ALL members of that group, logging each change.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_completion
AFTER UPDATE OF status ON Ride_Groups
FOR EACH ROW
WHEN (OLD.status != 'COMPLETED' AND NEW.status = 'COMPLETED')
DECLARE
    CURSOR c_members IS
        SELECT student_id
        FROM Group_Members
        WHERE group_id = :NEW.group_id;

    v_old_score   Students.trust_score%TYPE;
    v_new_score   Students.trust_score%TYPE;
BEGIN
    FOR member IN c_members LOOP
        apply_trust_delta(member.student_id, 10, v_old_score, v_new_score, 1);
        log_trust_change(
            member.student_id,
            v_old_score,
            v_new_score,
            'COMPLETED ride in group ' || :NEW.group_id
        );
    END LOOP;
END trg_trust_on_completion;
/

-- =============================================================================
-- TRIGGER 6: trg_block_priority_cancel
-- Fires BEFORE DELETE on Group_Members
-- Prevents cancellation of PriorityGo bookings (payment_status = 'PAID').
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_block_priority_cancel
BEFORE DELETE ON Group_Members
FOR EACH ROW
BEGIN
    IF :OLD.payment_status = 'PAID' THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'PriorityGo booking cannot be cancelled. Payment is guaranteed for student '
            || :OLD.student_id || ' in group ' || :OLD.group_id
        );
    END IF;
END trg_block_priority_cancel;
/

-- =============================================================================
-- End of D1_triggers.sql
-- =============================================================================
