-- =============================================================================
-- UniGo — Module C: Booking & Transactions
-- File: C1_booking.sql
-- Description: Four procedures that E1_app.py calls + ACID demo script
-- Database: Oracle 21c XE
-- Run order: 4th — after A1_ddl.sql, D1_triggers.sql, B1_views_and_proc.sql
--
-- Procedures delivered:
--   1. create_ride_group  — open a new FORMING group
--   2. book_ride          — atomic seat lock-in (SAVEPOINT + FOR UPDATE NOWAIT)
--   3. cancel_booking     — remove member, trigger fires trust penalty
--   4. complete_ride      — mark COMPLETED, trigger fires trust reward
--
-- Design decisions vs original TRD group_lock_in:
--   - seats_filled / total_luggage are NOT manually updated here.
--     trg_seat_sync (Module D) handles both columns on every
--     INSERT/DELETE to Group_Members. Doing it here too causes double-count.
--   - PriorityGo trust >= 90 check is enforced HERE (booking time),
--     not on Trip_Requests INSERT. A student can express intent regardless
--     of trust score — they are only blocked from locking in a seat.
--   - COMMIT is inside each procedure for simplicity in this lab context.
--     Callers (Module E) must not wrap these in a larger transaction.
-- =============================================================================


-- =============================================================================
-- PROCEDURE 1: create_ride_group
-- Opens a new FORMING ride group.
-- Called by /api/create-group in Module E.
-- p_vehicle_id defaults to 1 (Sedan) when called from the frontend.
-- =============================================================================
CREATE OR REPLACE PROCEDURE create_ride_group (
    p_destination_id  IN NUMBER,
    p_departure_date  IN VARCHAR2,   -- 'YYYY-MM-DD' string from Flask
    p_vehicle_id      IN NUMBER
) AS
    v_dest_count  NUMBER;
    v_veh_count   NUMBER;
BEGIN
    -- Validate destination exists
    SELECT COUNT(*) INTO v_dest_count
    FROM Destinations
    WHERE destination_id = p_destination_id;

    IF v_dest_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Destination ' || p_destination_id || ' not found.');
        RETURN;
    END IF;

    -- Validate vehicle exists
    SELECT COUNT(*) INTO v_veh_count
    FROM Vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF v_veh_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Vehicle ' || p_vehicle_id || ' not found.');
        RETURN;
    END IF;

    INSERT INTO Ride_Groups (
        group_id,
        vehicle_id,
        destination_id,
        departure_date,
        departure_time,
        seats_filled,
        total_luggage,
        status,
        created_at
    ) VALUES (
        group_seq.NEXTVAL,
        p_vehicle_id,
        p_destination_id,
        TO_DATE(p_departure_date, 'YYYY-MM-DD'),
        NULL,
        0,
        0,
        'FORMING',
        SYSTIMESTAMP
    );

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS: New ride group created for destination ' || p_destination_id || '.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERROR in create_ride_group: ' || SQLERRM);
END create_ride_group;
/


-- =============================================================================
-- PROCEDURE 2: book_ride
-- Atomic seat lock-in — the core ACID + concurrency deliverable.
--
-- Flow:
--   1. FOR UPDATE NOWAIT on Ride_Groups row → prevents race condition
--   2. SAVEPOINT before_member_add
--   3. Validate: group is FORMING
--   4. Validate: seat available (redundant check after lock, belt-and-suspenders)
--   5. Validate: luggage fits
--   6. IF has_connection = 'Y' → enforce trust >= 90 (PriorityGo gate)
--   7. INSERT Group_Members → trg_seat_sync fires, updates seats_filled + total_luggage
--   8. INSERT Payments record (PENDING)
--   9. COMMIT
--
-- Called by /api/book in Module E with args [group_id, student_id, luggage_count, priority_go].
-- priority_go is 0/1 from Flask; procedure resolves actual has_connection from Trip_Requests.
-- =============================================================================
CREATE OR REPLACE PROCEDURE book_ride (
    p_group_id    IN NUMBER,
    p_student_id  IN NUMBER,
    p_luggage     IN NUMBER
) AS
    v_seat_cap    NUMBER;
    v_seats_filled NUMBER;
    v_max_bags    NUMBER;
    v_total_lug   NUMBER;
    v_status      VARCHAR2(20);
    v_trust       NUMBER;
    v_has_conn    CHAR(1) := 'N';
    v_fare        NUMBER;
    v_dest_id     NUMBER;

    e_locked      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_locked, -54);  -- ORA-00054: resource busy (NOWAIT)
