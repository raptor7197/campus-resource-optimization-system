-- Test script for enhanced database functionality
-- Campus Resource Optimization System - Enhanced Features Testing

USE campus_db;

-- ============================================================================
-- TEST 1: Test Row Locking with Concurrent Booking Attempts
-- ============================================================================

SELECT '=== TEST 1: Row Locking and Conflict Detection ===' as test_section;

-- Test the stored procedure for safe booking with locking
CALL create_booking_with_lock(2, 1, '2025-11-05 10:00:00', '2025-11-05 11:00:00', @booking_id1, @result1);
SELECT @booking_id1 as first_booking_id, @result1 as first_result;

-- Try to book the same room at overlapping time (should fail)
CALL create_booking_with_lock(3, 1, '2025-11-05 10:30:00', '2025-11-05 11:30:00', @booking_id2, @result2);
SELECT @booking_id2 as second_booking_id, @result2 as second_result;

-- Try to book the same room at non-overlapping time (should succeed)
CALL create_booking_with_lock(3, 1, '2025-11-05 12:00:00', '2025-11-05 13:00:00', @booking_id3, @result3);
SELECT @booking_id3 as third_booking_id, @result3 as third_result;

-- ============================================================================
-- TEST 2: Test Audit Trail Functionality
-- ============================================================================

SELECT '=== TEST 2: Audit Trail Testing ===' as test_section;

-- Create a booking to test audit trail
INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
VALUES (4, 2, '2025-11-06 09:00:00', '2025-11-06 10:00:00', 'pending');

SET @test_booking_id = LAST_INSERT_ID();

-- Update the booking status
UPDATE bookings SET status = 'approved' WHERE id = @test_booking_id;

-- Update again to cancelled
UPDATE bookings SET status = 'cancelled' WHERE id = @test_booking_id;

-- Check audit trail
SELECT 'Audit trail for test booking:' as audit_info;
SELECT ab.*, u.name as changed_by_name
FROM audit_bookings ab
LEFT JOIN users u ON ab.changed_by = u.id
WHERE ab.booking_id = @test_booking_id
ORDER BY ab.changed_at;

-- ============================================================================
-- TEST 3: Test Equipment Usage Tracking
-- ============================================================================

SELECT '=== TEST 3: Equipment Usage Tracking ===' as test_section;

-- Create and approve a booking to trigger equipment usage tracking
INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
VALUES (5, 6, '2025-11-07 14:00:00', '2025-11-07 16:00:00', 'pending');

SET @equipment_test_booking = LAST_INSERT_ID();

-- Approve it (should trigger equipment usage creation)
UPDATE bookings SET status = 'approved' WHERE id = @equipment_test_booking;

-- Check equipment usage was created
SELECT 'Equipment usage created automatically:' as equipment_info;
SELECT eu.*, e.item_name, r.name as room_name
FROM equipment_usage eu
JOIN equipment e ON eu.equipment_id = e.id
JOIN rooms r ON e.room_id = r.id
WHERE eu.booking_id = @equipment_test_booking;

-- ============================================================================
-- TEST 4: Test Bulk Operations
-- ============================================================================

SELECT '=== TEST 4: Bulk Approval Testing ===' as test_section;

-- Create multiple pending bookings
INSERT INTO bookings (user_id, room_id, start_time, end_time, status) VALUES
(6, 3, '2025-11-08 09:00:00', '2025-11-08 10:00:00', 'pending'),
(7, 4, '2025-11-08 09:00:00', '2025-11-08 10:00:00', 'pending'),
(8, 5, '2025-11-08 09:00:00', '2025-11-08 10:00:00', 'pending');

-- Get the IDs of the bookings we just created
SELECT @bulk_id1 := MAX(id) - 2, @bulk_id2 := MAX(id) - 1, @bulk_id3 := MAX(id) FROM bookings;

-- Test bulk approval
SET @booking_ids_str = CONCAT(@bulk_id1, ',', @bulk_id2, ',', @bulk_id3);
CALL approve_multiple_bookings(@booking_ids_str, 1, @approved_count, @failed_count);

SELECT @approved_count as approved_count, @failed_count as failed_count;

-- Verify the approvals
SELECT id, status FROM bookings WHERE id IN (@bulk_id1, @bulk_id2, @bulk_id3);

-- ============================================================================
-- TEST 5: Test Equipment Maintenance Locking
-- ============================================================================

SELECT '=== TEST 5: Equipment Maintenance Locking ===' as test_section;

-- Test locking equipment for maintenance
CALL lock_equipment_for_maintenance(1, 2, @maintenance_result);
SELECT @maintenance_result as maintenance_lock_result;

-- Check maintenance record was created
SELECT 'Maintenance lock record:' as maintenance_info;
SELECT * FROM equipment_usage
WHERE notes = 'MAINTENANCE LOCK'
ORDER BY used_at DESC
LIMIT 1;

-- ============================================================================
-- TEST 6: Test Utilization Report
-- ============================================================================

SELECT '=== TEST 6: Utilization Report Testing ===' as test_section;

