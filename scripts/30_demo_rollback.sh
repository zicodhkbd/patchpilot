#!/usr/bin/env bash
# Sprint 3 demo and test: simulate a bad patch on web-3 and prove that PatchPilot
# detects it and replaces the server from its backup, while web-1 and web-2 are patched
# normally. Start a screen recording before running. Takes about 15-25 minutes.
PHASE=sprint3_rollback
# shellcheck source=poc_lib.sh
source "$(dirname "$0")/poc_lib.sh"

section "Sprint 3 demo: fault injection and automatic rollback"

dash=$(stack_output "$PROJECT-automation" DashboardUrl)
info "Dashboard: $dash  (open it in your browser now)"
evidence dashboard_before curl -s -m 10 "${dash}status"

web3=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJECT-web-3" "Name=tag:PatchGroup,Values=$PATCH_GROUP" \
  "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text | awk '{print $1}')
if [ -z "$web3" ]; then
  record R-01 "web-3 is running and in the patch group" FAIL "not found - run scripts/90_reset_demo.sh first"
  summary; exit 1
fi
record R-01 "web-3 is running and in the patch group" PASS "$web3"

info "Tagging web-3 with ChaosTest=true (simulated bad patch)"
aws ec2 create-tags --resources "$web3" --tags Key=ChaosTest,Value=true
check R-02 "web-3 tagged for the fault test" true "$(tag_of "$web3" ChaosTest)"

run="poc-rollback-$(date -u +%Y%m%d-%H%M%S)"
info "Starting patch cycle $run - open Step Functions > patchpilot-patch-cycle > Executions to watch the graph"
arn=$(start_execution "$run")
status=$(wait_execution "$arn" 3000)
check R-03 "Patch cycle execution finished" SUCCEEDED "$status"
evidence execution aws stepfunctions describe-execution --execution-arn "$arn" --query "{status:status,output:output}"

out=$(aws stepfunctions describe-execution --execution-arn "$arn" --query output --output text)
check R-04 "Servers patched and healthy (web-1, web-2)" 2 "$(json_get "$out" "d['summary']['healthy']")"
check R-05 "Servers rolled back (web-3)" 1 "$(json_get "$out" "d['summary']['rolled_back']")"

row=$(aws dynamodb get-item --table-name "$PROJECT-status" \
  --key "{\"InstanceId\":{\"S\":\"$web3\"},\"RunId\":{\"S\":\"$run\"}}" \
  --query "Item.[Status.S,ReplacementInstanceId.S,BackupAmiId.S]" --output text)
read -r w3status repl ami <<< "$row"
check R-06 "web-3 status in DynamoDB" ROLLED_BACK "$w3status"
info "Replacement server: $repl (launched from backup $ami)"

info "Waiting for the replacement server to start and serve the website"
aws ec2 wait instance-running --instance-ids "$repl" 2>/dev/null
rip=""; body=""
for _ in $(seq 1 18); do
  rip=$(ip_of "$repl"); body=$(health "$rip")
  [ "$body" = "OK" ] && break
  sleep 10
done
check R-07 "Replacement server web-3-restored serves /health" OK "$body"
check R-08 "Replacement server name" "$PROJECT-web-3-restored" "$(name_of "$repl")"

ostate=$(state_of "$web3")
if [ "$ostate" = "stopped" ] || [ "$ostate" = "stopping" ]; then record R-09 "Broken web-3 was stopped" PASS "$ostate"
else record R-09 "Broken web-3 was stopped" FAIL "$ostate"; fi
check R-10 "Broken web-3 tagged Quarantined" true "$(tag_of "$web3" Quarantined)"
check R-11 "Broken web-3 removed from the patch group" None "$(tag_of "$web3" PatchGroup)"

dstatus=$(curl -s -m 10 "${dash}status")
dw3=$(json_get "$dstatus" "[s['Status'] for s in d['servers'] if s['InstanceId']=='$web3'][0]")
check R-12 "Dashboard shows web-3 as ROLLED_BACK" ROLLED_BACK "$dw3"
evidence dashboard_after curl -s -m 10 "${dash}status"
evidence instances_after aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name,PublicIpAddress,Tags[?Key=='Quarantined']|[0].Value]" --output table

echo
echo "  Show the audience: http://$rip  (restored website), the dashboard, and the email"
echo "  'PatchPilot: attention needed'. To run the demo again: scripts/90_reset_demo.sh"
summary
