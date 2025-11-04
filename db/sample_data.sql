USE campus_db;

-- Admin (1)
INSERT INTO users (name,email,role,password) VALUES
('Admin Kavita','admin@campus.in','admin','admin123');

-- 10 Faculty 
INSERT INTO users (name,email,role,password) VALUES
('Dr. Rohan Sharma','rohan.sharma@uni.in','faculty','pass'),
('Prof. Nisha Verma','nisha.verma@uni.in','faculty','pass'),
('Dr. Amit Kulkarni','amit.kulkarni@uni.in','faculty','pass'),
('Prof. Sneha Iyer','sneha.iyer@uni.in','faculty','pass'),
('Dr. Arjun Mehta','arjun.mehta@uni.in','faculty','pass'),
('Prof. Priya Nair','priya.nair@uni.in','faculty','pass'),
('Dr. Kunal Gupta','kunal.gupta@uni.in','faculty','pass'),
('Prof. Ananya Rao','ananya.rao@uni.in','faculty','pass'),
('Dr. Devansh Patel','devansh.patel@uni.in','faculty','pass'),
('Prof. Meera Joshi','meera.joshi@uni.in','faculty','pass');

-- 30 Students
INSERT INTO users (name,email,role,password) VALUES
('Aditi Singh','aditi.singh@uni.in','student','pass'),
('Rahul Jain','rahul.jain@uni.in','student','pass'),
('Ishita Roy','ishita.roy@uni.in','student','pass'),
('Vikram Das','vikram.das@uni.in','student','pass'),
('Neha Kapoor','neha.kapoor@uni.in','student','pass'),
('Siddharth Rao','siddharth.rao@uni.in','student','pass'),
('Pooja Pillai','pooja.pillai@uni.in','student','pass'),
('Manish Yadav','manish.yadav@uni.in','student','pass'),
('Tanya Malhotra','tanya.malhotra@uni.in','student','pass'),
('Ritika Bansal','ritika.bansal@uni.in','student','pass'),
('Akash Reddy','akash.reddy@uni.in','student','pass'),
('Simran Kaur','simran.kaur@uni.in','student','pass'),
('Karan Arora','karan.arora@uni.in','student','pass'),
('Snehal Patil','snehal.patil@uni.in','student','pass'),
('Harshit Goel','harshit.goel@uni.in','student','pass'),
('Shruti Menon','shruti.menon@uni.in','student','pass'),
('Ankit Chawla','ankit.chawla@uni.in','student','pass'),
('Divya Bhatt','divya.bhatt@uni.in','student','pass'),
('Rohit Sinha','rohit.sinha@uni.in','student','pass'),
('Anushka Jain','anushka.jain@uni.in','student','pass'),
('Varun Khanna','varun.khanna@uni.in','student','pass'),
('Nikhil Kumar','nikhil.kumar@uni.in','student','pass'),
('Prachi Desai','prachi.desai@uni.in','student','pass'),
('Arvind Iyer','arvind.iyer@uni.in','student','pass'),
('Sanya Kapoor','sanya.kapoor@uni.in','student','pass'),
('Aman Tiwari','aman.tiwari@uni.in','student','pass'),
('Rhea D''Souza','rhea.dsouza@uni.in','student','pass'),
('Zoya Khan','zoya.khan@uni.in','student','pass'),
('Aditya Mishra','aditya.mishra@uni.in','student','pass'),
('Mihir Shah','mihir.shah@uni.in','student','pass');

-- Rooms: 5 Classrooms + 5 Labs
INSERT INTO rooms (name, type, capacity) VALUES
('CR-101','Classroom',40),
('CR-102','Classroom',50),
('CR-201','Classroom',60),
('CR-202','Classroom',45),
('CR-301','Classroom',35),
('LAB-A','Lab',30),
('LAB-B','Lab',28),
('LAB-C','Lab',32),
('LAB-D','Lab',24),
('LAB-E','Lab',26);

-- Equipment in labs
INSERT INTO equipment (room_id, item_name, quantity) VALUES
(6,'Projector',1),(6,'Computers',30),(6,'Oscilloscope',5),
(7,'Projector',1),(7,'Computers',28),
(8,'3D Printer',2),(8,'Computers',32),
(9,'Microscope',8),
(10,'Soldering Station',6);

-- Courses mapped to the first 5 faculty
INSERT INTO courses (course_name, faculty_id) VALUES
('DBMS', 1+1),      -- user id 2
('Operating Systems', 2+1),  -- 3
('Computer Networks', 3+1),  -- 4
('Machine Learning', 4+1),   -- 5
('Data Structures', 5+1);    -- 6

-- A couple of sample bookings (approved and pending)
INSERT INTO bookings (user_id, room_id, start_time, end_time, status) VALUES
(2, 1, '2025-11-01 09:00', '2025-11-01 10:00', 'approved'),
(3, 6, '2025-11-01 09:30', '2025-11-01 11:00', 'pending');


