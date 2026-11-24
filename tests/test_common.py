"""Unit tests run by the CI pipeline before anything is deployed."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from common import (ami_name, classify_command_status, format_report,  # noqa: E402
                    latest_by_instance, summarize_results, tag_value)


def test_classify_command_status():
    assert classify_command_status("Pending") == "IN_PROGRESS"
    assert classify_command_status("InProgress") == "IN_PROGRESS"
    assert classify_command_status("Success") == "SUCCESS"
    for s in ("Failed", "TimedOut", "Cancelled", "Undeliverable"):
        assert classify_command_status(s) == "FAILED"


def test_tag_value():
    tags = [{"Key": "Name", "Value": "web-1"}, {"Key": "ChaosTest", "Value": "true"}]
    assert tag_value(tags, "Name") == "web-1"
    assert tag_value(tags, "Missing", "x") == "x"
    assert tag_value(None, "Name", "d") == "d"


def test_ami_name_is_safe_and_short():
    name = ami_name("i-0abc", "exec:2026/10/28 run*1" + "x" * 200)
    assert len(name) <= 128
    assert ":" not in name and "*" not in name


def test_latest_by_instance_keeps_newest():
    items = [
        {"InstanceId": "i-1", "Name": "web-1", "Status": "PATCHING", "UpdatedAt": "2026-11-01T08:00:00"},
        {"InstanceId": "i-1", "Name": "web-1", "Status": "PATCHED_HEALTHY", "UpdatedAt": "2026-11-01T08:05:00"},
        {"InstanceId": "i-2", "Name": "web-2", "Status": "ROLLED_BACK", "UpdatedAt": "2026-11-01T08:10:00"},
    ]
    latest = latest_by_instance(items)
    assert [i["Status"] for i in latest] == ["PATCHED_HEALTHY", "ROLLED_BACK"]


def test_summary_and_report():
    results = [
        {"instanceId": "i-1", "name": "web-1", "outcome": "PATCHED_HEALTHY", "backupAmiId": "ami-1"},
        {"instanceId": "i-3", "name": "web-3", "outcome": "ROLLED_BACK", "backupAmiId": "ami-3",
         "replacementInstanceId": "i-9"},
        {"instanceId": "i-4", "name": "web-4", "outcome": "FAILED", "detail": "boom"},
    ]
    s = summarize_results(results)
    assert s == {"total": 3, "healthy": 1, "rolled_back": 1, "failed": 1}
    text = format_report("run-1", results)
    assert "ATTENTION NEEDED" in text
    assert "i-9" in text and "ami-3" in text


def test_report_all_healthy():
    text = format_report("run-2", [{"instanceId": "i-1", "outcome": "PATCHED_HEALTHY"}])
    assert text.startswith("PatchPilot patch cycle report - SUCCESS")
