import uuid
from datetime import datetime

from flask import Blueprint, jsonify, request

from modules.auth import require_auth
from modules.scheduler_store import load_schedules, save_schedules

scheduler_bp = Blueprint("scheduler", __name__)

_ALL_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def _validate_time(time_val: str) -> bool:
    try:
        datetime.strptime(time_val, "%H:%M")
        return True
    except ValueError:
        return False


@scheduler_bp.route("/api/schedules", methods=["GET"])
@require_auth
def get_schedules():
    """List all schedules — config content excluded to keep the response small."""
    schedules = load_schedules()
    preview = [{k: v for k, v in s.items() if k != "config"} for s in schedules]
    return jsonify(preview)


@scheduler_bp.route("/api/schedules", methods=["POST"])
@require_auth
def add_schedule():
    """Create a schedule. Body: { name, time (HH:MM), days, config (TOML) }"""
    data = request.get_json(silent=True) or {}
    time_val = data.get("time", "")

    if not _validate_time(time_val):
        return jsonify({"ok": False, "error": "invalid_time_format"}), 400

    entry = {
        "id":         str(uuid.uuid4()),
        "name":       data.get("name", "Unnamed").strip() or "Unnamed",
        "time":       time_val,
        "days":       [d for d in data.get("days", _ALL_DAYS) if d in _ALL_DAYS],
        "config":     data.get("config", ""),
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }
    schedules = load_schedules()
    schedules.append(entry)
    save_schedules(schedules)
    return jsonify({"ok": True, "id": entry["id"]})


@scheduler_bp.route("/api/schedules/<schedule_id>", methods=["GET"])
@require_auth
def get_schedule(schedule_id: str):
    """Fetch a single schedule including its full config content."""
    for s in load_schedules():
        if s["id"] == schedule_id:
            return jsonify(s)
    return jsonify({"ok": False, "error": "not_found"}), 404


@scheduler_bp.route("/api/schedules/<schedule_id>", methods=["PUT"])
@require_auth
def update_schedule(schedule_id: str):
    data = request.get_json(silent=True) or {}
    schedules = load_schedules()

    for s in schedules:
        if s["id"] != schedule_id:
            continue
        if "name" in data:
            s["name"] = data["name"].strip() or "Unnamed"
        if "time" in data:
            if not _validate_time(data["time"]):
                return jsonify({"ok": False, "error": "invalid_time_format"}), 400
            s["time"] = data["time"]
        if "days" in data:
            s["days"] = [d for d in data["days"] if d in _ALL_DAYS]
        if "config" in data:
            s["config"] = data["config"]
        save_schedules(schedules)
        return jsonify({"ok": True})

    return jsonify({"ok": False, "error": "not_found"}), 404


@scheduler_bp.route("/api/schedules/<schedule_id>", methods=["DELETE"])
@require_auth
def delete_schedule(schedule_id: str):
    schedules = load_schedules()
    filtered = [s for s in schedules if s["id"] != schedule_id]
    if len(filtered) == len(schedules):
        return jsonify({"ok": False, "error": "not_found"}), 404
    save_schedules(filtered)
    return jsonify({"ok": True})
