from flask import Flask, request, jsonify, render_template, session, redirect
import mysql.connector
from datetime import datetime
from functools import wraps

app = Flask(__name__, template_folder='templates')
app.secret_key = "dev_secret_change_me"
PORT = 5001

# ---- DB CONFIG ----
DB_CFG = {
    "host": "127.0.0.1",
    "user": "campus_user",          # change if you used a different user
    "password": "campus_pwd",       # change if you set a different password
    "database": "campus_db"
}

def get_db():
    return mysql.connector.connect(**DB_CFG)

# ---- Helpers ----
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
    # Accept "YYYY-MM-DD HH:MM" or ISO "YYYY-MM-DDTHH:MM"
    s = s.replace("T"," ")
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

# ---- Auth ----
@app.post("/login")
def login():
    data = request.get_json(silent=True) or request.form
    email = (data.get("email") or "").strip()
    password = (data.get("password") or "").strip()
    if not email or not password:
        return jsonify({"error":"missing_credentials"}), 400

    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("SELECT * FROM users WHERE email=%s AND password=%s", (email, password))
    user = cur.fetchone()
    cur.close(); cn.close()

    if not user:
        return jsonify({"error":"invalid_credentials"}), 401

    session["user_id"] = user["id"]
    session["name"] = user["name"]
    session["role"] = user["role"]
    return jsonify({"status":"success", "user":{"id":user["id"],"name":user["name"],"role":user["role"]}})

@app.post("/logout")
def logout():
    session.clear()
    return jsonify({"status":"success"})

# ---- API ----

@app.get("/rooms")
@require_login
def rooms():
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("SELECT * FROM rooms ORDER BY type, name")
    rows = cur.fetchall()
    cur.close(); cn.close()
    return jsonify(rows)

@app.get("/available_rooms")
@require_login
def available_rooms():
    start = request.args.get("start")
    end = request.args.get("end")
    if not start or not end:
        return jsonify({"error":"start_and_end_required"}), 400

    try:
        start_dt = parse_dt(start)
        end_dt = parse_dt(end)
        if end_dt <= start_dt:
            return jsonify({"error":"end_must_be_after_start"}), 400
    except Exception:
        return jsonify({"error":"bad_datetime_format"}), 400

    cn = get_db()
    cur = cn.cursor(dictionary=True)
    # Rooms that do NOT have overlapping approved or pending bookings
    query = """
    SELECT r.*
    FROM rooms r
    WHERE NOT EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.room_id = r.id
        AND b.status IN ('approved','pending')
        AND (b.start_time < %s AND b.end_time > %s)
    )
    ORDER BY r.type, r.name
    """
    cur.execute(query, (end_dt, start_dt))
    rows = cur.fetchall()
    cur.close(); cn.close()
    return jsonify(rows)

@app.post("/book")
@require_login
def book():
    data = request.get_json(silent=True) or {}
    user_id = data.get("user_id") or session.get("user_id")
    room_id = data.get("room_id")
    start_time = data.get("start_time")
    end_time = data.get("end_time")

    if not (user_id and room_id and start_time and end_time):
        return jsonify({"error":"missing_fields"}), 400
    try:
        start_dt = parse_dt(start_time)
        end_dt = parse_dt(end_time)
        if end_dt <= start_dt:
            return jsonify({"error":"end_must_be_after_start"}), 400
    except Exception:
        return jsonify({"error":"bad_datetime_format"}), 400

    try:
        cn = get_db()
        cur = cn.cursor()
        cur.execute(
            "INSERT INTO bookings (user_id, room_id, start_time, end_time, status) VALUES (%s,%s,%s,%s,'pending')",
            (user_id, room_id, start_dt, end_dt)
        )
        cn.commit()
        new_id = cur.lastrowid
        cur.close(); cn.close()
        return jsonify({"status":"success", "message":"Booking requested", "booking_id": new_id})
    except mysql.connector.Error as e:
        return jsonify({"error":"db_error", "message":str(e)}), 400

@app.post("/approve/<int:booking_id>")
@require_login
@require_admin
def approve(booking_id):
    # approving will re-run overlap via trigger (update)
    try:
        cn = get_db()
        cur = cn.cursor()
        cur.execute("UPDATE bookings SET status='approved' WHERE id=%s", (booking_id,))
        cn.commit()
        affected = cur.rowcount
        cur.close(); cn.close()
        if affected == 0:
            return jsonify({"error":"not_found"}), 404
        return jsonify({"status":"success","message":"Booking approved"})
    except mysql.connector.Error as e:
        return jsonify({"error":"db_error", "message":str(e)}), 400

@app.post("/cancel/<int:booking_id>")
@require_login
def cancel(booking_id):
    # Faculty can cancel their own pending/approved; Admin can cancel any
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("SELECT user_id FROM bookings WHERE id=%s", (booking_id,))
    row = cur.fetchone()
    if not row:
        cur.close(); cn.close()
        return jsonify({"error":"not_found"}), 404
    # permission check
    if session.get("role") != "admin" and session.get("user_id") != row["user_id"]:
        cur.close(); cn.close()
        return jsonify({"error":"forbidden"}), 403

    cur2 = cn.cursor()
    cur2.execute("UPDATE bookings SET status='cancelled' WHERE id=%s", (booking_id,))
    cn.commit()
    cur2.close(); cur.close(); cn.close()
    return jsonify({"status":"success","message":"Booking cancelled"})

@app.get("/schedule/<int:user_id>")
@require_login
def schedule(user_id):
    # Students can only view their own; Admin can view anyone; Faculty can view their own
    if session.get("role") != "admin" and session.get("user_id") != user_id:
        return jsonify({"error":"forbidden"}), 403
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("""
        SELECT b.id, r.name AS room, r.type, b.start_time, b.end_time, b.status
        FROM bookings b
        JOIN rooms r ON r.id = b.room_id
        WHERE b.user_id = %s
        ORDER BY b.start_time DESC
    """, (user_id,))
    rows = cur.fetchall()
    cur.close(); cn.close()
    return jsonify(rows)

# Minimal admin helper to add a room (CRUD demo)
@app.post("/rooms")
@require_login
@require_admin
def create_room():
    data = request.get_json(silent=True) or {}
    name = data.get("name")
    rtype = data.get("type")
    capacity = data.get("capacity")
    if not (name and rtype and capacity):
        return jsonify({"error":"missing_fields"}), 400
    cn = get_db(); cur = cn.cursor()
    try:
        cur.execute("INSERT INTO rooms (name,type,capacity) VALUES (%s,%s,%s)", (name, rtype, capacity))
        cn.commit()
        rid = cur.lastrowid
        cur.close(); cn.close()
        return jsonify({"status":"success","room_id":rid})
    except mysql.connector.Error as e:
        cur.close(); cn.close()
        return jsonify({"error":"db_error","message":str(e)}), 400


@app.route("/admin")
@require_login
@require_admin
def admin_page():
    return render_template("admin.html")

  
@app.get("/bookings_all")
@require_login
@require_admin
def bookings_all():
    cn = get_db()
    cur = cn.cursor(dictionary=True)
    cur.execute("""
      SELECT b.id, u.name AS faculty, r.name AS room, b.start_time, b.end_time, b.status
      FROM bookings b
      JOIN users u ON u.id=b.user_id
      JOIN rooms r ON r.id=b.room_id
      ORDER BY b.start_time DESC
    """)
    rows = cur.fetchall()
    cur.close(); cn.close()
    return jsonify(rows)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT, debug=True)