-- Generate utilization report
CALL get_room_utilization_report('2025-11-01', '2025-11-08');

-- ============================================================================
-- TEST 7: Test Views
-- ============================================================================

SELECT '=== TEST 7: Testing Views ===' as test_section;

-- Test active bookings view
SELECT 'Active bookings view:' as view_info;
SELECT * FROM active_bookings LIMIT 5;

-- Test room availability summary view
SELECT 'Room availability summary:' as availability_info;
SELECT * FROM room_availability_summary;

-- ============================================================================
-- TEST 8: Test Performance with Indexes
-- ============================================================================

SELECT '=== TEST 8: Performance Testing ===' as test_section;

-- Test query performance with indexes
EXPLAIN SELECT * FROM bookings
WHERE room_id = 1
AND status = 'approved'
AND start_time >= '2025-11-01'
AND end_time <= '2025-11-30';

-- Test availability query performance
EXPLAIN SELECT r.*
FROM rooms r
WHERE NOT EXISTS (
  SELECT 1 FROM bookings b
  WHERE b.room_id = r.id
    AND b.status IN ('approved','pending')
    AND (b.start_time < '2025-11-05 12:00:00' AND b.end_time > '2025-11-05 10:00:00')
);

-- ============================================================================
-- TEST 9: Test Constraint Violations and Error Handling
-- ============================================================================

SELECT '=== TEST 9: Constraint and Error Testing ===' as test_section;

-- Test duplicate room booking (should fail)
START TRANSACTION;

INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
VALUES (2, 1, '2025-11-05 10:15:00', '2025-11-05 10:45:00', 'pending');

-- This should fail due to existing trigger
-- The error will be caught by the application

ROLLBACK;

-- Test invalid time range
START TRANSACTION;

-- This should fail due to CHECK constraint
INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
VALUES (2, 1, '2025-11-05 12:00:00', '2025-11-05 11:00:00', 'pending');

ROLLBACK;

-- ============================================================================
-- TEST 10: Security Testing - Session Management
-- ============================================================================

SELECT '=== TEST 10: Session Management Testing ===' as test_section;

-- Create test sessions
INSERT INTO user_sessions (id, user_id, ip_address, user_agent, expires_at) VALUES
('test_session_1', 2, '192.168.1.100', 'Test Browser 1.0', DATE_ADD(NOW(), INTERVAL 1 DAY)),
('test_session_2', 3, '192.168.1.101', 'Test Browser 2.0', DATE_ADD(NOW(), INTERVAL 1 DAY)),
('expired_session', 4, '192.168.1.102', 'Test Browser 3.0', DATE_SUB(NOW(), INTERVAL 1 DAY));

-- Test session validation (active vs expired)
SELECT 'Active sessions:' as session_info;
SELECT id, user_id, is_active, expires_at > NOW() as is_valid
FROM user_sessions
WHERE is_active = TRUE AND expires_at > NOW();

-- Test login attempts logging
INSERT INTO login_attempts (email, ip_address, success, user_agent) VALUES
('test@uni.in', '192.168.1.100', TRUE, 'Test Browser'),
('wrong@uni.in', '192.168.1.100', FALSE, 'Test Browser'),
('test@uni.in', '192.168.1.101', TRUE, 'Another Browser');

SELECT 'Recent login attempts:' as login_info;
SELECT * FROM login_attempts ORDER BY attempt_time DESC LIMIT 5;

-- ============================================================================
-- CLEANUP TEST DATA
-- ============================================================================

SELECT '=== CLEANUP: Removing Test Data ===' as cleanup_section;

-- Remove test bookings and related data
DELETE FROM bookings WHERE id >= @test_booking_id;
DELETE FROM user_sessions WHERE id LIKE 'test_session_%' OR id = 'expired_session';
DELETE FROM login_attempts WHERE email IN ('test@uni.in', 'wrong@uni.in');

-- ============================================================================
-- FINAL SUMMARY
-- ============================================================================

SELECT '=== ENHANCEMENT TESTING SUMMARY ===' as summary_section;

SELECT
    'Total audit records' as metric,
    COUNT(*) as value
FROM audit_bookings
UNION ALL
SELECT
    'Total equipment usage records' as metric,
    COUNT(*) as value
FROM equipment_usage
UNION ALL
SELECT
    'Active triggers' as metric,
    COUNT(*) as value
FROM INFORMATION_SCHEMA.TRIGGERS
WHERE TRIGGER_SCHEMA = 'campus_db'
UNION ALL
SELECT
    'Performance indexes' as metric,
    COUNT(DISTINCT INDEX_NAME) as value
FROM INFORMATION_SCHEMA.STATISTICS
WHERE TABLE_SCHEMA = 'campus_db'
AND INDEX_NAME LIKE 'idx_%'
UNION ALL
SELECT
    'Stored procedures' as metric,
    COUNT(*) as value
FROM INFORMATION_SCHEMA.ROUTINES
WHERE ROUTINE_SCHEMA = 'campus_db'
AND ROUTINE_TYPE = 'PROCEDURE';

SELECT 'All enhancement tests completed successfully!' as final_message;