-- =============================================================================
-- UniGo — Module D: Trust & Reputation
-- File: D1_triggers.sql
-- Description: 5 Triggers for trust auditing, seat management, and reputation
-- Database: Oracle 21c XE
-- =============================================================================

-- =============================================================================
-- TRIGGER 1: trg_trust_on_join
-- Fires AFTER INSERT on Group_Members
-- Awards +5 trust to the joining student and logs the change in Trust_Audit_Log
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_join
AFTER INSERT ON Group_Members
FOR EACH ROW
DECLARE
    v_old_score   Students.trust_score%TYPE;
    v_new_score   Students.trust_score%TYPE;
BEGIN
    -- Fetch current trust score
    SELECT trust_score INTO v_old_score
    FROM Students
    WHERE student_id = :NEW.student_id;

    -- Calculate new score (capped at 200)
    v_new_score := LEAST(v_old_score + 5, 200);

    -- Update student trust score
    UPDATE Students
    SET trust_score = v_new_score
    WHERE student_id = :NEW.student_id;

    -- Log the audit trail
    INSERT INTO Trust_Audit_Log (
        audit_id,
        student_id,
        old_score,
        new_score,
        reason,
        created_at
    ) VALUES (
        trust_audit_seq.NEXTVAL,
        :NEW.student_id,
        v_old_score,
        v_new_score,
        'JOINED group ' || :NEW.group_id,
        SYSDATE
    );
END trg_trust_on_join;
/

-- =============================================================================
-- TRIGGER 2: trg_trust_on_cancel
-- Fires AFTER DELETE on Group_Members
-- Penalizes -15 trust to the cancelling student and logs the change
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_trust_on_cancel
AFTER DELETE ON Group_Members
FOR EACH ROW
DECLARE
    v_old_score   Students.trust_score%TYPE;
    v_new_score   Students.trust_score%TYPE;
BEGIN
    -- Fetch current trust score
    SELECT trust_score INTO v_old_score
    FROM Students
    WHERE student_id = :OLD.student_id;

    -- Calculate new score (floored at 0)
    v_new_score := GREATEST(v_old_score - 15, 0);

    -- Update student trust score
    UPDATE Students
    SET trust_score = v_new_score
    WHERE student_id = :OLD.student_id;

    -- Log the audit trail
    INSERT INTO Trust_Audit_Log (
        audit_id,
        student_id,
        old_score,
        new_score,
        reason,
        created_at
    ) VALUES (
        trust_audit_seq.NEXTVAL,
        :OLD.student_id,
        v_old_score,
        v_new_score,
        'CANCELLED from group ' || :OLD.group_id,
        SYSDATE
    );
END trg_trust_on_cancel;
/

-- =============================================================================
-- TRIGGER 3: trg_seats_on_join
-- Fires AFTER INSERT on Group_Members
-- Increments seats_filled by 1 and total_luggage by the student's luggage_count
-- on the parent Ride_Groups row
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_seats_on_join
AFTER INSERT ON Group_Members
FOR EACH ROW
DECLARE
    v_luggage   Trip_Requests.luggage_count%TYPE;
BEGIN
    -- Look up luggage count from the student's active trip request
    -- matching this group's destination
    SELECT tr.luggage_count INTO v_luggage
    FROM Trip_Requests tr
    JOIN Ride_Groups rg ON rg.destination_id = tr.destination_id
    WHERE tr.student_id = :NEW.student_id
      AND rg.group_id  = :NEW.group_id
      AND tr.status     = 'ACTIVE'
      AND ROWNUM        = 1;

    -- Update the ride group counters
    UPDATE Ride_Groups
    SET seats_filled = seats_filled + 1,
        total_luggage = total_luggage + v_luggage
    WHERE group_id = :NEW.group_id;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- If no matching trip request found, just increment seat count
        UPDATE Ride_Groups
        SET seats_filled = seats_filled + 1
        WHERE group_id = :NEW.group_id;
END trg_seats_on_join;
/

-- =============================================================================
-- TRIGGER 4: trg_seats_on_leave
-- Fires AFTER DELETE on Group_Members
-- Decrements seats_filled by 1 and total_luggage by the student's luggage_count
-- on the parent Ride_Groups row
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_seats_on_leave
AFTER DELETE ON Group_Members
FOR EACH ROW
DECLARE
    v_luggage   Trip_Requests.luggage_count%TYPE;
BEGIN
    -- Look up luggage count from the student's trip request
    SELECT tr.luggage_count INTO v_luggage
    FROM Trip_Requests tr
    JOIN Ride_Groups rg ON rg.destination_id = tr.destination_id
    WHERE tr.student_id = :OLD.student_id
      AND rg.group_id  = :OLD.group_id
      AND ROWNUM        = 1;

    -- Update the ride group counters
    UPDATE Ride_Groups
    SET seats_filled  = GREATEST(seats_filled - 1, 0),
        total_luggage = GREATEST(total_luggage - v_luggage, 0)
    WHERE group_id = :OLD.group_id;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- If no matching trip request found, just decrement seat count
        UPDATE Ride_Groups
        SET seats_filled = GREATEST(seats_filled - 1, 0)
        WHERE group_id = :OLD.group_id;
END trg_seats_on_leave;
/

-- =============================================================================
-- TRIGGER 5: trg_trust_on_completion
-- Fires AFTER UPDATE on Ride_Groups
-- When status changes to 'COMPLETED', awards +10 trust and +1 total_rides
-- to ALL members of that group, logging each in Trust_Audit_Log
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
        -- Fetch current trust score
        SELECT trust_score INTO v_old_score
        FROM Students
        WHERE student_id = member.student_id;

        -- Calculate new score (capped at 200)
        v_new_score := LEAST(v_old_score + 10, 200);

        -- Update trust score and ride count
        UPDATE Students
        SET trust_score = v_new_score,
            total_rides = total_rides + 1
        WHERE student_id = member.student_id;

        -- Log the audit trail
        INSERT INTO Trust_Audit_Log (
            audit_id,
            student_id,
            old_score,
            new_score,
            reason,
            created_at
        ) VALUES (
            trust_audit_seq.NEXTVAL,
            member.student_id,
            v_old_score,
            v_new_score,
            'COMPLETED ride in group ' || :NEW.group_id,
            SYSDATE
        );
    END LOOP;
END trg_trust_on_completion;
/

-- =============================================================================
-- TRIGGER 6: trg_block_priority_cancel
-- Fires BEFORE DELETE on Group_Members
-- PREVENTS cancellation of PriorityGo bookings (payment_status = 'PAID')
-- PriorityGo = pay first, guaranteed seat. Cannot back out.
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
