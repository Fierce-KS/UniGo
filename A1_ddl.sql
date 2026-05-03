-- =============================================================================
-- UniGo — Module A: Database Foundation
-- File: A1_ddl.sql
-- Description: All 9 tables, sequences, constraints, sample data
-- Database: Oracle 21c XE
-- Run order: 1st — everything else depends on this
-- =============================================================================

-- =============================================================================
-- SEQUENCES
-- Must exist before any INSERT or NEXTVAL reference
-- =============================================================================
CREATE SEQUENCE student_seq     START WITH 1001 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE dest_seq        START WITH 201  INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE route_seq       START WITH 301  INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE vehicle_seq     START WITH 401  INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE request_seq     START WITH 501  INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE group_seq       START WITH 601  INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE payment_seq     START WITH 701  INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE trust_audit_seq START WITH 801  INCREMENT BY 1 NOCACHE;

-- =============================================================================
-- TABLE 1: Students  (Module A owns)
-- trust_score and total_rides are updated ONLY by Module D triggers.
-- Never UPDATE these columns manually.
-- =============================================================================
CREATE TABLE Students (
    student_id   NUMBER(10)    NOT NULL,
    name         VARCHAR2(100) NOT NULL,
    email        VARCHAR2(150) NOT NULL,
    trust_score  NUMBER(5,2)   DEFAULT 100 NOT NULL,
    total_rides  NUMBER(5)     DEFAULT 0   NOT NULL,
    joined_on    DATE          DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_students     PRIMARY KEY (student_id),
    CONSTRAINT uq_student_email UNIQUE (email),
    CONSTRAINT chk_trust_range  CHECK (trust_score BETWEEN 0 AND 200),
    CONSTRAINT chk_rides_pos    CHECK (total_rides >= 0)
);

-- =============================================================================
-- TABLE 2: Destinations  (Module A owns)
-- =============================================================================
CREATE TABLE Destinations (
    destination_id  NUMBER(10)    NOT NULL,
    city_name       VARCHAR2(100) NOT NULL,
    is_transit_hub  CHAR(1)       DEFAULT 'N' NOT NULL,
    avg_travel_hours NUMBER(4,2)  NOT NULL,
    CONSTRAINT pk_destinations      PRIMARY KEY (destination_id),
    CONSTRAINT uq_city_name         UNIQUE (city_name),
    CONSTRAINT chk_transit_hub      CHECK (is_transit_hub IN ('Y','N')),
    CONSTRAINT chk_travel_hrs_pos   CHECK (avg_travel_hours > 0)
);

-- =============================================================================
-- TABLE 3: Routes  (Module A owns)
-- M:N self-join on Destinations.
-- is_enroute = 'Y' means a student going to from_dest_id can board a cab
-- headed to to_dest_id (the cab passes through from_dest_id).
-- =============================================================================
CREATE TABLE Routes (
    route_id      NUMBER(10) NOT NULL,
    from_dest_id  NUMBER(10) NOT NULL,
    to_dest_id    NUMBER(10) NOT NULL,
    is_enroute    CHAR(1)    DEFAULT 'N' NOT NULL,
    distance_km   NUMBER(6,2),
    CONSTRAINT pk_routes        PRIMARY KEY (route_id),
    CONSTRAINT fk_route_from    FOREIGN KEY (from_dest_id) REFERENCES Destinations(destination_id),
    CONSTRAINT fk_route_to      FOREIGN KEY (to_dest_id)   REFERENCES Destinations(destination_id),
    CONSTRAINT chk_enroute      CHECK (is_enroute IN ('Y','N')),
    CONSTRAINT chk_dist_pos     CHECK (distance_km IS NULL OR distance_km > 0),
    CONSTRAINT chk_no_self_route CHECK (from_dest_id <> to_dest_id)
);