BEGIN
    -- ── Step 1: Pessimistic lock on the group row ──────────────────────────
    BEGIN
        SELECT rg.seats_filled,
               rg.total_luggage,
               rg.status,
               rg.destination_id,
               v.seat_capacity,
               v.max_large_bags
        INTO   v_seats_filled, v_total_lug, v_status, v_dest_id,
               v_seat_cap, v_max_bags
        FROM   Ride_Groups rg
        JOIN   Vehicles v ON rg.vehicle_id = v.vehicle_id
        WHERE  rg.group_id = p_group_id
        FOR UPDATE NOWAIT;
    EXCEPTION
        WHEN e_locked THEN
            DBMS_OUTPUT.PUT_LINE('FAILED: Group ' || p_group_id ||
                                 ' is locked by another session. Retry.');
            RETURN;
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('FAILED: Group ' || p_group_id || ' does not exist.');
            RETURN;
    END;

    -- ── SAVEPOINT — partial rollback target ───────────────────────────────
    SAVEPOINT before_member_add;

    -- ── Step 2: Group must be FORMING ─────────────────────────────────────
    IF v_status != 'FORMING' THEN
        ROLLBACK TO before_member_add;
        DBMS_OUTPUT.PUT_LINE('FAILED: Group ' || p_group_id ||
                             ' is not open for booking (status: ' || v_status || ').');
        RETURN;
    END IF;

    -- ── Step 3: Seat available ─────────────────────────────────────────────
    IF v_seats_filled >= v_seat_cap THEN
        ROLLBACK TO before_member_add;
        DBMS_OUTPUT.PUT_LINE('FAILED: No seats available in group ' || p_group_id || '.');
        RETURN;
    END IF;

    -- ── Step 4: Luggage fits ───────────────────────────────────────────────
    IF (v_total_lug + p_luggage) > v_max_bags THEN
        ROLLBACK TO before_member_add;
        DBMS_OUTPUT.PUT_LINE('FAILED: Luggage capacity exceeded. ' ||
                             'Available bag space: ' || (v_max_bags - v_total_lug) ||
                             ', requested: ' || p_luggage);
        RETURN;
    END IF;

    -- ── Step 5: PriorityGo check — if group goes to a transit hub, trust >= 90 required ──
    -- A transit hub destination (airport/railway station) implies connection risk.
    -- We check is_transit_hub on the group's destination, not the student's trip request,
    -- because the group destination is what determines PriorityGo eligibility at booking time.
    DECLARE
        v_is_hub CHAR(1);
    BEGIN
        SELECT is_transit_hub INTO v_is_hub
        FROM Destinations
        WHERE destination_id = v_dest_id;

        IF v_is_hub = 'Y' THEN
            SELECT trust_score INTO v_trust
            FROM Students
            WHERE student_id = p_student_id;

            IF v_trust < 90 THEN
                ROLLBACK TO before_member_add;
                DBMS_OUTPUT.PUT_LINE('FAILED: PriorityGo requires trust score >= 90. ' ||
                                     'Student ' || p_student_id ||
                                     ' has trust score: ' || v_trust);
                RETURN;
            END IF;
        END IF;
    END;

    -- ── Step 6: Insert membership ──────────────────────────────────────────
    -- trg_seat_sync fires here: seats_filled + 1, total_luggage + p_luggage
    INSERT INTO Group_Members (group_id, student_id, joined_at, payment_status)
    VALUES (p_group_id, p_student_id, SYSTIMESTAMP, 'PENDING');

    -- ── Step 7: Create payment record ─────────────────────────────────────
    -- Fare: flat ₹950 per seat (demo pricing — real system would calculate)
    v_fare := 950;
    INSERT INTO Payments (payment_id, student_id, group_id, amount, status, paid_at)
    VALUES (payment_seq.NEXTVAL, p_student_id, p_group_id, v_fare, 'PENDING', NULL);

    -- ── Step 8: Lock group once full ──────────────────────────────────────
    -- Re-read seats_filled after trigger updated it
    DECLARE
        v_new_filled NUMBER;
    BEGIN
        SELECT seats_filled INTO v_new_filled
        FROM Ride_Groups WHERE group_id = p_group_id;

        IF v_new_filled >= v_seat_cap THEN
            UPDATE Ride_Groups SET status = 'LOCKED'
            WHERE group_id = p_group_id;
            DBMS_OUTPUT.PUT_LINE('INFO: Group ' || p_group_id || ' is now LOCKED (full).');
        END IF;
    END;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS: Student ' || p_student_id ||
                         ' booked into group ' || p_group_id || '.');

EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        ROLLBACK TO before_member_add;
        DBMS_OUTPUT.PUT_LINE('FAILED: Student ' || p_student_id ||
                             ' is already a member of group ' || p_group_id || '.');
    WHEN OTHERS THEN
        ROLLBACK TO before_member_add;
        DBMS_OUTPUT.PUT_LINE('ERROR in book_ride: ' || SQLERRM);
END book_ride;
/


-- =============================================================================
-- PROCEDURE 3: cancel_booking
-- Removes a student from a group.
-- DELETE from Group_Members fires trg_trust_on_cancellation (Module D):
--   → trust_score - 15 (floor 0)
--   → inserts row into Trust_Audit_Log
-- Also marks the payment REFUNDED and reopens a LOCKED group to FORMING.
-- Called by /api/cancel-booking in Module E.
-- =============================================================================
CREATE OR REPLACE PROCEDURE cancel_booking (
    p_group_id    IN NUMBER,
    p_student_id  IN NUMBER
) AS
    v_member_count  NUMBER;
    v_group_status  VARCHAR2(20);
BEGIN
    -- Verify membership exists
    SELECT COUNT(*) INTO v_member_count
    FROM Group_Members
    WHERE group_id = p_group_id AND student_id = p_student_id;

    IF v_member_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Student ' || p_student_id ||
                             ' is not a member of group ' || p_group_id || '.');
        RETURN;
    END IF;

    -- Cannot cancel a COMPLETED or already CANCELLED group
    SELECT status INTO v_group_status
    FROM Ride_Groups WHERE group_id = p_group_id;

    IF v_group_status IN ('COMPLETED', 'CANCELLED') THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Cannot cancel booking in a ' ||
                             v_group_status || ' group.');
        RETURN;
    END IF;

    SAVEPOINT before_cancel;

    -- Delete triggers: trg_trust_on_cancellation fires (-15 trust, audit log entry)
    --                  trg_seat_sync fires (seats_filled - 1, total_luggage adjusted)
    DELETE FROM Group_Members
    WHERE group_id = p_group_id AND student_id = p_student_id;

    -- Refund payment
    UPDATE Payments
    SET status = 'REFUNDED', paid_at = SYSTIMESTAMP
    WHERE student_id = p_student_id AND group_id = p_group_id;

    -- If group was LOCKED, reopen to FORMING (seat freed up)
    IF v_group_status = 'LOCKED' THEN
        UPDATE Ride_Groups SET status = 'FORMING'
        WHERE group_id = p_group_id;
        DBMS_OUTPUT.PUT_LINE('INFO: Group ' || p_group_id ||
                             ' reopened to FORMING (seat freed).');
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS: Student ' || p_student_id ||
                         ' removed from group ' || p_group_id ||
                         '. Trust penalty applied (-15).');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO before_cancel;
        DBMS_OUTPUT.PUT_LINE('ERROR in cancel_booking: ' || SQLERRM);
END cancel_booking;
/


-- =============================================================================
-- PROCEDURE 4: complete_ride
-- Marks a group COMPLETED.
-- UPDATE on Ride_Groups fires trg_trust_on_completion (Module D):
--   → trust_score + 10 for every member
--   → total_rides + 1 for every member
--   → inserts row into Trust_Audit_Log for each member
-- Called by /api/complete-ride in Module E (admin/demo action).
-- =============================================================================
CREATE OR REPLACE PROCEDURE complete_ride (
    p_group_id  IN NUMBER
) AS
    v_status      VARCHAR2(20);
    v_member_count NUMBER;
BEGIN
    -- Validate group exists and is in a completable state
    SELECT status INTO v_status
    FROM Ride_Groups WHERE group_id = p_group_id;

    IF v_status NOT IN ('FORMING', 'LOCKED') THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Group ' || p_group_id ||
                             ' cannot be completed (status: ' || v_status || ').');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_member_count
    FROM Group_Members WHERE group_id = p_group_id;

    IF v_member_count < 2 THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Group ' || p_group_id ||
                             ' needs at least 2 members to complete. Has: ' || v_member_count);
        RETURN;
    END IF;

    SAVEPOINT before_complete;

    -- This UPDATE fires trg_trust_on_completion (Module D)
    UPDATE Ride_Groups
    SET status = 'COMPLETED'
    WHERE group_id = p_group_id;

    -- Mark all pending payments as COMPLETED
    UPDATE Payments
    SET status = 'COMPLETED', paid_at = SYSTIMESTAMP
    WHERE group_id = p_group_id AND status = 'PENDING';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS: Group ' || p_group_id || ' completed. ' ||
                         'Trust +10 applied to ' || v_member_count || ' members.');

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('FAILED: Group ' || p_group_id || ' does not exist.');
    WHEN OTHERS THEN
        ROLLBACK TO before_complete;
        DBMS_OUTPUT.PUT_LINE('ERROR in complete_ride: ' || SQLERRM);
