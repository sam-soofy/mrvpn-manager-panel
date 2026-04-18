import json
from pathlib import Path

# modules/scheduler_store.py lives at PROJECT_ROOT/modules/scheduler_store.py
# so .parent.parent resolves to PROJECT_ROOT — works in both dev and production.
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCHEDULES_FILE = _PROJECT_ROOT / "schedules.json"


def load_schedules() -> list:
    """Return the schedule list, or [] on any read/parse error."""
    if not SCHEDULES_FILE.exists():
        return []
    try:
        return json.loads(SCHEDULES_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []


def save_schedules(schedules: list) -> None:
    SCHEDULES_FILE.write_text(json.dumps(schedules, indent=2), encoding="utf-8")