-- =============================================================================
-- TABLE 4: Vehicles  (Module A owns)
-- =============================================================================
CREATE TABLE Vehicles (
    vehicle_id      NUMBER(10)    NOT NULL,
    vehicle_type    VARCHAR2(50)  NOT NULL,
    seat_capacity   NUMBER(2)     NOT NULL,
    max_large_bags  NUMBER(2)     NOT NULL,
    registration_no VARCHAR2(20)  NOT NULL,
    CONSTRAINT pk_vehicles         PRIMARY KEY (vehicle_id),
    CONSTRAINT uq_registration     UNIQUE (registration_no),
    CONSTRAINT chk_seat_capacity   CHECK (seat_capacity BETWEEN 1 AND 10),
    CONSTRAINT chk_max_bags        CHECK (max_large_bags >= 0)
);

-- =============================================================================
-- TABLE 5: Trip_Requests  (Module B owns — DDL here, Module B adds views/proc)
-- has_connection = 'Y' triggers PriorityGo flow at booking time (in Module C).
-- connection_time MUST be provided when has_connection = 'Y'.
-- =============================================================================
CREATE TABLE Trip_Requests (
    request_id      NUMBER(10)    NOT NULL,
    student_id      NUMBER(10)    NOT NULL,
    destination_id  NUMBER(10)    NOT NULL,
    travel_date     DATE          NOT NULL,
    preferred_time  VARCHAR2(10),
    has_connection  CHAR(1)       DEFAULT 'N' NOT NULL,
    connection_time NUMBER(4,2),
    luggage_count   NUMBER(2)     DEFAULT 0 NOT NULL,
    status          VARCHAR2(20)  DEFAULT 'OPEN' NOT NULL,
    created_at      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_trip_requests     PRIMARY KEY (request_id),
    CONSTRAINT fk_tr_student        FOREIGN KEY (student_id)     REFERENCES Students(student_id) ON DELETE CASCADE,
    CONSTRAINT fk_tr_destination    FOREIGN KEY (destination_id) REFERENCES Destinations(destination_id),
    CONSTRAINT chk_has_connection   CHECK (has_connection IN ('Y','N')),
    CONSTRAINT chk_tr_status        CHECK (status IN ('OPEN','MATCHED','CLOSED')),
    CONSTRAINT chk_luggage_pos      CHECK (luggage_count >= 0),
    CONSTRAINT chk_conn_time_req    CHECK (has_connection = 'N' OR connection_time IS NOT NULL)
);

-- =============================================================================
-- TABLE 6: Ride_Groups  (Module C owns)
-- seats_filled and total_luggage are managed EXCLUSIVELY by trg_seat_sync.
-- group_lock_in does NOT manually UPDATE these — the trigger handles it.
-- =============================================================================
CREATE TABLE Ride_Groups (
    group_id        NUMBER(10)   NOT NULL,
    vehicle_id      NUMBER(10)   NOT NULL,
    destination_id  NUMBER(10)   NOT NULL,
    departure_date  DATE         NOT NULL,
    departure_time  VARCHAR2(10),
    seats_filled    NUMBER(2)    DEFAULT 0 NOT NULL,
    total_luggage   NUMBER(2)    DEFAULT 0 NOT NULL,
    status          VARCHAR2(20) DEFAULT 'FORMING' NOT NULL,
    created_at      TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_ride_groups      PRIMARY KEY (group_id),
    CONSTRAINT fk_rg_vehicle       FOREIGN KEY (vehicle_id)     REFERENCES Vehicles(vehicle_id),
    CONSTRAINT fk_rg_destination   FOREIGN KEY (destination_id) REFERENCES Destinations(destination_id),
    CONSTRAINT chk_rg_status       CHECK (status IN ('FORMING','LOCKED','COMPLETED','CANCELLED')),
    CONSTRAINT chk_seats_filled    CHECK (seats_filled >= 0),
    CONSTRAINT chk_total_luggage   CHECK (total_luggage >= 0)
);

-- =============================================================================
-- TABLE 7: Group_Members  (Module C owns)
-- Composite PK (group_id, student_id) prevents duplicate membership.
-- INSERT here fires trg_seat_sync (Module D) which updates Ride_Groups.
-- DELETE here fires trg_trust_on_cancellation (Module D).
-- =============================================================================
CREATE TABLE Group_Members (
    group_id        NUMBER(10)   NOT NULL,
    student_id      NUMBER(10)   NOT NULL,
    joined_at       TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    payment_status  VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    CONSTRAINT pk_group_members    PRIMARY KEY (group_id, student_id),
    CONSTRAINT fk_gm_group         FOREIGN KEY (group_id)   REFERENCES Ride_Groups(group_id),
    CONSTRAINT fk_gm_student       FOREIGN KEY (student_id) REFERENCES Students(student_id),
    CONSTRAINT chk_payment_status  CHECK (payment_status IN ('PENDING','PAID','REFUNDED'))
);

