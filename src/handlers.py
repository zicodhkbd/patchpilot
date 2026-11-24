"""PatchPilot Lambda handlers.

One code package, several functions (each CloudFormation Lambda points at a
different handler in this file). The Step Functions state machine calls them
in this order for every server, one server at a time (rolling patching):

  discover -> [ backup -> patch (SSM) -> check_patch -> health_check -> rollback? ] -> report
"""
import json
import os
import time
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

from common import (PROJECT, ami_name, classify_command_status, format_report,
                    latest_by_instance, now_iso, summarize_results, tag_value)

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
sns = boto3.client("sns")
table = boto3.resource("dynamodb").Table(os.environ.get("TABLE_NAME", "patchpilot-status"))

PATCH_GROUP = os.environ.get("PATCH_GROUP", "patchpilot-web")
TOPIC_ARN = os.environ.get("TOPIC_ARN", "")
AMI_RETENTION_DAYS = int(os.environ.get("AMI_RETENTION_DAYS", "3"))


# ---------------------------------------------------------------- helpers
def put_status(state, status, **extra):
    """Write/overwrite the status row for this server in this run."""
    item = {
        "InstanceId": state["instanceId"],
        "RunId": state["runId"],
        "Name": state.get("name", state["instanceId"]),
        "Status": status,
        "UpdatedAt": now_iso(),
    }
    for key in ("backupAmiId", "replacementInstanceId", "patchStatus", "detail"):
        if state.get(key):
            item[key[0].upper() + key[1:]] = state[key]
    item.update({k: v for k, v in extra.items() if v})
    table.put_item(Item=item)


def describe_instance(instance_id):
    res = ec2.describe_instances(InstanceIds=[instance_id])
    return res["Reservations"][0]["Instances"][0]


def prune_old_backups():
    """Delete PatchPilot backup AMIs (and their snapshots) older than the retention period."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=AMI_RETENTION_DAYS)
    images = ec2.describe_images(Owners=["self"], Filters=[{"Name": "tag:Project", "Values": [PROJECT]}])["Images"]
    removed = 0
    for img in images:
        created = datetime.fromisoformat(img["CreationDate"].replace("Z", "+00:00"))
        if created < cutoff:
            ec2.deregister_image(ImageId=img["ImageId"])
            for bdm in img.get("BlockDeviceMappings", []):
                snap = bdm.get("Ebs", {}).get("SnapshotId")
                if snap:
                    ec2.delete_snapshot(SnapshotId=snap)
            removed += 1
    return removed


# ---------------------------------------------------------------- 1. discover
def discover(event, context):
    """Find running servers in the patch group. Input: {"runId": "..."}."""
    run_id = event.get("runId") or now_iso()
    res = ec2.describe_instances(Filters=[
        {"Name": "tag:PatchGroup", "Values": [PATCH_GROUP]},
        {"Name": "instance-state-name", "Values": ["running"]},
    ])
    instances = []
    for r in res["Reservations"]:
        for i in r["Instances"]:
            instances.append({
                "runId": run_id,
                "instanceId": i["InstanceId"],
                "name": tag_value(i.get("Tags"), "Name", i["InstanceId"]),
                "chaos": tag_value(i.get("Tags"), "ChaosTest", "false").lower(),
            })
    instances.sort(key=lambda x: x["name"])
    pruned = prune_old_backups()
    print(json.dumps({"runId": run_id, "found": len(instances), "prunedAmis": pruned}))
    return {"runId": run_id, "instances": instances, "prunedAmis": pruned}


# ---------------------------------------------------------------- 2. backup
def backup(event, context):
    """Create a pre-patch AMI. EBS snapshots are point-in-time at the moment of
    the call, so patching can start immediately (NoReboot keeps the site up)."""
    iid, run_id = event["instanceId"], event["runId"]
    image = ec2.create_image(
        InstanceId=iid,
        Name=ami_name(iid, run_id),
        Description=f"PatchPilot pre-patch backup of {event.get('name', iid)}",
        NoReboot=True,
        TagSpecifications=[
            {"ResourceType": "image", "Tags": [
                {"Key": "Project", "Value": PROJECT},
                {"Key": "SourceInstance", "Value": iid},
                {"Key": "RunId", "Value": run_id}]},
            {"ResourceType": "snapshot", "Tags": [{"Key": "Project", "Value": PROJECT}]},
        ],
    )
    event["backupAmiId"] = image["ImageId"]
    put_status(event, "BACKUP_CREATED")
    return event


# ---------------------------------------------------------------- 3. check patch
def check_patch(event, context):
    """Poll the SSM AWS-RunPatchBaseline command for this server."""
    try:
        inv = ssm.get_command_invocation(CommandId=event["patch"]["commandId"], InstanceId=event["instanceId"])
        raw = inv["Status"]
    except ssm.exceptions.InvocationDoesNotExist:
        raw = "Pending"  # the command was just sent and is not registered yet
    event["patchStatus"] = classify_command_status(raw)
    event["patchRawStatus"] = raw
    if event["patchStatus"] == "IN_PROGRESS":
        put_status(event, "PATCHING")
    else:
        put_status(event, "PATCH_" + event["patchStatus"])
    return event


# ---------------------------------------------------------------- 4. health check
def health_check(event, context):
    """HTTP GET http://<public-ip>/health with retries."""
    inst = describe_instance(event["instanceId"])
    ip = inst.get("PublicIpAddress")
    healthy, detail = False, "no public IP"
    if ip:
        for attempt in range(1, 7):
            try:
                with urllib.request.urlopen(f"http://{ip}/health", timeout=5) as resp:
                    body = resp.read().decode().strip()
                    if resp.status == 200 and body == "OK":
                        healthy, detail = True, f"HTTP 200 on attempt {attempt}"
                        break
                    detail = f"HTTP {resp.status} body={body[:40]}"
            except Exception as exc:  # connection refused / timeout while service is down
                detail = f"{type(exc).__name__}: {exc}"[:200]
            time.sleep(10)
    event["healthy"] = healthy
    event["detail"] = detail
    if healthy:
        event["outcome"] = "PATCHED_HEALTHY" if event.get("patchStatus") == "SUCCESS" else "PATCH_FAILED"
        put_status(event, event["outcome"])
    else:
        put_status(event, "UNHEALTHY")
    return event


