-- Enhanced Database Schema with Triggers, Locking, and Optimization
-- Campus Resource Optimization System

USE campus_db;

-- ============================================================================
-- 1. AUDIT TABLES FOR TRACKING CHANGES
-- ============================================================================

-- Audit table for bookings
CREATE TABLE IF NOT EXISTS audit_bookings (
    id INT AUTO_INCREMENT PRIMARY KEY,
    booking_id INT NOT NULL,
    action_type ENUM('INSERT', 'UPDATE', 'DELETE') NOT NULL,
    old_data JSON,
    new_data JSON,
    changed_by INT,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_info VARCHAR(255),
    INDEX idx_booking_audit (booking_id, changed_at),
    INDEX idx_audit_user (changed_by)
) ENGINE=InnoDB;

-- Audit table for users (sensitive operations)
CREATE TABLE IF NOT EXISTS audit_users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    action_type ENUM('INSERT', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT') NOT NULL,
    old_data JSON,
    new_data JSON,
    ip_address VARCHAR(45),
    user_agent TEXT,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_user_audit (user_id, changed_at)
) ENGINE=InnoDB;

-- Equipment usage tracking
CREATE TABLE IF NOT EXISTS equipment_usage (
    id INT AUTO_INCREMENT PRIMARY KEY,
    equipment_id INT NOT NULL,
    booking_id INT NOT NULL,
    used_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    usage_duration INT, -- in minutes
    notes TEXT,
    CONSTRAINT fk_equipment_usage_equipment FOREIGN KEY (equipment_id) REFERENCES equipment(id) ON DELETE CASCADE,
    CONSTRAINT fk_equipment_usage_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE,
    INDEX idx_equipment_usage (equipment_id, used_at),
    INDEX idx_booking_equipment (booking_id)
) ENGINE=InnoDB;

-- Session management table for better security
CREATE TABLE IF NOT EXISTS user_sessions (
    id VARCHAR(128) PRIMARY KEY,
    user_id INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_accessed TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    ip_address VARCHAR(45),
    user_agent TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMP,
    CONSTRAINT fk_session_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    INDEX idx_session_user (user_id),
    INDEX idx_session_active (is_active, expires_at)
) ENGINE=InnoDB;

-- ============================================================================
-- 2. ENHANCED TRIGGERS FOR AUDIT LOGGING
-- ============================================================================

-- Booking audit triggers
DELIMITER //

-- Trigger for INSERT on bookings
DROP TRIGGER IF EXISTS trg_bookings_audit_insert//
CREATE TRIGGER trg_bookings_audit_insert
AFTER INSERT ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO audit_bookings (booking_id, action_type, new_data, changed_by)
    VALUES (
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'user_id', NEW.user_id,
            'room_id', NEW.room_id,
            'start_time', NEW.start_time,
            'end_time', NEW.end_time,
            'status', NEW.status
        ),
        NEW.user_id
    );
END//

-- Trigger for UPDATE on bookings
DROP TRIGGER IF EXISTS trg_bookings_audit_update//
CREATE TRIGGER trg_bookings_audit_update
AFTER UPDATE ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO audit_bookings (booking_id, action_type, old_data, new_data, changed_by)
    VALUES (
        NEW.id,
        'UPDATE',
        JSON_OBJECT(
            'user_id', OLD.user_id,
            'room_id', OLD.room_id,
            'start_time', OLD.start_time,
            'end_time', OLD.end_time,
            'status', OLD.status
        ),
        JSON_OBJECT(
            'user_id', NEW.user_id,
            'room_id', NEW.room_id,
            'start_time', NEW.start_time,
            'end_time', NEW.end_time,
            'status', NEW.status
        ),
        NEW.user_id
    );
END//

-- Trigger for DELETE on bookings
DROP TRIGGER IF EXISTS trg_bookings_audit_delete//
CREATE TRIGGER trg_bookings_audit_delete
AFTER DELETE ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO audit_bookings (booking_id, action_type, old_data)
    VALUES (
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'user_id', OLD.user_id,
            'room_id', OLD.room_id,
            'start_time', OLD.start_time,
            'end_time', OLD.end_time,
            'status', OLD.status
        )
    );
END//

-- Equipment usage auto-tracking trigger
DROP TRIGGER IF EXISTS trg_booking_approved_equipment//
CREATE TRIGGER trg_booking_approved_equipment
AFTER UPDATE ON bookings
FOR EACH ROW
BEGIN
    -- When booking is approved, automatically create equipment usage records
    IF OLD.status != 'approved' AND NEW.status = 'approved' THEN
        INSERT INTO equipment_usage (equipment_id, booking_id, notes)
        SELECT e.id, NEW.id, CONCAT('Auto-assigned for booking in ', r.name)
        FROM equipment e
        JOIN rooms r ON e.room_id = r.id
        WHERE r.id = NEW.room_id;
    END IF;