-- =============================================================================
-- TABLE 8: Payments  (Module C owns)
-- =============================================================================
CREATE TABLE Payments (
    payment_id  NUMBER(10)    NOT NULL,
    student_id  NUMBER(10)    NOT NULL,
    group_id    NUMBER(10)    NOT NULL,
    amount      NUMBER(8,2)   NOT NULL,
    status      VARCHAR2(20)  DEFAULT 'PENDING' NOT NULL,
    paid_at     TIMESTAMP,
    CONSTRAINT pk_payments        PRIMARY KEY (payment_id),
    CONSTRAINT fk_pay_student     FOREIGN KEY (student_id) REFERENCES Students(student_id),
    CONSTRAINT fk_pay_group       FOREIGN KEY (group_id)   REFERENCES Ride_Groups(group_id),
    CONSTRAINT chk_amount_pos     CHECK (amount > 0),
    CONSTRAINT chk_pay_status     CHECK (status IN ('PENDING','COMPLETED','FAILED','REFUNDED')),
    CONSTRAINT uq_student_group   UNIQUE (student_id, group_id)
);

-- =============================================================================
-- TABLE 9: Trust_Audit_Log  (Module D owns)
-- IMMUTABLE — trg_immutable_audit blocks all UPDATE and DELETE.
-- Written only via log_trust_change() procedure.
-- =============================================================================
CREATE TABLE Trust_Audit_Log (
    audit_id    NUMBER(10)    NOT NULL,
    student_id  NUMBER(10)    NOT NULL,
    old_score   NUMBER(5,2)   NOT NULL,
    new_score   NUMBER(5,2)   NOT NULL,
    reason      VARCHAR2(200) NOT NULL,
    changed_at  TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_trust_audit    PRIMARY KEY (audit_id),
    CONSTRAINT fk_audit_student  FOREIGN KEY (student_id) REFERENCES Students(student_id)
);

-- =============================================================================
-- SAMPLE DATA
-- Insertion order respects FK dependencies:
--   Destinations → Routes (self-ref on Destinations)
--   Vehicles
--   Students
--   Trip_Requests (refs Students + Destinations)
--   Ride_Groups   (refs Vehicles + Destinations)
--   Group_Members (refs Ride_Groups + Students)
--   Payments      (refs Students + Ride_Groups)
--
-- NOTE: No direct INSERT into Trust_Audit_Log here.
--       The triggers will populate it once they exist (D1_triggers.sql).
-- =============================================================================

-- Destinations (7 rows — matches TRD spec)
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'Patiala',          'N', 0.5);   -- 201
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'Rajpura',          'N', 0.8);   -- 202
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'Ambala',           'N', 1.5);   -- 203
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'Chandigarh',       'N', 1.8);   -- 204
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'Delhi',            'N', 4.0);   -- 205
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'IGI Airport',      'Y', 4.5);   -- 206
INSERT INTO Destinations VALUES (dest_seq.NEXTVAL, 'Railway Station',  'Y', 4.2);   -- 207

-- Routes (9 rows — at least 3 with is_enroute='Y' for en-route matching demo)
-- Direct routes
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 201, 204, 'N', 60.0);   -- Patiala → Chandigarh
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 201, 205, 'N', 250.0);  -- Patiala → Delhi
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 201, 207, 'N', 255.0);  -- Patiala → Railway Station
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 204, 205, 'N', 260.0);  -- Chandigarh → Delhi
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 204, 206, 'N', 270.0);  -- Chandigarh → IGI Airport
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 203, 205, 'N', 200.0);  -- Ambala → Delhi
-- En-route: Chandigarh-bound cab passes through Rajpura
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 202, 204, 'Y', 30.0);   -- 307 Rajpura en-route on Chandigarh cab
-- En-route: Delhi-bound cab passes through Ambala
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 203, 205, 'Y', 200.0);  -- 308 Ambala en-route on Delhi cab
-- En-route: IGI Airport cab passes through Delhi
INSERT INTO Routes VALUES (route_seq.NEXTVAL, 205, 206, 'Y', 20.0);   -- 309 Delhi en-route on IGI cab

