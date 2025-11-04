from flask import Flask, request, jsonify, render_template, session, redirect
import mysql.connector
from datetime import datetime, timedelta
from functools import wraps
import hashlib
import secrets
import logging

app = Flask(__name__, template_folder='templates')
app.secret_key = "dev_secret_change_me"  # TODO: Use environment variable in production
PORT = 5001

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ---- DB CONFIG ----
DB_CFG = {
    "host": "127.0.0.1",
    "user": "campus_user",
    "password": "campus_pwd",
    "database": "campus_db",
    "autocommit": False  # Explicit transaction control
}

def get_db():
    return mysql.connector.connect(**DB_CFG)

# ---- Enhanced Security Helpers ----
def hash_password(password):
    """Hash password with salt"""
    salt = secrets.token_hex(16)
    return hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex() + ':' + salt

def verify_password(password, hashed):
    """Verify password against hash"""
    try:
        hash_part, salt = hashed.split(':')
        return hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex() == hash_part
    except:
        return False

def log_login_attempt(email, success, ip_address, user_agent):
    """Log login attempts for security monitoring"""
    try:
        cn = get_db()
        cur = cn.cursor()
        cur.execute(
            "INSERT INTO login_attempts (email, ip_address, success, user_agent) VALUES (%s, %s, %s, %s)",
            (email, ip_address, success, user_agent)
        )
        cn.commit()
        cur.close()
        cn.close()
    except Exception as e:
        logger.error(f"Failed to log login attempt: {e}")

def create_session(user_id, ip_address, user_agent):
    """Create secure session with database tracking"""
    session_id = secrets.token_urlsafe(32)
    expires_at = datetime.now() + timedelta(hours=24)

    try:
        cn = get_db()
        cur = cn.cursor()
        cur.execute(
            "INSERT INTO user_sessions (id, user_id, ip_address, user_agent, expires_at) VALUES (%s, %s, %s, %s, %s)",
            (session_id, user_id, ip_address, user_agent, expires_at)
        )
        cn.commit()
        cur.close()
        cn.close()
        return session_id
    except Exception as e:
        logger.error(f"Failed to create session: {e}")
        return None

def validate_session(session_id):
    """Validate session and update last accessed time"""
    try:
        cn = get_db()
        cur = cn.cursor(dictionary=True)
        cur.execute(
            "SELECT user_id FROM user_sessions WHERE id = %s AND is_active = TRUE AND expires_at > NOW()",
            (session_id,)
        )
        session_data = cur.fetchone()

        if session_data:
            # Update last accessed time
            cur.execute("UPDATE user_sessions SET last_accessed = NOW() WHERE id = %s", (session_id,))
            cn.commit()

        cur.close()
        cn.close()
        return session_data['user_id'] if session_data else None
    except Exception as e:
        logger.error(f"Session validation error: {e}")
        return None

