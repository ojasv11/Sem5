
DROP DATABASE IF EXISTS clara_db;

CREATE DATABASE clara_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE clara_db;


-- =====================================================================
-- STEP 2: Tables, in dependency order (parents before children)
--
--   Buildings -> Classrooms -> Timetable -> TimetableSections <- Sections <- Courses
--                    |            ^
--                    |         Subjects
--                    +--> AllocationRequests <- Users
--                    +--> Allocations        <- Users, AllocationRequests
--
--   Timetable         = WHERE and WHEN: one row per room in use (e.g. LT6, Mon 09:00-09:55)
--   TimetableSections = WHO attends it. A combined class (sections A + B together)
--                       is ONE Timetable row with TWO TimetableSections rows.
-- =====================================================================

-- 2.1 Buildings: one row per building. Adding a new building later is one INSERT.
CREATE TABLE Buildings (
    building_id    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    building_name  VARCHAR(100)  NOT NULL,

    CONSTRAINT pk_buildings      PRIMARY KEY (building_id),
    CONSTRAINT uq_buildings_name UNIQUE (building_name)
) ENGINE = InnoDB;


-- 2.2 Classrooms: every bookable room (classroom or lab) in any building.
CREATE TABLE Classrooms (
    room_id      INT UNSIGNED             NOT NULL AUTO_INCREMENT,
    room_name    VARCHAR(50)              NOT NULL,
    room_type    ENUM('Classroom', 'Lab') NOT NULL,
    building_id  INT UNSIGNED             NOT NULL,

    CONSTRAINT pk_classrooms PRIMARY KEY (room_id),
    -- The same room name may exist in two buildings, but not twice in one building
    CONSTRAINT uq_classrooms_building_room UNIQUE (building_id, room_name),
    CONSTRAINT fk_classrooms_building FOREIGN KEY (building_id)
        REFERENCES Buildings (building_id)
        ON DELETE RESTRICT,
    INDEX idx_classrooms_type (room_type)
) ENGINE = InnoDB;


-- 2.3 Courses: one row per programme and year, e.g. ('B.Tech CSE', 3).
CREATE TABLE Courses (
    course_id    INT UNSIGNED     NOT NULL AUTO_INCREMENT,
    course_name  VARCHAR(50)      NOT NULL,   -- 'B.Tech CSE', 'BCA', 'B.Com'
    course_year  TINYINT UNSIGNED NOT NULL,   -- 1 to 4

    CONSTRAINT pk_courses           PRIMARY KEY (course_id),
    CONSTRAINT uq_courses_name_year UNIQUE (course_name, course_year),
    CONSTRAINT chk_courses_year     CHECK (course_year BETWEEN 1 AND 4)
) ENGINE = InnoDB;


-- 2.3a Sections: the sections of each course and year, e.g. B.Tech CSE 3 - A.
CREATE TABLE Sections (
    section_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    course_id     INT UNSIGNED NOT NULL,
    section_name  VARCHAR(20)  NOT NULL,      -- 'A', 'B', 'DS1', ...

    CONSTRAINT pk_sections              PRIMARY KEY (section_id),
    CONSTRAINT uq_sections_course_name  UNIQUE (course_id, section_name),
    CONSTRAINT fk_sections_course FOREIGN KEY (course_id)
        REFERENCES Courses (course_id)
        ON DELETE RESTRICT
) ENGINE = InnoDB;


-- 2.3b Subjects: subject codes ('TCS-514') or activity names ('Career Excellence Classes (CEC)').
CREATE TABLE Subjects (
    subject_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    subject_code  VARCHAR(100) NOT NULL,
    subject_name  VARCHAR(150) NULL,          -- full name, can be filled in later

    CONSTRAINT pk_subjects      PRIMARY KEY (subject_id),
    CONSTRAINT uq_subjects_code UNIQUE (subject_code)
) ENGINE = InnoDB;


-- 2.4 Users: admin accounts only at this stage (no Faculty role yet).
CREATE TABLE Users (
    user_id        INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    username       VARCHAR(50)   NOT NULL,
    full_name      VARCHAR(100)  NOT NULL,
    email          VARCHAR(255)  NOT NULL,
    password_hash  VARCHAR(255)  NOT NULL,      -- a bcrypt/argon2 hash, never the plain password
    role           ENUM('Admin') NOT NULL DEFAULT 'Admin',
    is_active      BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_users          PRIMARY KEY (user_id),
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT uq_users_email    UNIQUE (email)
) ENGINE = InnoDB;


