CREATE DATABASE IF NOT EXISTS campus_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE campus_db;

DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS equipment;
DROP TABLE IF EXISTS courses;
DROP TABLE IF EXISTS rooms;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE,
  role ENUM('admin','faculty','student') NOT NULL,
  password VARCHAR(255) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE rooms (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL UNIQUE,
  type ENUM('Classroom','Lab') NOT NULL,
  capacity INT NOT NULL
) ENGINE=InnoDB;

CREATE TABLE bookings (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  room_id INT NOT NULL,
  start_time DATETIME NOT NULL,
  end_time DATETIME NOT NULL,
  status ENUM('pending','approved','cancelled') NOT NULL DEFAULT 'pending',
  CONSTRAINT fk_booking_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT fk_booking_room FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE,
  CONSTRAINT chk_time CHECK (end_time > start_time)
) ENGINE=InnoDB;

CREATE TABLE equipment (
  id INT AUTO_INCREMENT PRIMARY KEY,
  room_id INT NOT NULL,
  item_name VARCHAR(100) NOT NULL,
  quantity INT NOT NULL DEFAULT 1,
  CONSTRAINT fk_equipment_room FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE courses (
  id INT AUTO_INCREMENT PRIMARY KEY,
  course_name VARCHAR(120) NOT NULL,
  faculty_id INT NOT NULL,
  CONSTRAINT fk_course_faculty FOREIGN KEY (faculty_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;


DELIMITER //
CREATE PROCEDURE check_conflict(IN p_room_id INT, IN p_start DATETIME, IN p_end DATETIME, IN p_ignore_booking_id INT)
BEGIN
  -- Block overlap with APPROVED or PENDING bookings (cancelled doesn't block)
  IF EXISTS (
    SELECT 1
    FROM bookings b
    WHERE b.room_id = p_room_id
      AND b.status IN ('approved','pending')
      AND (p_ignore_booking_id IS NULL OR b.id <> p_ignore_booking_id)
      AND (b.start_time < p_end AND b.end_time > p_start)
  ) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Room already booked for this time';
  END IF;
END//
DELIMITER ;

-- Before INSERT trigger
DELIMITER //
CREATE TRIGGER trg_bookings_bi
BEFORE INSERT ON bookings
FOR EACH ROW
BEGIN
  IF NEW.end_time <= NEW.start_time THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'end_time must be after start_time';
  END IF;
  CALL check_conflict(NEW.room_id, NEW.start_time, NEW.end_time, NULL);
END//
DELIMITER ;

-- Before UPDATE trigger (for status/time changes)
DELIMITER //
CREATE TRIGGER trg_bookings_bu
BEFORE UPDATE ON bookings
FOR EACH ROW
BEGIN
  IF NEW.end_time <= NEW.start_time THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'end_time must be after start_time';
  END IF;
  CALL check_conflict(NEW.room_id, NEW.start_time, NEW.end_time, OLD.id);
END//
DELIMITER ;