# ---- Decorators ----
def require_login(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if "user_id" not in session:
            return jsonify({"error": "auth_required"}), 401
        return f(*args, **kwargs)
    return wrapper

def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if session.get("role") != "admin":
            return jsonify({"error": "admin_only"}), 403
        return f(*args, **kwargs)
    return wrapper

def parse_dt(s):
    """Accept "YYYY-MM-DD HH:MM" or ISO "YYYY-MM-DDTHH:MM" """
    s = s.replace("T", " ")
    return datetime.strptime(s, "%Y-%m-%d %H:%M")

# ---- Pages ----
@app.route("/")
def home():
    if "user_id" in session:
        return redirect("/dashboard")
    return redirect("/login_page")

@app.route("/login_page")
def login_page():
    return render_template("login.html")

@app.route("/dashboard")
@require_login
def dashboard_page():
    return render_template("dashboard.html", user_name=session.get("name"), user_id=session.get("user_id"))

@app.route("/available")
@require_login
def available_page():
    return render_template("available.html")

# ---- Enhanced Auth with Security ----
@app.post("/login")
def login():
    data = request.get_json(silent=True) or request.form
    email = (data.get("email") or "").strip()
    password = (data.get("password") or "").strip()
    ip_address = request.remote_addr
    user_agent = request.headers.get('User-Agent', '')

    if not email or not password:
        log_login_attempt(email, False, ip_address, user_agent)
        return jsonify({"error": "missing_credentials"}), 400

    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("SELECT * FROM users WHERE email=%s", (email,))
    user = cur.fetchone()
    cur.close()
    cn.close()

    # For backward compatibility, check plain text passwords first
    # In production, you'd migrate all passwords to hashed format
    valid_password = False
    if user:
        if ':' in user.get('password', ''):  # Hashed password
            valid_password = verify_password(password, user['password'])
        else:  # Plain text password (legacy)
            valid_password = password == user['password']

    if not user or not valid_password:
        log_login_attempt(email, False, ip_address, user_agent)
        return jsonify({"error": "invalid_credentials"}), 401

    # Successful login
    log_login_attempt(email, True, ip_address, user_agent)
    session_id = create_session(user["id"], ip_address, user_agent)

    session["user_id"] = user["id"]
    session["name"] = user["name"]
    session["role"] = user["role"]
    session["session_id"] = session_id

    return jsonify({
        "status": "success",
        "user": {"id": user["id"], "name": user["name"], "role": user["role"]}
    })

@app.post("/logout")
def logout():
    session_id = session.get("session_id")
    if session_id:
        try:
            cn = get_db()
            cur = cn.cursor()
            cur.execute("UPDATE user_sessions SET is_active = FALSE WHERE id = %s", (session_id,))
            cn.commit()
            cur.close()
            cn.close()
        except Exception as e:
            logger.error(f"Failed to invalidate session: {e}")

    session.clear()
    return jsonify({"status": "success"})

# ---- Enhanced API with Locking ----

@app.get("/rooms")
@require_login
def rooms():
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("SELECT * FROM rooms ORDER BY type, name")
    rows = cur.fetchall()
    cur.close()
    cn.close()
    return jsonify(rows)

@app.get("/available_rooms")
@require_login
def available_rooms():
    start = request.args.get("start")
    end = request.args.get("end")
    if not start or not end:
        return jsonify({"error": "start_and_end_required"}), 400

    try:
        start_dt = parse_dt(start)
        end_dt = parse_dt(end)
        if end_dt <= start_dt:
            return jsonify({"error": "end_must_be_after_start"}), 400
    except Exception:
        return jsonify({"error": "bad_datetime_format"}), 400

    cn = get_db()
    cur = cn.cursor(dictionary=True)
    # Use the existing query with shared locks for consistency
    query = """
    SELECT r.*,
           GROUP_CONCAT(e.item_name SEPARATOR ', ') as equipment
    FROM rooms r
    LEFT JOIN equipment e ON r.id = e.room_id
    WHERE NOT EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.room_id = r.id
        AND b.status IN ('approved','pending')
        AND (b.start_time < %s AND b.end_time > %s)
    )
    GROUP BY r.id, r.name, r.type, r.capacity
    ORDER BY r.type, r.name
    LOCK IN SHARE MODE
    """
    cur.execute(query, (end_dt, start_dt))
    rows = cur.fetchall()
    cur.close()
    cn.close()
    return jsonify(rows)

@app.post("/book")
@require_login
def book():
    """Enhanced booking with stored procedure and proper locking"""
    data = request.get_json(silent=True) or {}
    user_id = data.get("user_id") or session.get("user_id")
    room_id = data.get("room_id")
    start_time = data.get("start_time")
    end_time = data.get("end_time")

    if not (user_id and room_id and start_time and end_time):
        return jsonify({"error": "missing_fields"}), 400

    try:
        start_dt = parse_dt(start_time)
        end_dt = parse_dt(end_time)
        if end_dt <= start_dt:
            return jsonify({"error": "end_must_be_after_start"}), 400
    except Exception:
        return jsonify({"error": "bad_datetime_format"}), 400

    try:
        cn = get_db()
        cur = cn.cursor()

        # Use the stored procedure for safe booking with locking
        cur.callproc('create_booking_with_lock', [user_id, room_id, start_dt, end_dt, 0, ''])

        # Get the OUT parameters
        cur.execute("SELECT @_create_booking_with_lock_4 AS booking_id, @_create_booking_with_lock_5 AS result")
        result = cur.fetchone()

        cur.close()
        cn.close()

        booking_id, result_msg = result

        if result_msg.startswith('SUCCESS'):
            return jsonify({
                "status": "success",
                "message": "Booking requested with enhanced conflict checking",
                "booking_id": booking_id
            })
        else:
            return jsonify({"error": "booking_failed", "message": result_msg}), 400

    except mysql.connector.Error as e:
        logger.error(f"Booking error: {e}")
        return jsonify({"error": "db_error", "message": str(e)}), 400

@app.post("/approve/<int:booking_id>")
@require_login
@require_admin
def approve(booking_id):
    """Enhanced approval with locking and audit trail"""
    try:
        cn = get_db()
        cn.start_transaction()

        cur = cn.cursor(dictionary=True)

        # Lock the booking record
        cur.execute("SELECT * FROM bookings WHERE id = %s FOR UPDATE", (booking_id,))
        booking = cur.fetchone()

        if not booking:
            cn.rollback()
            cur.close()
            cn.close()
            return jsonify({"error": "not_found"}), 404

        if booking['status'] != 'pending':
            cn.rollback()
            cur.close()
            cn.close()
            return jsonify({"error": "booking_not_pending"}), 400

        # Check for conflicts one more time with locking
        cur.execute("""
            SELECT COUNT(*) as conflicts FROM bookings
            WHERE room_id = %s
            AND id != %s
            AND status = 'approved'
            AND start_time < %s
            AND end_time > %s
            FOR UPDATE
        """, (booking['room_id'], booking_id, booking['end_time'], booking['start_time']))

        conflict_count = cur.fetchone()['conflicts']

        if conflict_count > 0:
            cn.rollback()
            cur.close()
            cn.close()
            return jsonify({"error": "conflict_detected"}), 400

        # Approve the booking
        cur.execute("UPDATE bookings SET status='approved' WHERE id=%s", (booking_id,))

        # Log the approval in audit trail
        cur.execute("""
            INSERT INTO audit_bookings (booking_id, action_type, new_data, changed_by, session_info)
            VALUES (%s, 'UPDATE', JSON_OBJECT('status', 'approved'), %s, %s)
        """, (booking_id, session.get('user_id'), f"Admin approval by {session.get('name')}"))

        cn.commit()
        cur.close()
        cn.close()

        return jsonify({"status": "success", "message": "Booking approved with enhanced tracking"})

    except mysql.connector.Error as e:
        logger.error(f"Approval error: {e}")
        if cn:
            cn.rollback()
        return jsonify({"error": "db_error", "message": str(e)}), 400

@app.post("/cancel/<int:booking_id>")
@require_login
def cancel(booking_id):
    """Enhanced cancellation with proper locking"""
    try:
        cn = get_db()
        cn.start_transaction()

        cur = cn.cursor(dictionary=True)

        # Lock and get the booking
        cur.execute("SELECT user_id, status FROM bookings WHERE id=%s FOR UPDATE", (booking_id,))
        row = cur.fetchone()

        if not row:
            cn.rollback()
            cur.close()
            cn.close()
            return jsonify({"error": "not_found"}), 404

        # Permission check
        if session.get("role") != "admin" and session.get("user_id") != row["user_id"]:
            cn.rollback()
            cur.close()
            cn.close()
            return jsonify({"error": "forbidden"}), 403

        # Update status
        cur.execute("UPDATE bookings SET status='cancelled' WHERE id=%s", (booking_id,))

        cn.commit()
        cur.close()
        cn.close()

        return jsonify({"status": "success", "message": "Booking cancelled with enhanced tracking"})

    except mysql.connector.Error as e:
        logger.error(f"Cancellation error: {e}")
        if cn:
            cn.rollback()
        return jsonify({"error": "db_error", "message": str(e)}), 400

# ---- New Enhanced Endpoints ----

@app.get("/equipment_usage/<int:room_id>")
@require_login
def equipment_usage(room_id):
    """Get equipment usage history for a room"""
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("""
        SELECT eu.*, e.item_name, b.start_time, b.end_time, u.name as user_name
        FROM equipment_usage eu
        JOIN equipment e ON eu.equipment_id = e.id
        LEFT JOIN bookings b ON eu.booking_id = b.id
        LEFT JOIN users u ON b.user_id = u.id
        WHERE e.room_id = %s
        ORDER BY eu.used_at DESC
        LIMIT 50
    """, (room_id,))
    rows = cur.fetchall()
    cur.close()
    cn.close()
    return jsonify(rows)

@app.get("/audit_trail/<int:booking_id>")
@require_login
@require_admin
def audit_trail(booking_id):
    """Get audit trail for a specific booking"""
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("""
        SELECT ab.*, u.name as changed_by_name
        FROM audit_bookings ab
        LEFT JOIN users u ON ab.changed_by = u.id
        WHERE ab.booking_id = %s
        ORDER BY ab.changed_at DESC
    """, (booking_id,))
    rows = cur.fetchall()
    cur.close()
    cn.close()
    return jsonify(rows)

@app.get("/utilization_report")
@require_login
@require_admin
def utilization_report():
    """Get room utilization report using stored procedure"""
    start_date = request.args.get("start_date", (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d"))
    end_date = request.args.get("end_date", datetime.now().strftime("%Y-%m-%d"))

    try:
        cn = get_db()
        cur = cn.cursor(dictionary=True)
        cur.callproc('get_room_utilization_report', [start_date, end_date])

        # Get results from stored procedure
        results = []
        for result in cur.stored_results():
            results.extend(result.fetchall())

        cur.close()
        cn.close()

        return jsonify(results)
    except mysql.connector.Error as e:
        logger.error(f"Report generation error: {e}")
        return jsonify({"error": "report_error", "message": str(e)}), 400

@app.post("/bulk_approve")
@require_login
@require_admin
def bulk_approve():
    """Bulk approve bookings using stored procedure"""
    data = request.get_json(silent=True) or {}
    booking_ids = data.get("booking_ids", [])

    if not booking_ids:
        return jsonify({"error": "no_booking_ids"}), 400

    try:
        cn = get_db()
        cur = cn.cursor()

        # Convert list to comma-separated string
        booking_ids_str = ",".join(map(str, booking_ids))

        cur.callproc('approve_multiple_bookings', [booking_ids_str, session.get('user_id'), 0, 0])

        # Get the OUT parameters
        cur.execute("SELECT @_approve_multiple_bookings_2 AS approved_count, @_approve_multiple_bookings_3 AS failed_count")
        result = cur.fetchone()

        cur.close()
        cn.close()

        approved_count, failed_count = result

        return jsonify({
            "status": "success",
            "approved_count": approved_count,
            "failed_count": failed_count,
            "message": f"Approved {approved_count} bookings, {failed_count} failed"
        })

    except mysql.connector.Error as e:
        logger.error(f"Bulk approval error: {e}")
        return jsonify({"error": "db_error", "message": str(e)}), 400

@app.get("/schedule/<int:user_id>")
@require_login
def schedule(user_id):
    """Enhanced schedule view with equipment info"""
    if session.get("role") != "admin" and session.get("user_id") != user_id:
        return jsonify({"error": "forbidden"}), 403

    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("""
        SELECT b.id, r.name AS room, r.type, b.start_time, b.end_time, b.status,
               GROUP_CONCAT(e.item_name SEPARATOR ', ') as equipment
        FROM bookings b
        JOIN rooms r ON r.id = b.room_id
        LEFT JOIN equipment e ON r.id = e.room_id
        WHERE b.user_id = %s
        GROUP BY b.id, r.name, r.type, b.start_time, b.end_time, b.status
        ORDER BY b.start_time DESC
    """, (user_id,))
    rows = cur.fetchall()
    cur.close()
    cn.close()
    return jsonify(rows)

# Existing endpoints remain the same...
@app.post("/rooms")
@require_login
@require_admin
def create_room():
    data = request.get_json(silent=True) or {}
    name = data.get("name")
    rtype = data.get("type")
    capacity = data.get("capacity")
    if not (name and rtype and capacity):
        return jsonify({"error": "missing_fields"}), 400
    cn = get_db()
    cur = cn.cursor()
    try:
        cur.execute("INSERT INTO rooms (name,type,capacity) VALUES (%s,%s,%s)", (name, rtype, capacity))
        cn.commit()
        rid = cur.lastrowid
        cur.close()
        cn.close()
        return jsonify({"status": "success", "room_id": rid})
    except mysql.connector.Error as e:
        cur.close()
        cn.close()
        return jsonify({"error": "db_error", "message": str(e)}), 400

@app.route("/admin")
@require_login
@require_admin
def admin_page():
    return render_template("admin.html")

@app.get("/bookings_all")
@require_login
@require_admin
def bookings_all():
    """Enhanced admin view with audit information"""
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("""
      SELECT b.id, u.name AS faculty, r.name AS room, b.start_time, b.end_time, b.status,
             GROUP_CONCAT(e.item_name SEPARATOR ', ') as equipment,
             ab.changed_at as last_modified
      FROM bookings b
      JOIN users u ON u.id=b.user_id
      JOIN rooms r ON r.id=b.room_id
      LEFT JOIN equipment e ON r.id = e.room_id
      LEFT JOIN (
          SELECT booking_id, MAX(changed_at) as changed_at
          FROM audit_bookings
          GROUP BY booking_id
      ) ab ON b.id = ab.booking_id
      GROUP BY b.id, u.name, r.name, b.start_time, b.end_time, b.status, ab.changed_at
      ORDER BY b.start_time DESC
    """)
    rows = cur.fetchall()
    cur.close()
    cn.close()
    return jsonify(rows)

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT, debug=True)