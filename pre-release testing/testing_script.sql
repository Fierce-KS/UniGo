-- =============================================================================
-- UniGo - Demo Testing Script
-- Prerequisites: All 5 files already executed (A1, D2, D1, B1, C1)
-- SET SERVEROUTPUT ON before running.
-- =============================================================================

SET SERVEROUTPUT ON;

-- =============================================================================
-- SECTION 1: DATA OVERVIEW
-- Show the examiner what's in the database
-- =============================================================================

-- All students with trust scores
SELECT student_id, name, trust_score, total_rides FROM Students ORDER BY student_id;

-- All ride groups and their status
SELECT group_id, status, seats_filled, total_luggage FROM Ride_Groups ORDER BY group_id;

-- Who is in which group
SELECT gm.group_id, s.name, rg.status
FROM Group_Members gm
JOIN Students s ON gm.student_id = s.student_id
JOIN Ride_Groups rg ON gm.group_id = rg.group_id
ORDER BY gm.group_id;


-- =============================================================================
-- SECTION 2: VIEW-BASED MATCHING (Module B)
-- =============================================================================

-- Available rides right now (vw_available_rides)
SELECT group_id, city_name, departure_date, available_seats, available_bag_space
FROM vw_available_rides;

-- En-route matching: Rajpura student finds Chandigarh-bound cab
SELECT * FROM vw_enroute_matches;

-- Trust leaderboard with RANK() window function (BQ-04)
SELECT student_id, name, trust_score, total_rides, trust_rank
FROM vw_trust_leaderboard
WHERE trust_rank <= 5
ORDER BY trust_rank;


-- =============================================================================
-- SECTION 3: COMPLEX QUERIES (BQ-01 to BQ-06)
-- =============================================================================

-- BQ-01: Multi-table JOIN — open requests matching available groups on 2026-05-10
SELECT
    tr.request_id,
    s.name              AS student_name,
    ar.group_id,
    ar.city_name        AS group_dest,
    d2.city_name        AS student_dest,
    ar.available_seats,
    ar.departure_date
FROM Trip_Requests tr
JOIN Students s         ON tr.student_id      = s.student_id
JOIN vw_available_rides ar ON (
        ar.destination_id = tr.destination_id
        OR EXISTS (
            SELECT 1 FROM Routes r
            WHERE r.to_dest_id   = ar.destination_id
              AND r.from_dest_id = tr.destination_id
              AND r.is_enroute   = 'Y'
        )
)
JOIN Destinations d2    ON tr.destination_id  = d2.destination_id
WHERE tr.status = 'OPEN'
  AND ar.departure_date = TO_CHAR(DATE '2026-05-10', 'YYYY-MM-DD')
ORDER BY tr.request_id, ar.group_id;

-- BQ-02: Correlated NOT EXISTS — students who have never cancelled
SELECT s.student_id, s.name, s.trust_score
FROM Students s
WHERE NOT EXISTS (
    SELECT 1 FROM Trust_Audit_Log t
    WHERE t.student_id = s.student_id
      AND UPPER(t.reason) LIKE '%CANCELLATION%'
)
ORDER BY s.trust_score DESC;

-- BQ-03: Aggregate + HAVING — groups where luggage > 70% of capacity
SELECT
    rg.group_id,
    d.city_name,
    v.max_large_bags,
    rg.total_luggage,
    ROUND(rg.total_luggage / v.max_large_bags * 100, 1) AS luggage_pct
FROM Ride_Groups rg
JOIN Vehicles     v ON rg.vehicle_id     = v.vehicle_id
JOIN Destinations d ON rg.destination_id = d.destination_id
WHERE v.max_large_bags > 0
GROUP BY rg.group_id, d.city_name, v.max_large_bags, rg.total_luggage
HAVING rg.total_luggage > 0.7 * v.max_large_bags
ORDER BY luggage_pct DESC;

-- BQ-05: INTERSECT — destinations that are both group destinations and en-route stops
SELECT d.city_name FROM Destinations d
JOIN Ride_Groups rg ON rg.destination_id = d.destination_id
INTERSECT
SELECT d2.city_name FROM Destinations d2
JOIN Routes r ON r.from_dest_id = d2.destination_id
WHERE r.is_enroute = 'Y';

-- BQ-06: Inline function call — travel risk for PriorityGo requests
SELECT
    s.name,
    d.city_name,
    tr.connection_time,
    ROUND(d.avg_travel_hours * 1.3, 2)                           AS required_hrs,
    calculate_travel_risk(tr.connection_time, tr.destination_id) AS risk_level
FROM Trip_Requests tr
JOIN Students     s ON tr.student_id     = s.student_id
JOIN Destinations d ON tr.destination_id = d.destination_id
WHERE tr.has_connection = 'Y';


-- =============================================================================
-- SECTION 4: CURSOR DEMO (Module B — find_travel_buddies)
-- =============================================================================

-- Student 1005 (Sneha) wants to go to Rajpura on 2026-05-10 with 1 bag
-- Should find Group 602 (Chandigarh) as EN-ROUTE match
EXEC find_travel_buddies(1005, 202, DATE '2026-05-10', 1);


-- =============================================================================
-- SECTION 5: BOOK_RIDE — ACID Transaction Demo (Module C)
-- =============================================================================

-- State before booking
SELECT seats_filled, total_luggage, status FROM Ride_Groups WHERE group_id = 601;
SELECT trust_score FROM Students WHERE student_id = 1001;

