"""Shared helpers for the PatchPilot Lambda functions.

Pure functions (no AWS calls) live here so they can be unit-tested in the
CI pipeline without an AWS account.
"""
import os
from datetime import datetime, timezone

PROJECT = os.environ.get("PROJECT_NAME", "patchpilot")

# SSM command statuses -> what the state machine should do next
_IN_PROGRESS = {"Pending", "InProgress", "Delayed"}
_SUCCESS = {"Success"}


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def classify_command_status(status):
    """Map an SSM command invocation status to IN_PROGRESS / SUCCESS / FAILED."""
    if status in _IN_PROGRESS:
        return "IN_PROGRESS"
    if status in _SUCCESS:
        return "SUCCESS"
    return "FAILED"


def tag_value(tags, key, default=""):
    for t in tags or []:
        if t.get("Key") == key:
            return t.get("Value", default)
    return default


def ami_name(instance_id, run_id):
    # AMI names allow letters, numbers, ( ) . - / _ and spaces; max 128 chars
    safe_run = "".join(c if c.isalnum() or c in "-_." else "-" for c in run_id)
    return f"{PROJECT}-{instance_id}-{safe_run}"[:128]


def latest_by_instance(items):
    """Given DynamoDB items (one per instance per run), keep the newest per instance."""
    latest = {}
    for item in items:
        iid = item.get("InstanceId")
        if not iid:
            continue
        if iid not in latest or item.get("UpdatedAt", "") > latest[iid].get("UpdatedAt", ""):
            latest[iid] = item
    return sorted(latest.values(), key=lambda i: i.get("Name", i["InstanceId"]))


def summarize_results(results):
    """Count outcomes from the Map state results."""
    summary = {"total": len(results), "healthy": 0, "rolled_back": 0, "failed": 0}
    for r in results:
        outcome = r.get("outcome")
        if outcome == "PATCHED_HEALTHY":
            summary["healthy"] += 1
        elif outcome == "ROLLED_BACK":
            summary["rolled_back"] += 1
        else:
            summary["failed"] += 1
    return summary


def format_report(run_id, results):
    """Build the plain-text email sent by SNS at the end of a patch cycle."""
    s = summarize_results(results)
    overall = "SUCCESS" if s["healthy"] == s["total"] else "ATTENTION NEEDED"
    lines = [
        f"PatchPilot patch cycle report - {overall}",
        f"Run ID: {run_id}",
        f"Servers: {s['total']} | Patched and healthy: {s['healthy']} | "
        f"Rolled back: {s['rolled_back']} | Failed: {s['failed']}",
        "",
    ]
    for r in results:
        lines.append(f"- {r.get('name', r.get('instanceId'))} ({r.get('instanceId')}): {r.get('outcome')}")
        if r.get("backupAmiId"):
            lines.append(f"    Pre-patch backup AMI: {r['backupAmiId']}")
        if r.get("replacementInstanceId"):
            lines.append(f"    Replacement instance launched from backup: {r['replacementInstanceId']}")
        if r.get("detail"):
            lines.append(f"    Detail: {r['detail']}")
    return "\n".join(lines)
