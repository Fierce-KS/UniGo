-- =============================================================================
-- UniGo — Module B: Matching Engine
-- File: B1_views_and_proc.sql
-- Description: Views for ride matching + find_travel_buddies procedure
-- Database: Oracle 21c XE
-- Run order: 3rd — after A1_ddl.sql and D1_triggers.sql
-- =============================================================================

-- =============================================================================
-- VIEW 1: vw_available_rides
-- Primary matching view. Pre-computes available seats and bag space.
-- Filters to FORMING groups with at least 1 seat remaining.
-- All booking queries use this view — never query Ride_Groups directly.
-- =============================================================================
CREATE OR REPLACE VIEW vw_available_rides AS
SELECT
    rg.group_id,
    rg.destination_id,
    d.city_name,
    TO_CHAR(rg.departure_date, 'YYYY-MM-DD')  AS departure_date,
    rg.departure_time,
    v.seat_capacity,
    rg.seats_filled,
    (v.seat_capacity - rg.seats_filled)        AS available_seats,
    v.max_large_bags,
    rg.total_luggage,
    (v.max_large_bags - rg.total_luggage)      AS available_bag_space,
    rg.status
FROM Ride_Groups rg
JOIN Vehicles    v  ON rg.vehicle_id     = v.vehicle_id
JOIN Destinations d ON rg.destination_id = d.destination_id
WHERE rg.status = 'FORMING'
  AND (v.seat_capacity - rg.seats_filled) > 0;

-- =============================================================================
-- VIEW 2: vw_enroute_matches
-- En-route matching. A Rajpura-bound student finds a Chandigarh cab
-- whose route has is_enroute = 'Y' from Rajpura to Chandigarh.
-- Depends on vw_available_rides.
-- =============================================================================
CREATE OR REPLACE VIEW vw_enroute_matches AS
SELECT
    ar.group_id,
    ar.city_name           AS group_destination,
    d2.city_name           AS student_destination,
    ar.available_seats,
    ar.available_bag_space,
    ar.departure_date,
    ar.departure_time,
    r.distance_km
FROM vw_available_rides ar
JOIN Routes      r  ON ar.destination_id = r.to_dest_id
JOIN Destinations d2 ON r.from_dest_id  = d2.destination_id
WHERE r.is_enroute = 'Y';

-- =============================================================================
-- VIEW 3: vw_trust_leaderboard
-- Window function demo — RANK() OVER. Required by BQ-04.
-- =============================================================================
CREATE OR REPLACE VIEW vw_trust_leaderboard AS
SELECT
    student_id,
    name,
    trust_score,
    total_rides,
    RANK() OVER (ORDER BY trust_score DESC) AS trust_rank
FROM Students;

-- =============================================================================
-- VIEW 4: vw_students
-- Flat student list used by Module E dashboard and student selector.
-- =============================================================================
CREATE OR REPLACE VIEW vw_students AS
SELECT
    student_id,
    name,
    email,
    trust_score,
    total_rides,
    TO_CHAR(joined_on, 'YYYY-MM-DD') AS joined_on
FROM Students
ORDER BY student_id;

-- =============================================================================
-- VIEW 5: vw_destinations
-- Used by Module E dropdowns.
-- =============================================================================
CREATE OR REPLACE VIEW vw_destinations AS
SELECT
    destination_id,
    city_name,
    is_transit_hub,
    avg_travel_hours
FROM Destinations
ORDER BY city_name;

-- =============================================================================
-- VIEW 6: vw_ride_groups
-- Full ride group list for Module E group selector.
-- Joins vehicle for capacity context.
-- =============================================================================
CREATE OR REPLACE VIEW vw_ride_groups AS
SELECT
    rg.group_id,
    rg.destination_id,
    d.city_name,
    TO_CHAR(rg.departure_date, 'YYYY-MM-DD') AS departure_date,
    rg.departure_time,
    v.seat_capacity,
    rg.seats_filled,
    (v.seat_capacity - rg.seats_filled)      AS available_seats,
    rg.total_luggage,
    rg.status