-- 2.5 Timetable: the regular weekly classes. One row = one room in use at one time.
CREATE TABLE Timetable (
    timetable_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    room_id       INT UNSIGNED NOT NULL,
    subject_id    INT UNSIGNED NOT NULL,
    day_of_week   ENUM('Monday', 'Tuesday', 'Wednesday',
                       'Thursday', 'Friday', 'Saturday') NOT NULL,
    start_time    TIME NOT NULL,
    end_time      TIME NOT NULL,

    CONSTRAINT pk_timetable        PRIMARY KEY (timetable_id),
    CONSTRAINT chk_timetable_times CHECK (end_time > start_time),
    -- Quick guard against exact duplicates; partial overlaps are blocked by triggers (Step 5)
    CONSTRAINT uq_timetable_room_slot UNIQUE (room_id, day_of_week, start_time),
    CONSTRAINT fk_timetable_room FOREIGN KEY (room_id)
        REFERENCES Classrooms (room_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_timetable_subject FOREIGN KEY (subject_id)
        REFERENCES Subjects (subject_id)
        ON DELETE RESTRICT
) ENGINE = InnoDB;


-- 2.5a TimetableSections: which sections (and lab group) attend each timetable row.
--      group_name 'All' = whole section; 'G1'/'G2' = half of the section (lab batches).
CREATE TABLE TimetableSections (
    timetable_id  INT UNSIGNED NOT NULL,
    section_id    INT UNSIGNED NOT NULL,
    group_name    ENUM('All', 'G1', 'G2') NOT NULL DEFAULT 'All',

    CONSTRAINT pk_timetable_sections PRIMARY KEY (timetable_id, section_id, group_name),
    CONSTRAINT fk_ts_timetable FOREIGN KEY (timetable_id)
        REFERENCES Timetable (timetable_id)
        ON DELETE CASCADE,          -- deleting a class removes its attendance rows
    CONSTRAINT fk_ts_section FOREIGN KEY (section_id)
        REFERENCES Sections (section_id)
        ON DELETE RESTRICT,
    INDEX idx_ts_section (section_id)
) ENGINE = InnoDB;


-- 2.6 AllocationRequests: temporary booking requests waiting for a decision.
--     A request names EITHER a specific room OR a room type, never both.
CREATE TABLE AllocationRequests (
    request_id           INT UNSIGNED NOT NULL AUTO_INCREMENT,
    requested_room_id    INT UNSIGNED NULL,
    requested_room_type  ENUM('Classroom', 'Lab') NULL,
    request_date         DATE NOT NULL,              -- the date the room is needed
    start_time           TIME NOT NULL,
    end_time             TIME NOT NULL,
    priority             ENUM('Low', 'Medium', 'High') NOT NULL DEFAULT 'Medium',
    request_status       ENUM('Pending', 'Approved', 'Rejected', 'Cancelled')
                             NOT NULL DEFAULT 'Pending',
    purpose              VARCHAR(255) NULL,
    requested_by         INT UNSIGNED NOT NULL,
    request_timestamp    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_allocation_requests PRIMARY KEY (request_id),
    CONSTRAINT chk_requests_times     CHECK (end_time > start_time),
    CONSTRAINT chk_requests_target    CHECK ((requested_room_id IS NULL) <> (requested_room_type IS NULL)),
    -- No ON DELETE/ON UPDATE action here: MySQL forbids referential actions on
    -- columns used in a CHECK constraint, so the default (RESTRICT) applies.
    CONSTRAINT fk_requests_room FOREIGN KEY (requested_room_id)
        REFERENCES Classrooms (room_id),
    CONSTRAINT fk_requests_user FOREIGN KEY (requested_by)
        REFERENCES Users (user_id)
        ON DELETE RESTRICT,
    INDEX idx_requests_queue (request_status, priority, request_timestamp)
) ENGINE = InnoDB;


-- 2.7 Allocations: confirmed temporary bookings of a specific room on a specific date.
--     request_id is NULL when an admin books a room directly (no request).
CREATE TABLE Allocations (
    allocation_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    room_id            INT UNSIGNED NOT NULL,
    allocation_date    DATE NOT NULL,
    start_time         TIME NOT NULL,
    end_time           TIME NOT NULL,
    allocation_status  ENUM('Confirmed', 'Cancelled') NOT NULL DEFAULT 'Confirmed',
    request_id         INT UNSIGNED NULL,
    allocated_by       INT UNSIGNED NOT NULL,
    allocated_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_allocations        PRIMARY KEY (allocation_id),
    CONSTRAINT chk_allocations_times CHECK (end_time > start_time),
    CONSTRAINT fk_allocations_room FOREIGN KEY (room_id)
        REFERENCES Classrooms (room_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_allocations_request FOREIGN KEY (request_id)
        REFERENCES AllocationRequests (request_id)
        ON DELETE SET NULL,
    CONSTRAINT fk_allocations_user FOREIGN KEY (allocated_by)
        REFERENCES Users (user_id)
        ON DELETE RESTRICT,
    INDEX idx_allocations_room_date (room_id, allocation_date, start_time),
    INDEX idx_allocations_request (request_id)
) ENGINE = InnoDB;


-- 2.8 TimetableStaging: a temporary holding table for the converter's CSV.
--     Plain text columns and no rules, so the CSV import never fails halfway.
--     sp_import_timetable (Step 6.4) checks it and copies it into the real tables.
--     Column names match the CSV header, so Workbench's import wizard maps them itself.
CREATE TABLE TimetableStaging (
    staging_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
    day          VARCHAR(20),
    start_time   VARCHAR(10),
    end_time     VARCHAR(10),
    room         VARCHAR(50),
    subject      VARCHAR(100),
    course       VARCHAR(50),
    year         VARCHAR(5),
    section      VARCHAR(20),
    group_name   VARCHAR(10),
    source_cell  VARCHAR(30),

    CONSTRAINT pk_timetable_staging PRIMARY KEY (staging_id)
) ENGINE = InnoDB;


-- =====================================================================
-- STEP 3: A read-only view for the GUI's "View Timetable" screen
-- =====================================================================
CREATE VIEW v_timetable_details AS
SELECT
    t.timetable_id,
    t.day_of_week,
    t.start_time,
    t.end_time,
    r.room_name,
    r.room_type,
    b.building_name,
    sub.subject_code,
    GROUP_CONCAT(CONCAT(c.course_name, ' ', c.course_year, '-', sec.section_name,
                        IF(ts.group_name = 'All', '', CONCAT(' (', ts.group_name, ')')))
                 ORDER BY c.course_name, c.course_year, sec.section_name
                 SEPARATOR ', ') AS attending
FROM Timetable  t
JOIN Classrooms r   ON r.room_id     = t.room_id
JOIN Buildings  b   ON b.building_id = r.building_id
JOIN Subjects   sub ON sub.subject_id = t.subject_id
LEFT JOIN TimetableSections ts  ON ts.timetable_id = t.timetable_id
LEFT JOIN Sections          sec ON sec.section_id  = ts.section_id
LEFT JOIN Courses           c   ON c.course_id     = sec.course_id
GROUP BY t.timetable_id, t.day_of_week, t.start_time, t.end_time,
         r.room_name, r.room_type, b.building_name, sub.subject_code;


-- =====================================================================
-- STEP 4: Clash-checking procedures (called by the triggers in Step 5)
--
-- Two time slots overlap when:  existing.start < new.end AND new.start < existing.end
-- The comparison is strict, so a class ending at 10:00 does NOT clash with
-- one starting at 10:00 (back-to-back bookings are allowed).
--
-- These checks use plain reads only. MySQL does not let a trigger lock rows
-- (SELECT ... FOR UPDATE) in a table that the triggering statement is also
-- using (error 1442), so the locking is done by the booking procedures in Step 6.
-- =====================================================================
DELIMITER $$

CREATE PROCEDURE sp_assert_timetable_slot_free(
    IN p_room_id    INT UNSIGNED,
    IN p_day        VARCHAR(9),
    IN p_start      TIME,
    IN p_end        TIME,
    IN p_exclude_id INT UNSIGNED   -- the timetable row being updated, or 0 for a new row
)
BEGIN
    DECLARE v_room_name VARCHAR(50);
    DECLARE v_date      DATE DEFAULT NULL;
    DECLARE v_start     TIME DEFAULT NULL;
    DECLARE v_end       TIME DEFAULT NULL;
    DECLARE v_msg       VARCHAR(128);
    -- An empty SELECT ... INTO just leaves the variables NULL (no warning leaks out)
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    SELECT room_name INTO v_room_name
    FROM Classrooms
    WHERE room_id = p_room_id;

    -- (a) Another weekly class in the same room, same day, overlapping time
    SELECT start_time, end_time INTO v_start, v_end
    FROM Timetable
    WHERE room_id = p_room_id
      AND day_of_week = p_day
      AND timetable_id <> p_exclude_id
      AND start_time < p_end
      AND p_start < end_time
    ORDER BY start_time
    LIMIT 1;

    IF v_start IS NOT NULL THEN
        SET v_msg = LEFT(CONCAT('Room clash: ', v_room_name, ' already has a class on ', p_day, ' ',
                                TIME_FORMAT(v_start, '%H:%i'), '-', TIME_FORMAT(v_end, '%H:%i'), '.'), 128);
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- (b) An upcoming confirmed temporary booking of this room on the same weekday
    SELECT allocation_date, start_time, end_time INTO v_date, v_start, v_end
    FROM Allocations
    WHERE room_id = p_room_id
      AND allocation_status = 'Confirmed'
      AND allocation_date >= CURDATE()
      AND ELT(WEEKDAY(allocation_date) + 1, 'Monday', 'Tuesday', 'Wednesday',
              'Thursday', 'Friday', 'Saturday', 'Sunday') = p_day
      AND start_time < p_end
      AND p_start < end_time
    ORDER BY allocation_date, start_time
    LIMIT 1;

    IF v_date IS NOT NULL THEN
        SET v_msg = LEFT(CONCAT('Booking clash: ', v_room_name, ' is booked on ',
                                DATE_FORMAT(v_date, '%d-%m-%Y'), ' ',
                                TIME_FORMAT(v_start, '%H:%i'), '-', TIME_FORMAT(v_end, '%H:%i'), '.'), 128);
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$


CREATE PROCEDURE sp_assert_allocation_slot_free(
    IN p_room_id    INT UNSIGNED,
    IN p_date       DATE,
    IN p_start      TIME,
    IN p_end        TIME,
    IN p_exclude_id INT UNSIGNED   -- the allocation row being updated, or 0 for a new row
)
BEGIN
    DECLARE v_room_name VARCHAR(50);
    DECLARE v_day       VARCHAR(9);
    DECLARE v_start     TIME DEFAULT NULL;
    DECLARE v_end       TIME DEFAULT NULL;
    DECLARE v_msg       VARCHAR(128);
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    -- ELT + WEEKDAY gives an English day name regardless of server locale settings
    SET v_day = ELT(WEEKDAY(p_date) + 1, 'Monday', 'Tuesday', 'Wednesday',
                    'Thursday', 'Friday', 'Saturday', 'Sunday');

    SELECT room_name INTO v_room_name
    FROM Classrooms
    WHERE room_id = p_room_id;

    -- (a) Another confirmed booking of the same room on the same date
    SELECT start_time, end_time INTO v_start, v_end
    FROM Allocations
    WHERE room_id = p_room_id
      AND allocation_date = p_date
      AND allocation_status = 'Confirmed'
      AND allocation_id <> p_exclude_id
      AND start_time < p_end
      AND p_start < end_time
    ORDER BY start_time
    LIMIT 1;

    IF v_start IS NOT NULL THEN
        SET v_msg = LEFT(CONCAT('Booking clash: ', v_room_name, ' is already booked ',
                                TIME_FORMAT(v_start, '%H:%i'), '-', TIME_FORMAT(v_end, '%H:%i'),
                                ' on ', DATE_FORMAT(p_date, '%d-%m-%Y'), '.'), 128);
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- (b) A regular weekly class in this room on that weekday
    SELECT start_time, end_time INTO v_start, v_end
    FROM Timetable
    WHERE room_id = p_room_id
      AND day_of_week = v_day
      AND start_time < p_end
      AND p_start < end_time
    ORDER BY start_time
    LIMIT 1;

    IF v_start IS NOT NULL THEN
        SET v_msg = LEFT(CONCAT('Timetable clash: ', v_room_name, ' has a regular class on ', v_day, ' ',
                                TIME_FORMAT(v_start, '%H:%i'), '-', TIME_FORMAT(v_end, '%H:%i'), '.'), 128);
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$


CREATE PROCEDURE sp_assert_section_free(
    IN p_timetable_id INT UNSIGNED,
    IN p_section_id   INT UNSIGNED,
    IN p_group        VARCHAR(3)
)
BEGIN
    -- A section cannot be in two classes at once. Exception: its two lab groups
    -- (G1 and G2) may be in different rooms at the same time.
    DECLARE v_day     VARCHAR(9);
    DECLARE v_start   TIME;
    DECLARE v_end     TIME;
    DECLARE v_c_start TIME DEFAULT NULL;
    DECLARE v_c_end   TIME DEFAULT NULL;
    DECLARE v_room    VARCHAR(50);
    DECLARE v_label   VARCHAR(80);
    DECLARE v_msg     VARCHAR(128);
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    SELECT day_of_week, start_time, end_time INTO v_day, v_start, v_end
    FROM Timetable
    WHERE timetable_id = p_timetable_id;

    SELECT t.start_time, t.end_time, r.room_name INTO v_c_start, v_c_end, v_room
    FROM TimetableSections ts
    JOIN Timetable  t ON t.timetable_id = ts.timetable_id
    JOIN Classrooms r ON r.room_id      = t.room_id
    WHERE ts.section_id = p_section_id
      AND ts.timetable_id <> p_timetable_id
      AND t.day_of_week = v_day
      AND t.start_time < v_end
      AND v_start < t.end_time
      AND (ts.group_name = 'All' OR p_group = 'All' OR ts.group_name = p_group)
    ORDER BY t.start_time
    LIMIT 1;

    IF v_c_start IS NOT NULL THEN
        SELECT CONCAT(c.course_name, ' ', c.course_year, '-', sec.section_name) INTO v_label
        FROM Sections sec
        JOIN Courses c ON c.course_id = sec.course_id
        WHERE sec.section_id = p_section_id;

        SET v_msg = LEFT(CONCAT('Section clash: ', v_label, ' already has a class on ', v_day, ' ',
                                TIME_FORMAT(v_c_start, '%H:%i'), '-', TIME_FORMAT(v_c_end, '%H:%i'),
                                ' in ', v_room, '.'), 128);
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$


-- =====================================================================
-- STEP 5: Triggers. They run automatically on every INSERT/UPDATE, so no
-- program (GUI, Workbench, script) can save an overlapping booking.
-- =====================================================================
CREATE TRIGGER trg_timetable_before_insert
BEFORE INSERT ON Timetable
FOR EACH ROW
BEGIN
    CALL sp_assert_timetable_slot_free(NEW.room_id, NEW.day_of_week,
                                       NEW.start_time, NEW.end_time, 0);
END$$

CREATE TRIGGER trg_timetable_before_update
BEFORE UPDATE ON Timetable
FOR EACH ROW
BEGIN
    CALL sp_assert_timetable_slot_free(NEW.room_id, NEW.day_of_week,
                                       NEW.start_time, NEW.end_time, OLD.timetable_id);
END$$

CREATE TRIGGER trg_allocations_before_insert
BEFORE INSERT ON Allocations
FOR EACH ROW
BEGIN
    -- Cancelled rows do not occupy the room, so only confirmed rows are checked
    IF NEW.allocation_status = 'Confirmed' THEN
        CALL sp_assert_allocation_slot_free(NEW.room_id, NEW.allocation_date,
                                            NEW.start_time, NEW.end_time, 0);
    END IF;
END$$

CREATE TRIGGER trg_allocations_before_update
BEFORE UPDATE ON Allocations
FOR EACH ROW
BEGIN
    IF NEW.allocation_status = 'Confirmed' THEN
        CALL sp_assert_allocation_slot_free(NEW.room_id, NEW.allocation_date,
                                            NEW.start_time, NEW.end_time, OLD.allocation_id);
    END IF;
END$$

CREATE TRIGGER trg_timetable_sections_before_insert
BEFORE INSERT ON TimetableSections
FOR EACH ROW
BEGIN
    CALL sp_assert_section_free(NEW.timetable_id, NEW.section_id, NEW.group_name);
END$$

CREATE TRIGGER trg_timetable_sections_before_update
BEFORE UPDATE ON TimetableSections
FOR EACH ROW
BEGIN
    CALL sp_assert_section_free(NEW.timetable_id, NEW.section_id, NEW.group_name);
END$$


-- =====================================================================
-- STEP 6: Booking procedures (transaction control + concurrency control)
--
-- Every booking procedure follows the same locking protocol:
--   1. READ COMMITTED isolation, so every statement sees the latest committed data.
--   2. START TRANSACTION.
--   3. Lock the room's row in Classrooms with SELECT ... FOR UPDATE.
--      That row is the room's mutex: a second transaction for the same room
--      waits here until the first one commits or rolls back.
--   4. INSERT. The trigger checks for clashes, and because of steps 1 and 3
--      it sees any booking that the other transaction has just committed.
--   5. COMMIT, or ROLLBACK if anything failed.
--
-- The application should be given EXECUTE on these procedures but not direct
-- INSERT on Timetable/Allocations, so every booking follows this protocol.
-- =====================================================================

-- 6.1 Add one weekly timetable entry safely
-- (Attach sections to the new entry afterwards with INSERT INTO TimetableSections.)
CREATE PROCEDURE sp_add_timetable_entry(
    IN  p_room_id      INT UNSIGNED,
    IN  p_subject_id   INT UNSIGNED,
    IN  p_day          VARCHAR(9),
    IN  p_start        TIME,
    IN  p_end          TIME,
    OUT p_timetable_id INT UNSIGNED
)
BEGIN
    DECLARE v_locked INT UNSIGNED DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_timetable_id = NULL;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;

    SELECT room_id INTO v_locked
    FROM Classrooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF v_locked IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room not found.';
    END IF;

    INSERT INTO Timetable (room_id, subject_id, day_of_week, start_time, end_time)
    VALUES (p_room_id, p_subject_id, p_day, p_start, p_end);
    SET p_timetable_id = LAST_INSERT_ID();

    COMMIT;
END$$


-- 6.2 Book a room directly (no request), for example by an admin
CREATE PROCEDURE sp_book_room(
    IN  p_room_id       INT UNSIGNED,
    IN  p_date          DATE,
    IN  p_start         TIME,
    IN  p_end           TIME,
    IN  p_admin_id      INT UNSIGNED,
    OUT p_allocation_id INT UNSIGNED
)
BEGIN
    DECLARE v_locked INT UNSIGNED DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_allocation_id = NULL;
    IF p_date < CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rooms cannot be booked for a past date.';
    END IF;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;

    SELECT room_id INTO v_locked
    FROM Classrooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF v_locked IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room not found.';
    END IF;

    INSERT INTO Allocations (room_id, allocation_date, start_time, end_time,
                             allocation_status, allocated_by)
    VALUES (p_room_id, p_date, p_start, p_end, 'Confirmed', p_admin_id);
    SET p_allocation_id = LAST_INSERT_ID();

    COMMIT;
END$$


-- 6.3 Approve a pending request
--   1. Lock the request row, so two admins cannot approve it at the same time.
--   2. Try each candidate room in room_id order (the requested room, or every
--      room of the requested type): lock it, then try to insert. A clash
--      (SQLSTATE 45001 from the trigger) just moves on to the next room.
--   3. On success, mark the request Approved and COMMIT. On any error, ROLLBACK.
--   Locking rooms in a fixed order (room_id) prevents deadlocks: the
--   resource-ordering rule from Operating Systems.
CREATE PROCEDURE sp_approve_request(
    IN  p_request_id    INT UNSIGNED,
    IN  p_admin_id      INT UNSIGNED,
    OUT p_allocation_id INT UNSIGNED
)
BEGIN
    DECLARE v_status    VARCHAR(20) DEFAULT NULL;
    DECLARE v_room_id   INT UNSIGNED DEFAULT NULL;
    DECLARE v_room_type VARCHAR(20) DEFAULT NULL;
    DECLARE v_date      DATE;
    DECLARE v_start     TIME;
    DECLARE v_end       TIME;
    DECLARE v_candidate INT UNSIGNED;
    DECLARE v_locked    INT UNSIGNED;
    DECLARE v_done      BOOLEAN DEFAULT FALSE;
    DECLARE v_clash     BOOLEAN DEFAULT FALSE;

    -- Cursor variables are read when the cursor is OPENed, not here
    DECLARE cur_rooms CURSOR FOR
        SELECT room_id
        FROM Classrooms
        WHERE (v_room_id IS NOT NULL AND room_id = v_room_id)
           OR (v_room_id IS NULL AND room_type = v_room_type)
        ORDER BY room_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- Any unexpected error: undo everything, then pass the error to the caller
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_allocation_id = NULL;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;

    SELECT request_status, requested_room_id, requested_room_type,
           request_date, start_time, end_time
      INTO v_status, v_room_id, v_room_type, v_date, v_start, v_end
    FROM AllocationRequests
    WHERE request_id = p_request_id
    FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found.';
    END IF;
    IF v_status <> 'Pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only pending requests can be approved.';
    END IF;
    IF v_date < CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This request is for a past date and cannot be approved.';
    END IF;

    SET v_done = FALSE;
    OPEN cur_rooms;

    room_loop: LOOP
        FETCH cur_rooms INTO v_candidate;
        IF v_done THEN
            LEAVE room_loop;
        END IF;

        -- Lock this room (its mutex) before checking and inserting
        SELECT room_id INTO v_locked
        FROM Classrooms
        WHERE room_id = v_candidate
        FOR UPDATE;

        BEGIN
            -- A clash on this room is expected sometimes: note it and try the next room
            DECLARE CONTINUE HANDLER FOR SQLSTATE '45001' SET v_clash = TRUE;
            SET v_clash = FALSE;

            INSERT INTO Allocations
                (room_id, allocation_date, start_time, end_time,
                 allocation_status, request_id, allocated_by)
            VALUES
                (v_candidate, v_date, v_start, v_end,
                 'Confirmed', p_request_id, p_admin_id);
        END;

        IF NOT v_clash THEN
            SET p_allocation_id = LAST_INSERT_ID();
            LEAVE room_loop;
        END IF;
    END LOOP;

    CLOSE cur_rooms;

    IF p_allocation_id IS NULL THEN
        SIGNAL SQLSTATE '45002'
            SET MESSAGE_TEXT = 'No suitable room is free for this request. It is still pending.';
    END IF;

    UPDATE AllocationRequests
    SET request_status = 'Approved'
    WHERE request_id = p_request_id;

    COMMIT;
END$$

-- 6.4 Import the timetable from TimetableStaging (one transaction: all or nothing)
--   1. Refuse if the staging rows have errors (unknown room, bad time, ...).
--   2. Delete the old timetable of the sections being uploaded (re-upload replaces it).
--   3. Add any new courses, sections and subjects.
--   4. Insert one Timetable row per room + day + time. Rows of several sections in
--      the same room at the same time become ONE row: a combined class.
--   5. Link every section to its row. The triggers check every insert for clashes;
--      if any check fails, everything is rolled back.
CREATE PROCEDURE sp_import_timetable(
    IN p_building_name VARCHAR(100)
)
BEGIN
    DECLARE v_bad_rows   INT DEFAULT 0;
    DECLARE v_mismatches INT DEFAULT 0;
    DECLARE v_msg        VARCHAR(128);
    DECLARE v_safe_mode  INT DEFAULT @@SESSION.sql_safe_updates;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET SESSION sql_safe_updates = v_safe_mode;
        RESIGNAL;
    END;

    -- Workbench's "Safe Updates" mode would block the DELETE in step 2.
    -- Switch it off for this procedure only, and restore it at the end.
    SET SESSION sql_safe_updates = 0;

    SELECT COUNT(*) INTO v_bad_rows
    FROM TimetableStaging st
    WHERE COALESCE(st.day, '') NOT IN ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
       OR COALESCE(st.start_time, '') NOT REGEXP '^[0-2][0-9]:[0-5][0-9]$'
       OR COALESCE(st.end_time, '')   NOT REGEXP '^[0-2][0-9]:[0-5][0-9]$'
       OR st.end_time <= st.start_time
       OR COALESCE(st.year, '') NOT REGEXP '^[1-4]$'
       OR COALESCE(st.course, '') = ''
       OR COALESCE(st.section, '') = ''
       OR COALESCE(st.subject, '') = ''
       OR COALESCE(st.group_name, '') NOT IN ('All', 'G1', 'G2')
       OR NOT EXISTS (SELECT 1
                      FROM Classrooms r
                      JOIN Buildings b ON b.building_id = r.building_id
                      WHERE b.building_name = p_building_name
                        AND r.room_name = st.room);

    SELECT COUNT(*) INTO v_mismatches
    FROM (SELECT room
          FROM TimetableStaging
          GROUP BY room, day, start_time, end_time
          HAVING COUNT(DISTINCT subject) > 1) AS x;

    IF v_bad_rows > 0 OR v_mismatches > 0 THEN
        SET v_msg = LEFT(CONCAT('Import stopped: ', v_bad_rows, ' invalid rows, ', v_mismatches,
                                ' room slots with different subjects. Run the checks in file 03.'), 128);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    START TRANSACTION;

    -- 2. Replace the old timetable of these sections
    DELETE FROM Timetable
    WHERE timetable_id IN (
        SELECT timetable_id FROM (            -- derived table: the list is built first
            SELECT DISTINCT ts.timetable_id
            FROM TimetableSections ts
            JOIN Sections sec ON sec.section_id = ts.section_id
            JOIN Courses  c   ON c.course_id    = sec.course_id
            JOIN (SELECT DISTINCT course, year, section FROM TimetableStaging) st
              ON st.course = c.course_name AND st.year = c.course_year AND st.section = sec.section_name
        ) AS old_rows);

    -- 3. New courses, sections and subjects
    INSERT INTO Courses (course_name, course_year)
    SELECT DISTINCT st.course, CAST(st.year AS UNSIGNED)
    FROM TimetableStaging st
    WHERE NOT EXISTS (SELECT 1 FROM Courses c
                      WHERE c.course_name = st.course AND c.course_year = st.year);

    INSERT INTO Sections (course_id, section_name)
    SELECT DISTINCT c.course_id, st.section
    FROM TimetableStaging st
    JOIN Courses c ON c.course_name = st.course AND c.course_year = st.year
    WHERE NOT EXISTS (SELECT 1 FROM Sections sec
                      WHERE sec.course_id = c.course_id AND sec.section_name = st.section);

    INSERT INTO Subjects (subject_code)
    SELECT DISTINCT st.subject
    FROM TimetableStaging st
    WHERE NOT EXISTS (SELECT 1 FROM Subjects sub WHERE sub.subject_code = st.subject);

    -- 4. One Timetable row per room + day + time (combined classes become one row)
    INSERT INTO Timetable (room_id, subject_id, day_of_week, start_time, end_time)
    SELECT r.room_id, MIN(sub.subject_id), st.day,
           CAST(CONCAT(st.start_time, ':00') AS TIME),
           CAST(CONCAT(st.end_time, ':00') AS TIME)
    FROM TimetableStaging st
    JOIN Classrooms r  ON r.room_name = st.room
    JOIN Buildings  b  ON b.building_id = r.building_id AND b.building_name = p_building_name
    JOIN Subjects  sub ON sub.subject_code = st.subject
    GROUP BY r.room_id, st.day, st.start_time, st.end_time;

    -- 5. Who attends each row
    INSERT INTO TimetableSections (timetable_id, section_id, group_name)
    SELECT DISTINCT t.timetable_id, sec.section_id, st.group_name
    FROM TimetableStaging st
    JOIN Classrooms r ON r.room_name = st.room
    JOIN Buildings  b ON b.building_id = r.building_id AND b.building_name = p_building_name
    JOIN Timetable  t ON t.room_id = r.room_id
                     AND t.day_of_week = st.day
                     AND t.start_time = CAST(CONCAT(st.start_time, ':00') AS TIME)
                     AND t.end_time   = CAST(CONCAT(st.end_time, ':00') AS TIME)
    JOIN Courses  c   ON c.course_name = st.course AND c.course_year = st.year
    JOIN Sections sec ON sec.course_id = c.course_id AND sec.section_name = st.section;

    COMMIT;
    SET SESSION sql_safe_updates = v_safe_mode;

    SELECT (SELECT COUNT(*) FROM TimetableStaging)  AS csv_rows,
           (SELECT COUNT(*) FROM Timetable)         AS timetable_entries,
           (SELECT COUNT(*) FROM TimetableSections) AS section_links;
END$$

DELIMITER ;

-- Done. Next, run 02_clara_base_data.sql.