-- Book Aanya (1001) into Group 601 (Delhi, 1 seat left)
EXEC book_ride(601, 1001, 0);

-- State after booking — seats should be 4, group LOCKED
SELECT seats_filled, total_luggage, status FROM Ride_Groups WHERE group_id = 601;
SELECT * FROM Group_Members WHERE group_id = 601 AND student_id = 1001;
SELECT * FROM Payments WHERE student_id = 1001 AND group_id = 601;


-- =============================================================================
-- SECTION 6: PRIORITYGO TRUST BLOCK (Module C + D)
-- =============================================================================

-- Student 1005 (Sneha, trust=45) tries to book transit hub group (IGI Airport)
-- Should be BLOCKED — trust < 90
SELECT trust_score FROM Students WHERE student_id = 1005;
EXEC book_ride(605, 1005, 0);

-- Student 1002 (Rohan, trust=95) books the same group — should SUCCEED
SELECT trust_score FROM Students WHERE student_id = 1002;
EXEC book_ride(605, 1002, 0);


-- =============================================================================
-- SECTION 7: SAVEPOINT ROLLBACK DEMO (Module C)
-- =============================================================================

-- Try to add 99 bags to group 601 — should fail and rollback cleanly
EXEC book_ride(601, 1009, 99);

-- Verify nothing was inserted
SELECT * FROM Group_Members WHERE group_id = 601 AND student_id = 1009;


-- =============================================================================
-- SECTION 8: CANCEL_BOOKING — Trust Penalty + Audit Log (Module C + D)
-- =============================================================================

-- Trust before cancellation
SELECT trust_score FROM Students WHERE student_id = 1001;

-- Cancel Aanya from group 601 — trigger fires: -15 trust, audit log entry
EXEC cancel_booking(601, 1001);

-- Trust after — should be 15 less, group reopened to FORMING
SELECT trust_score FROM Students WHERE student_id = 1001;
SELECT seats_filled, status FROM Ride_Groups WHERE group_id = 601;

-- Audit log entry
SELECT audit_id, old_score, new_score, reason, changed_at
FROM Trust_Audit_Log
WHERE student_id = 1001
ORDER BY audit_id DESC;


-- =============================================================================
-- SECTION 9: COMPLETE_RIDE — Trust Reward for All Members (Module C + D)
-- =============================================================================

-- Trust and rides before completion
SELECT student_id, trust_score, total_rides FROM Students
WHERE student_id IN (SELECT student_id FROM Group_Members WHERE group_id = 602);

-- Complete group 602 — trigger fires: +10 trust, +1 ride for each member
EXEC complete_ride(602);

-- Trust and rides after — all members should have +10 trust, +1 ride
SELECT student_id, trust_score, total_rides FROM Students
WHERE student_id IN (SELECT student_id FROM Group_Members WHERE group_id = 602);

-- Audit log entries for completion
SELECT audit_id, student_id, old_score, new_score, reason
FROM Trust_Audit_Log
WHERE reason LIKE '%602%'
ORDER BY audit_id DESC;


-- =============================================================================
-- SECTION 10: IMMUTABLE AUDIT LOG DEMO (Module D)
-- =============================================================================

-- Try to delete an audit entry — should be BLOCKED by trg_immutable_audit
BEGIN
    DELETE FROM Trust_Audit_Log WHERE ROWNUM = 1;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('BLOCKED: ' || SQLERRM);
END;
/

-- Try to update an audit entry — also blocked
BEGIN
    UPDATE Trust_Audit_Log SET reason = 'tampered' WHERE ROWNUM = 1;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('BLOCKED: ' || SQLERRM);
END;
/


-- =============================================================================
-- SECTION 11: CONCURRENCY DEMO (Module C — FOR UPDATE NOWAIT)
-- NOTE: For live demo, run Session 1 block in one terminal,
--       then immediately run Session 2 block in a second terminal
--       BEFORE committing Session 1.
-- =============================================================================

-- SESSION 1 (run first, DO NOT COMMIT):
--   SELECT * FROM Ride_Groups WHERE group_id = 601 FOR UPDATE NOWAIT;

-- SESSION 2 (run while Session 1 is open):
--   SET SERVEROUTPUT ON;
--   EXEC book_ride(601, 1001, 0);
--   Expected: "FAILED: Group 601 is locked by another session. Retry."

-- SESSION 1 (then commit to release lock):
--   COMMIT;

-- SESSION 2 (try again after Session 1 commits):
--   EXEC book_ride(601, 1001, 0);
--   Expected: "SUCCESS: Student 1001 booked into group 601."

-- The PRAGMA EXCEPTION_INIT(-54) in book_ride catches ORA-00054
-- and prints the friendly retry message instead of crashing.


-- =============================================================================
-- SECTION 12: FINAL STATE OVERVIEW
-- =============================================================================

-- Full audit log — complete history of all trust changes
SELECT s.name, t.old_score, t.new_score, t.reason, t.changed_at
FROM Trust_Audit_Log t
JOIN Students s ON t.student_id = s.student_id
ORDER BY t.audit_id;

-- Final leaderboard
SELECT name, trust_score, total_rides, trust_rank
FROM vw_trust_leaderboard
ORDER BY trust_rank;

-- =============================================================================
-- End of DEMO_SCRIPT.sql
-- =============================================================================