-- Vehicles (4 rows)
INSERT INTO Vehicles VALUES (vehicle_seq.NEXTVAL, 'Sedan',           4, 2, 'PB-10-AB-1001');  -- 401
INSERT INTO Vehicles VALUES (vehicle_seq.NEXTVAL, 'SUV',             6, 4, 'PB-10-AB-1002');  -- 402
INSERT INTO Vehicles VALUES (vehicle_seq.NEXTVAL, 'Tempo Traveller', 9, 6, 'PB-10-AB-1003');  -- 403
INSERT INTO Vehicles VALUES (vehicle_seq.NEXTVAL, 'Sedan',           4, 2, 'PB-10-AB-1004');  -- 404 (1 seat remaining — concurrency demo)

-- Students (10 rows — mix of trust scores per TRD spec)
-- At least 2 with trust < 90, at least 2 with trust >= 90, 1 with zero rides
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Aanya Sharma',    'aanya@thapar.edu',   100, 0,  SYSDATE);  -- 1001 zero rides
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Rohan Mehta',     'rohan@thapar.edu',   95,  4,  SYSDATE);  -- 1002 trust >= 90
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Priya Kapoor',    'priya@thapar.edu',   110, 7,  SYSDATE);  -- 1003 trust >= 90
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Kabir Singh',     'kabir@thapar.edu',   75,  2,  SYSDATE);  -- 1004 trust < 90
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Sneha Reddy',     'sneha@thapar.edu',   60,  1,  SYSDATE);  -- 1005 trust < 90
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Arjun Nair',      'arjun@thapar.edu',   100, 3,  SYSDATE);  -- 1006
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Divya Patel',     'divya@thapar.edu',   120, 10, SYSDATE);  -- 1007 high trust
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Varun Gupta',     'varun@thapar.edu',   85,  5,  SYSDATE);  -- 1008
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Meera Joshi',     'meera@thapar.edu',   100, 2,  SYSDATE);  -- 1009
INSERT INTO Students VALUES (student_seq.NEXTVAL, 'Tanvir Hussain',  'tanvir@thapar.edu',  90,  6,  SYSDATE);  -- 1010

-- Trip_Requests (sample — open requests for matching demo)
INSERT INTO Trip_Requests VALUES (request_seq.NEXTVAL, 1001, 205, DATE '2026-05-10', '08:00', 'N', NULL, 1, 'OPEN', SYSTIMESTAMP);  -- 501 Aanya → Delhi
INSERT INTO Trip_Requests VALUES (request_seq.NEXTVAL, 1004, 204, DATE '2026-05-10', '09:00', 'N', NULL, 0, 'OPEN', SYSTIMESTAMP);  -- 502 Kabir → Chandigarh
INSERT INTO Trip_Requests VALUES (request_seq.NEXTVAL, 1005, 202, DATE '2026-05-10', '08:00', 'N', NULL, 1, 'OPEN', SYSTIMESTAMP);  -- 503 Sneha → Rajpura (en-route match candidate)
INSERT INTO Trip_Requests VALUES (request_seq.NEXTVAL, 1002, 206, DATE '2026-05-15', '07:00', 'Y', 6.0, 1, 'OPEN', SYSTIMESTAMP);  -- 504 Rohan → IGI, has connection (PriorityGo eligible: trust=95)
INSERT INTO Trip_Requests VALUES (request_seq.NEXTVAL, 1008, 205, DATE '2026-05-10', '08:00', 'N', NULL, 2, 'OPEN', SYSTIMESTAMP);  -- 505 Varun → Delhi