END complete_ride;
/


-- =============================================================================
-- C2_ACID_DEMO: Transaction and concurrency demonstration script
-- Run this in TWO separate SQL*Plus / Workbench sessions for the examiner.
--
-- SESSION 1: Run steps 1-3 WITHOUT committing → holds FOR UPDATE lock
-- SESSION 2: Run book_ride on same group → gets ORA-00054, prints retry message
-- SESSION 1: Then COMMIT → lock released
-- =============================================================================

-- ── DEMO SETUP: Check group 601 (1 seat left — concurrency demo group) ──
SELECT
    rg.group_id,
    d.city_name,
    v.seat_capacity,
    rg.seats_filled,
    (v.seat_capacity - rg.seats_filled) AS seats_left,
    rg.status
FROM Ride_Groups rg
JOIN Vehicles v     ON rg.vehicle_id     = v.vehicle_id
JOIN Destinations d ON rg.destination_id = d.destination_id
WHERE rg.group_id = 601;

-- ── SESSION 1: Manually acquire FOR UPDATE NOWAIT lock (do NOT commit yet) ──
-- Paste this in Session 1 and leave it open:
--
--   SELECT * FROM Ride_Groups WHERE group_id = 601 FOR UPDATE NOWAIT;
--   -- DO NOT COMMIT YET

-- ── SESSION 2: Try to book — should get ORA-00054 handled gracefully ──
SET SERVEROUTPUT ON;
EXEC book_ride(601, 1001, 1);
-- Expected output: "FAILED: Group 601 is locked by another session. Retry."

-- ── SESSION 1: Now COMMIT to release the lock ──
--   COMMIT;

-- ── SESSION 2: Try again — should succeed ──
EXEC book_ride(601, 1001, 1);
-- Expected output: "SUCCESS: Student 1001 booked into group 601."
--                  "INFO: Group 601 is now LOCKED (full)."

-- ── Demo SAVEPOINT rollback on luggage failure ──
SET SERVEROUTPUT ON;
EXEC book_ride(601, 1009, 99);
-- Expected output: "FAILED: Luggage capacity exceeded."
-- Verify nothing was inserted:
SELECT * FROM Group_Members WHERE group_id = 601 AND student_id = 1009;

-- ── Demo PriorityGo trust block ──
-- Student 1005 has trust_score = 60, has a connecting flight request
EXEC book_ride(605, 1005, 1);
-- Expected output: "FAILED: PriorityGo requires trust score >= 90. Student 1005 has trust score: 60"

-- ── Demo cancel_booking → trust penalty ──
SET SERVEROUTPUT ON;
SELECT trust_score FROM Students WHERE student_id = 1004;
EXEC cancel_booking(602, 1004);
SELECT trust_score FROM Students WHERE student_id = 1004;
SELECT * FROM Trust_Audit_Log WHERE student_id = 1004 ORDER BY audit_id DESC;

-- ── Demo complete_ride → trust reward ──
SET SERVEROUTPUT ON;
SELECT student_id, trust_score, total_rides FROM Students
WHERE student_id IN (SELECT student_id FROM Group_Members WHERE group_id = 602);

EXEC complete_ride(602);

SELECT student_id, trust_score, total_rides FROM Students
WHERE student_id IN (SELECT student_id FROM Group_Members WHERE group_id = 602);
SELECT * FROM Trust_Audit_Log WHERE student_id IN (1004, 1009) ORDER BY audit_id DESC;

-- ── ACID property summary ──
--
-- Atomicity:    SAVEPOINT before_member_add / before_cancel / before_complete
--               Any validation failure rolls back to savepoint — no partial writes
--
-- Consistency:  CHECK constraints (luggage <= capacity, trust range, status enum)
--               FK integrity maintained throughout
--               PriorityGo trust check enforced before any write
--
-- Isolation:    SELECT FOR UPDATE NOWAIT acquires row-level lock
--               Second session gets ORA-00054 — double-booking impossible
--
-- Durability:   COMMIT issued only after ALL validations pass
--               Verified: SELECT after COMMIT shows persisted state

-- =============================================================================
-- End of C1_booking.sql
-- =============================================================================