END//

DELIMITER ;

-- ============================================================================
-- 3. PERFORMANCE OPTIMIZATION INDEXES
-- ============================================================================

-- Indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_bookings_room_time ON bookings(room_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_bookings_user_status ON bookings(user_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_status_time ON bookings(status, start_time);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);
CREATE INDEX IF NOT EXISTS idx_equipment_room ON equipment(room_id);
CREATE INDEX IF NOT EXISTS idx_courses_faculty ON courses(faculty_id);

-- Composite index for availability queries
CREATE INDEX IF NOT EXISTS idx_bookings_availability ON bookings(room_id, status, start_time, end_time);

-- ============================================================================
-- 4. STORED PROCEDURES FOR COMPLEX OPERATIONS WITH LOCKING
-- ============================================================================

DELIMITER //

-- Procedure for safe booking with row locking
DROP PROCEDURE IF EXISTS create_booking_with_lock//
CREATE PROCEDURE create_booking_with_lock(
    IN p_user_id INT,
    IN p_room_id INT,
    IN p_start_time DATETIME,
    IN p_end_time DATETIME,
    OUT p_booking_id INT,
    OUT p_result VARCHAR(100)
)
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE conflict_count INT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_result = 'ERROR: Transaction failed';
        SET p_booking_id = 0;
    END;

    START TRANSACTION;

    -- Lock the room record to prevent concurrent bookings
    SELECT id INTO @room_check FROM rooms WHERE id = p_room_id FOR UPDATE;

    IF @room_check IS NULL THEN
        SET p_result = 'ERROR: Room not found';
        SET p_booking_id = 0;
        ROLLBACK;
    ELSE
        -- Check for conflicts with explicit locking
        SELECT COUNT(*) INTO conflict_count
        FROM bookings
        WHERE room_id = p_room_id
        AND status IN ('approved', 'pending')
        AND start_time < p_end_time
        AND end_time > p_start_time
        FOR UPDATE;

        IF conflict_count > 0 THEN
            SET p_result = 'ERROR: Room already booked for this time';
            SET p_booking_id = 0;
            ROLLBACK;
        ELSE
            -- Insert the booking
            INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
            VALUES (p_user_id, p_room_id, p_start_time, p_end_time, 'pending');

            SET p_booking_id = LAST_INSERT_ID();
            SET p_result = 'SUCCESS: Booking created';
            COMMIT;
        END IF;
    END IF;
END//

-- Procedure for bulk approval with locking
DROP PROCEDURE IF EXISTS approve_multiple_bookings//
CREATE PROCEDURE approve_multiple_bookings(
    IN p_booking_ids TEXT,
    IN p_approved_by INT,
    OUT p_approved_count INT,
    OUT p_failed_count INT
)
BEGIN
    DECLARE booking_id INT;
    DECLARE done INT DEFAULT FALSE;
    DECLARE booking_cursor CURSOR FOR
        SELECT CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(p_booking_ids, ',', numbers.n), ',', -1) AS UNSIGNED) as booking_id
        FROM (SELECT 1 n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) numbers
        WHERE CHAR_LENGTH(p_booking_ids) - CHAR_LENGTH(REPLACE(p_booking_ids, ',', '')) >= numbers.n - 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET p_failed_count = p_failed_count + 1;

    SET p_approved_count = 0;
    SET p_failed_count = 0;

    OPEN booking_cursor;

    booking_loop: LOOP
        FETCH booking_cursor INTO booking_id;
        IF done THEN
            LEAVE booking_loop;
        END IF;

        START TRANSACTION;

        -- Lock and update the booking
        UPDATE bookings
        SET status = 'approved'
        WHERE id = booking_id
        AND status = 'pending'
        FOR UPDATE;

        IF ROW_COUNT() > 0 THEN
            SET p_approved_count = p_approved_count + 1;
            COMMIT;
        ELSE
            SET p_failed_count = p_failed_count + 1;
            ROLLBACK;
        END IF;
    END LOOP;

    CLOSE booking_cursor;
END//