-- Ride_Groups (5 rows — matches TRD spec for concurrency + completion demo)
-- Group 601: Delhi, 3 seats filled of 4 (Sedan) → 1 seat left for concurrency demo
INSERT INTO Ride_Groups VALUES (group_seq.NEXTVAL, 404, 205, DATE '2026-05-10', '08:00', 3, 2, 'FORMING',   SYSTIMESTAMP);  -- 601
-- Group 602: Chandigarh, 2 of 6 (SUV)
INSERT INTO Ride_Groups VALUES (group_seq.NEXTVAL, 402, 204, DATE '2026-05-10', '09:00', 2, 1, 'FORMING',   SYSTIMESTAMP);  -- 602
-- Group 603: Delhi, 4 of 6 (SUV)
INSERT INTO Ride_Groups VALUES (group_seq.NEXTVAL, 402, 205, DATE '2026-05-12', '10:00', 4, 3, 'FORMING',   SYSTIMESTAMP);  -- 603
-- Group 604: COMPLETED — for trust trigger demo
INSERT INTO Ride_Groups VALUES (group_seq.NEXTVAL, 401, 204, DATE '2026-04-20', '08:00', 4, 2, 'COMPLETED', SYSTIMESTAMP);  -- 604
-- Group 605: IGI Airport, 1 of 6 (SUV) — PriorityGo demo
INSERT INTO Ride_Groups VALUES (group_seq.NEXTVAL, 402, 206, DATE '2026-05-15', '07:00', 1, 1, 'FORMING',   SYSTIMESTAMP);  -- 605

-- Group_Members (12 rows — realistic distribution across groups)
-- NOTE: seats_filled/total_luggage above are set directly for sample data only.
--       Once triggers exist, these cols update automatically on every INSERT/DELETE here.
-- Group 601 members (3 members, 1 seat left — concurrency demo)
INSERT INTO Group_Members VALUES (601, 1003, SYSTIMESTAMP, 'PAID');
INSERT INTO Group_Members VALUES (601, 1006, SYSTIMESTAMP, 'PAID');
INSERT INTO Group_Members VALUES (601, 1007, SYSTIMESTAMP, 'PENDING');
-- Group 602 members
INSERT INTO Group_Members VALUES (602, 1004, SYSTIMESTAMP, 'PENDING');
INSERT INTO Group_Members VALUES (602, 1009, SYSTIMESTAMP, 'PENDING');
-- Group 603 members
INSERT INTO Group_Members VALUES (603, 1002, SYSTIMESTAMP, 'PAID');
INSERT INTO Group_Members VALUES (603, 1005, SYSTIMESTAMP, 'PENDING');
INSERT INTO Group_Members VALUES (603, 1008, SYSTIMESTAMP, 'PENDING');
INSERT INTO Group_Members VALUES (603, 1010, SYSTIMESTAMP, 'PAID');
-- Group 604 members (COMPLETED — trust trigger should fire on status change)
INSERT INTO Group_Members VALUES (604, 1001, SYSTIMESTAMP, 'PAID');
INSERT INTO Group_Members VALUES (604, 1003, SYSTIMESTAMP, 'PAID');
INSERT INTO Group_Members VALUES (604, 1007, SYSTIMESTAMP, 'PAID');
-- Group 605 member (PriorityGo demo — high trust student)
INSERT INTO Group_Members VALUES (605, 1002, SYSTIMESTAMP, 'PAID');

-- Payments (8 rows — mix of statuses including 1 REFUNDED for cancellation demo)
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1003, 601, 950.00,  'COMPLETED', SYSTIMESTAMP);   -- 701
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1006, 601, 950.00,  'COMPLETED', SYSTIMESTAMP);   -- 702
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1007, 601, 950.00,  'PENDING',   NULL);           -- 703
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1004, 602, 800.00,  'PENDING',   NULL);           -- 704
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1002, 603, 900.00,  'COMPLETED', SYSTIMESTAMP);   -- 705
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1008, 603, 900.00,  'REFUNDED',  SYSTIMESTAMP);   -- 706 REFUNDED — cancellation demo
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1001, 604, 750.00,  'COMPLETED', SYSTIMESTAMP);   -- 707
INSERT INTO Payments VALUES (payment_seq.NEXTVAL, 1002, 605, 1100.00, 'COMPLETED', SYSTIMESTAMP);   -- 708 PriorityGo payment

COMMIT;

-- =============================================================================
-- End of A1_ddl.sql
-- =============================================================================
