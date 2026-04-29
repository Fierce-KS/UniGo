"""
UniGo — Module E: Frontend (E1_app.py)
Routes only. Zero business logic.

Depends on:
  - Views: vw_students, vw_leaderboard, vw_destinations,
           vw_ride_groups, vw_trust_audit, vw_available_rides  (Modules A/B/C)
  - Procedures: book_ride, cancel_booking, complete_ride       (Module C)
  - Functions: check_priority_eligibility, calculate_travel_risk (Module D)

See reference/E2_views_contract.sql for expected view definitions.
"""
from flask import Flask, render_template, jsonify, request
import oracledb

DB = {"user": "system", "password": "UniGo2026", "dsn": "localhost:1521/XEPDB1"}
app = Flask(__name__)

def q(sql, p=None):
    with oracledb.connect(**DB) as c:
        with c.cursor() as cur:
            cur.execute(sql, p or {})
            return [dict(zip([x[0].lower() for x in cur.description], r)) for r in cur.fetchall()]

def proc(name, p):
    with oracledb.connect(**DB) as c:
        with c.cursor() as cur:
            try:
                cur.callproc(name, p)
                c.commit()
                return {"success": True}
            except oracledb.Error as e:
                c.rollback()
                return {"success": False, "error": str(e)}

# Pages
@app.route("/")
def dash(): return render_template("index.html", active="dashboard")
@app.route("/find")
def find(): return render_template("find.html", active="find")

# API — all queries are just SELECT * FROM view
@app.route("/api/students")
def a1(): return jsonify(q("SELECT * FROM vw_students"))
@app.route("/api/leaderboard")
def a2(): return jsonify(q("SELECT * FROM vw_leaderboard ORDER BY trust_rank"))
@app.route("/api/destinations")
def a3(): return jsonify(q("SELECT * FROM vw_destinations"))
@app.route("/api/ride-groups")
def a4(): return jsonify(q("SELECT * FROM vw_ride_groups ORDER BY group_id"))
@app.route("/api/trust-audit")
def a5(): return jsonify(q("SELECT * FROM vw_trust_audit ORDER BY audit_id DESC"))

# API — find buddies (filters on the view)
@app.route("/api/find-buddies", methods=["POST"])
def a6():
    d = request.json
    rows = q("SELECT * FROM vw_available_rides WHERE destination_id=:a AND departure_date=TO_CHAR(TO_DATE(:b,'YYYY-MM-DD'),'YYYY-MM-DD') AND available_bag_space>=:c",
             {"a": int(d["destination_id"]), "b": d["travel_date"], "c": int(d["luggage_count"])})
    return jsonify({"matches": rows, "count": len(rows)})

# API — calls DB functions (Module D)
@app.route("/api/priority-check", methods=["POST"])
def a7():
    d = request.json
    return jsonify({"status": q("SELECT check_priority_eligibility(:a) AS s FROM DUAL", {"a": int(d["student_id"])})[0]["s"]})

@app.route("/api/travel-risk", methods=["POST"])
def a8():
    d = request.json
    return jsonify({"risk_level": q("SELECT calculate_travel_risk(:a,:b,:c) AS r FROM DUAL",
        {"a": float(d["connection_time"]), "b": int(d["destination_id"]), "c": float(d.get("buffer_factor",1.3))})[0]["r"]})

# API — calls DB procedures (Module C)
@app.route("/api/book", methods=["POST"])
def a9():
    d = request.json
    return jsonify(proc("book_ride", [int(d["group_id"]), int(d["student_id"]), 1 if d.get("priority_go") else 0]))

@app.route("/api/cancel-booking", methods=["POST"])
def a10():
    d = request.json
    return jsonify(proc("cancel_booking", [int(d["group_id"]), int(d["student_id"])]))

@app.route("/api/complete-ride", methods=["POST"])
def a11():
    d = request.json
    return jsonify(proc("complete_ride", [int(d["group_id"])]))

if __name__ == "__main__":
    print("\n  UniGo — http://localhost:5050\n")
    app.run(debug=True, port=5050)