# ---------------------------------------------------------------- 5. rollback
def rollback(event, context):
    """Launch a replacement server from the pre-patch AMI, then stop and
    quarantine the broken one so it is excluded from future patch cycles."""
    iid, ami = event["instanceId"], event["backupAmiId"]
    put_status(event, "ROLLING_BACK")
    ec2.get_waiter("image_available").wait(ImageIds=[ami], WaiterConfig={"Delay": 15, "MaxAttempts": 50})

    old = describe_instance(iid)
    tags = [t for t in old.get("Tags", []) if not t["Key"].startswith("aws:")]
    tags = [t for t in tags if t["Key"] not in ("Name", "ChaosTest")]
    tags += [
        {"Key": "Name", "Value": event.get("name", iid) + "-restored"},
        {"Key": "ChaosTest", "Value": "false"},
        {"Key": "RestoredFrom", "Value": iid},
    ]
    run_args = {
        "ImageId": ami,
        "InstanceType": old["InstanceType"],
        "MinCount": 1,
        "MaxCount": 1,
        "SubnetId": old["SubnetId"],
        "SecurityGroupIds": [g["GroupId"] for g in old["SecurityGroups"]],
        "MetadataOptions": {"HttpTokens": "required", "InstanceMetadataTags": "enabled"},
        "TagSpecifications": [{"ResourceType": "instance", "Tags": tags}],
    }
    if old.get("IamInstanceProfile"):
        run_args["IamInstanceProfile"] = {"Arn": old["IamInstanceProfile"]["Arn"]}
    new_id = ec2.run_instances(**run_args)["Instances"][0]["InstanceId"]

    ec2.stop_instances(InstanceIds=[iid])
    ec2.delete_tags(Resources=[iid], Tags=[{"Key": "PatchGroup"}])
    ec2.create_tags(Resources=[iid], Tags=[{"Key": "Quarantined", "Value": "true"},
                                           {"Key": "ReplacedBy", "Value": new_id}])

    event["replacementInstanceId"] = new_id
    event["outcome"] = "ROLLED_BACK"
    event["detail"] = f"Health check failed ({event.get('detail', '')}); restored from {ami}"[:300]
    put_status(event, "ROLLED_BACK")
    return event


# ---------------------------------------------------------------- 6. report
def report(event, context):
    """Email a summary of the run through SNS. Input: {"runId", "results": [...]}."""
    run_id, results = event["runId"], event.get("results", [])
    text = format_report(run_id, results)
    summary = summarize_results(results)
    subject = "PatchPilot: all servers patched" if summary["healthy"] == summary["total"] \
        else "PatchPilot: attention needed"
    if TOPIC_ARN:
        sns.publish(TopicArn=TOPIC_ARN, Subject=subject, Message=text)
    print(text)
    return {"runId": run_id, "summary": summary}


# ---------------------------------------------------------------- 7. dashboard API
_DASHBOARD = os.path.join(os.path.dirname(__file__), "dashboard.html")


def api(event, context):
    """API Gateway (HTTP API) handler: GET / -> dashboard page, GET /status -> JSON."""
    path = event.get("rawPath", "/")
    if path == "/status":
        items, kwargs = [], {}
        while True:
            page = table.scan(**kwargs)
            items += page.get("Items", [])
            if "LastEvaluatedKey" not in page:
                break
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
        recent = sorted(items, key=lambda i: i.get("UpdatedAt", ""), reverse=True)[:25]
        body = {"servers": latest_by_instance(items), "recent": recent, "generatedAt": now_iso()}
        return {"statusCode": 200, "headers": {"Content-Type": "application/json"},
                "body": json.dumps(body, default=str)}
    if path in ("/", "/index.html"):
        with open(_DASHBOARD, encoding="utf-8") as f:
            return {"statusCode": 200, "headers": {"Content-Type": "text/html"}, "body": f.read()}
    return {"statusCode": 404, "body": "Not found"}