-- Procedure for equipment maintenance locking
DROP PROCEDURE IF EXISTS lock_equipment_for_maintenance//
CREATE PROCEDURE lock_equipment_for_maintenance(
    IN p_equipment_id INT,
    IN p_maintenance_duration_hours INT,
    OUT p_result VARCHAR(100)
)
BEGIN
    DECLARE room_bookings INT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_result = 'ERROR: Could not lock equipment';
    END;

    START TRANSACTION;

    -- Lock equipment record
    SELECT room_id INTO @room_id FROM equipment WHERE id = p_equipment_id FOR UPDATE;

    -- Check for active bookings in the next maintenance window
    SELECT COUNT(*) INTO room_bookings
    FROM bookings
    WHERE room_id = @room_id
    AND status IN ('approved', 'pending')
    AND start_time <= DATE_ADD(NOW(), INTERVAL p_maintenance_duration_hours HOUR)
    AND end_time > NOW()
    FOR UPDATE;

    IF room_bookings > 0 THEN
        SET p_result = 'ERROR: Cannot lock - active bookings in maintenance window';
        ROLLBACK;
    ELSE
        -- Mark equipment as under maintenance (you'd add a status column to equipment table)
        -- For now, we'll add a note in equipment_usage
        INSERT INTO equipment_usage (equipment_id, booking_id, notes, usage_duration)
        VALUES (p_equipment_id, 0, 'MAINTENANCE LOCK', p_maintenance_duration_hours * 60);

        SET p_result = 'SUCCESS: Equipment locked for maintenance';
        COMMIT;
    END IF;
END//

-- Procedure for getting room utilization with locking for reports
DROP PROCEDURE IF EXISTS get_room_utilization_report//
CREATE PROCEDURE get_room_utilization_report(
    IN p_start_date DATE,
    IN p_end_date DATE
)
BEGIN
    -- Use shared locks for consistent reporting
    SELECT
        r.id,
        r.name,
        r.type,
        r.capacity,
        COUNT(b.id) as total_bookings,
        COUNT(CASE WHEN b.status = 'approved' THEN 1 END) as approved_bookings,
        SUM(CASE WHEN b.status = 'approved'
            THEN TIMESTAMPDIFF(MINUTE, b.start_time, b.end_time)
            ELSE 0 END) as total_minutes_used,
        ROUND(
            (SUM(CASE WHEN b.status = 'approved'
                THEN TIMESTAMPDIFF(MINUTE, b.start_time, b.end_time)
                ELSE 0 END) /
            (TIMESTAMPDIFF(DAY, p_start_date, p_end_date) * 24 * 60)) * 100, 2
        ) as utilization_percentage
    FROM rooms r
    LEFT JOIN bookings b ON r.id = b.room_id
        AND DATE(b.start_time) BETWEEN p_start_date AND p_end_date
        LOCK IN SHARE MODE
    GROUP BY r.id, r.name, r.type, r.capacity
    ORDER BY utilization_percentage DESC;
END//

DELIMITER ;

-- ============================================================================
-- 5. VIEWS FOR COMMONLY USED QUERIES
-- ============================================================================

-- View for current active bookings with user and room details
CREATE OR REPLACE VIEW active_bookings AS
SELECT
    b.id,
    b.start_time,
    b.end_time,
    b.status,
    u.name as user_name,
    u.email as user_email,
    u.role as user_role,
    r.name as room_name,
    r.type as room_type,
    r.capacity as room_capacity,
    GROUP_CONCAT(e.item_name SEPARATOR ', ') as available_equipment
FROM bookings b
JOIN users u ON b.user_id = u.id
JOIN rooms r ON b.room_id = r.id
LEFT JOIN equipment e ON r.id = e.room_id
WHERE b.status IN ('approved', 'pending')
AND b.end_time > NOW()
GROUP BY b.id, b.start_time, b.end_time, b.status, u.name, u.email, u.role, r.name, r.type, r.capacity;

-- View for room availability summary
CREATE OR REPLACE VIEW room_availability_summary AS
SELECT
    r.id,
    r.name,
    r.type,
    r.capacity,
    COUNT(CASE WHEN b.status = 'approved' AND b.start_time > NOW() THEN 1 END) as upcoming_bookings,
    COUNT(CASE WHEN b.status = 'pending' THEN 1 END) as pending_bookings,
    MAX(CASE WHEN b.status = 'approved' THEN b.end_time END) as last_booked_until
FROM rooms r
LEFT JOIN bookings b ON r.id = b.room_id
GROUP BY r.id, r.name, r.type, r.capacity;

-- ============================================================================
-- 6. SECURITY ENHANCEMENTS
-- ============================================================================

-- Add password history table (for future password policy implementation)
CREATE TABLE IF NOT EXISTS password_history (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_password_history_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    INDEX idx_password_user (user_id, created_at)
) ENGINE=InnoDB;

-- Add login attempts tracking
CREATE TABLE IF NOT EXISTS login_attempts (
    id INT AUTO_INCREMENT PRIMARY KEY,
    email VARCHAR(120),
    ip_address VARCHAR(45),
    attempt_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    success BOOLEAN DEFAULT FALSE,
    user_agent TEXT,
    INDEX idx_login_attempts_email (email, attempt_time),
    INDEX idx_login_attempts_ip (ip_address, attempt_time)
) ENGINE=InnoDB;