FROM Ride_Groups  rg
JOIN Vehicles     v  ON rg.vehicle_id     = v.vehicle_id
JOIN Destinations d  ON rg.destination_id = d.destination_id;

-- =============================================================================
-- VIEW 7: vw_trust_audit
-- Full audit log view for Module E audit table.
-- =============================================================================
CREATE OR REPLACE VIEW vw_trust_audit AS
SELECT
    t.audit_id,
    t.student_id,
    s.name          AS student_name,
    t.old_score,
    t.new_score,
    t.reason,
    TO_CHAR(t.changed_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at
FROM Trust_Audit_Log t
JOIN Students s ON t.student_id = s.student_id;

-- =============================================================================
-- VIEW 8: vw_student_bookings
-- Per-student booking history. Used by /api/student-bookings/:id in Module E.
-- =============================================================================
CREATE OR REPLACE VIEW vw_student_bookings AS
SELECT
    gm.student_id,
    gm.group_id,
    d.city_name,
    TO_CHAR(rg.departure_date, 'YYYY-MM-DD') AS departure_date,
    rg.departure_time,
    rg.status,
    v.seat_capacity,
    rg.seats_filled,
    gm.payment_status
FROM Group_Members gm
JOIN Ride_Groups  rg ON gm.group_id       = rg.group_id
JOIN Destinations d  ON rg.destination_id = d.destination_id
JOIN Vehicles     v  ON rg.vehicle_id     = v.vehicle_id;

-- =============================================================================
-- VIEW 9: vw_student_audit
-- Per-student trust audit. Used by /api/student-audit/:id in Module E.
-- =============================================================================
CREATE OR REPLACE VIEW vw_student_audit AS
SELECT
    audit_id,
    student_id,
    old_score,
    new_score,
    reason,
    TO_CHAR(changed_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at
FROM Trust_Audit_Log;

-- =============================================================================
-- VIEW 10: vw_leaderboard
-- Alias of vw_trust_leaderboard for Module E /api/leaderboard endpoint.
-- =============================================================================
CREATE OR REPLACE VIEW vw_leaderboard AS
SELECT * FROM vw_trust_leaderboard;

-- =============================================================================
-- PROCEDURE: find_travel_buddies
-- Mandatory CURSOR deliverable.
-- Accepts student context and finds compatible FORMING groups via explicit cursor.
-- Checks both direct destination match AND en-route compatibility.
-- =============================================================================
CREATE OR REPLACE PROCEDURE find_travel_buddies (
    p_student_id    IN NUMBER,
    p_destination_id IN NUMBER,
    p_travel_date   IN DATE,
    p_luggage_count IN NUMBER
) AS
    CURSOR c_matches IS
        SELECT
            ar.group_id,
            ar.city_name,
            ar.available_seats,
            ar.available_bag_space,
            ar.departure_time,
            'DIRECT' AS match_type
        FROM vw_available_rides ar
        WHERE ar.destination_id = p_destination_id
          AND ar.departure_date = TO_CHAR(p_travel_date, 'YYYY-MM-DD')
          AND ar.available_bag_space >= p_luggage_count
        UNION ALL
        SELECT
            ar.group_id,
            ar.city_name,
            ar.available_seats,
            ar.available_bag_space,
            ar.departure_time,
            'EN-ROUTE' AS match_type
        FROM vw_available_rides ar
        WHERE EXISTS (
            SELECT 1 FROM Routes r
            WHERE r.to_dest_id   = ar.destination_id
              AND r.from_dest_id = p_destination_id
              AND r.is_enroute   = 'Y'
        )
          AND ar.departure_date = TO_CHAR(p_travel_date, 'YYYY-MM-DD')
          AND ar.available_bag_space >= p_luggage_count;

    v_match  c_matches%ROWTYPE;
    v_count  NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== find_travel_buddies ===');
    DBMS_OUTPUT.PUT_LINE('Student: ' || p_student_id ||
                         ' | Dest: '   || p_destination_id ||
                         ' | Date: '   || TO_CHAR(p_travel_date,'YYYY-MM-DD') ||
                         ' | Bags: '   || p_luggage_count);
    DBMS_OUTPUT.PUT_LINE('---------------------------------');

    OPEN c_matches;
    LOOP
        FETCH c_matches INTO v_match;
        EXIT WHEN c_matches%NOTFOUND;
        v_count := v_count + 1;
        DBMS_OUTPUT.PUT_LINE(
            '[' || v_match.match_type || '] ' ||
            'Group: '   || v_match.group_id        ||
            ' | Dest: ' || v_match.city_name        ||
            ' | Seats: '|| v_match.available_seats  ||
            ' | Bags: ' || v_match.available_bag_space ||
            ' | Departs:'|| v_match.departure_time
        );
    END LOOP;
    CLOSE c_matches;

    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('No matching groups found for given criteria.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('---------------------------------');
        DBMS_OUTPUT.PUT_LINE('Total matches: ' || v_count);
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        IF c_matches%ISOPEN THEN CLOSE c_matches; END IF;
        DBMS_OUTPUT.PUT_LINE('ERROR in find_travel_buddies: ' || SQLERRM);
END find_travel_buddies;
/

-- =============================================================================
-- COMPLEX QUERY SUITE (BQ-01 to BQ-06)
-- Run these during the examiner demo as a script.
-- =============================================================================

-- BQ-01: Multi-table JOIN + VIEW
-- All FORMING groups matching open Trip_Requests for a given date,
-- joined with en-route route information.
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

-- BQ-02: Correlated NOT EXISTS subquery
-- Students who have NEVER cancelled — no cancellation entry in audit log.
SELECT
    s.student_id,
    s.name,
    s.trust_score,
    s.total_rides
FROM Students s
WHERE NOT EXISTS (
    SELECT 1
    FROM Trust_Audit_Log t
    WHERE t.student_id = s.student_id
      AND UPPER(t.reason) LIKE '%CANCELLATION%'
)
ORDER BY s.trust_score DESC;

-- BQ-03: Aggregate + HAVING
-- Ride groups where luggage exceeds 70% of vehicle bag capacity (overcrowded).
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

-- BQ-04: Window function RANK()
-- Top 5 students by trust score using vw_trust_leaderboard.
SELECT student_id, name, trust_score, total_rides, trust_rank
FROM vw_trust_leaderboard
WHERE trust_rank <= 5
ORDER BY trust_rank;

-- BQ-05: SET operation INTERSECT
-- Destinations reachable both as direct group destinations AND as en-route stops.
SELECT d.city_name FROM Destinations d
JOIN Ride_Groups rg ON rg.destination_id = d.destination_id
INTERSECT
SELECT d2.city_name FROM Destinations d2
JOIN Routes r ON r.from_dest_id = d2.destination_id
WHERE r.is_enroute = 'Y';

-- BQ-06: Inline function call
-- Risk level for all PriorityGo trip requests using calculate_travel_risk().
SELECT
    s.name,
    d.city_name,
    tr.connection_time,
    d.avg_travel_hours,
    ROUND(d.avg_travel_hours * 1.3, 2)                              AS required_hrs,
    calculate_travel_risk(tr.connection_time, tr.destination_id)    AS risk_level
FROM Trip_Requests tr
JOIN Students     s ON tr.student_id     = s.student_id
JOIN Destinations d ON tr.destination_id = d.destination_id
WHERE tr.has_connection = 'Y'
ORDER BY tr.request_id;

-- =============================================================================
-- End of B1_views_and_proc.sql
-- =============================================================================
