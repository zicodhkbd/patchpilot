#!/usr/bin/env bash
# Shared helpers for the PatchPilot test and proof-of-concept (PoC) scripts.
# Run the scripts in AWS CloudShell (us-east-1). Every check is written to:
#   ~/patchpilot-poc/results.csv   one line per test (PASS / FAIL)
#   ~/patchpilot-poc/poc-log.md    readable log grouped by phase
#   ~/patchpilot-poc/<phase>_*.txt raw evidence (command + output)
set -uo pipefail

export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
PROJECT="patchpilot"
PATCH_GROUP="patchpilot-web"
EVID_DIR="${POC_DIR:-$HOME/patchpilot-poc}"
RESULTS="$EVID_DIR/results.csv"
LOG="$EVID_DIR/poc-log.md"
PHASE="${PHASE:-general}"
PASS_COUNT=0
FAIL_COUNT=0

mkdir -p "$EVID_DIR"
[ -f "$RESULTS" ] || echo "timestamp,phase,test_id,description,result,detail" > "$RESULTS"
[ -f "$LOG" ] || printf '# PatchPilot proof-of-concept log\n\nAccount: %s  |  Region: %s\n' \
  "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" "$AWS_DEFAULT_REGION" > "$LOG"

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

section() {
  echo
  echo "=================================================================="
  echo " $*"
  echo "=================================================================="
  printf '\n## %s\n_Started %s_\n\n' "$*" "$(now)" >> "$LOG"
}

info() { echo "  ... $*"; }

# record <test_id> <description> <PASS|FAIL> [detail]
record() {
  local id="$1" desc="$2" res="$3" detail="${4:-}"
  detail="${detail//$'\n'/ }"
  local csv_desc="${desc//,/;}" csv_detail="${detail//,/;}"
  echo "$(now),$PHASE,$id,$csv_desc,$res,$csv_detail" >> "$RESULTS"
  if [ -n "$detail" ]; then
    printf -- '- `%s` %s: **%s** (%s)\n' "$id" "$desc" "$res" "$detail" >> "$LOG"
  else
    printf -- '- `%s` %s: **%s**\n' "$id" "$desc" "$res" >> "$LOG"
  fi
  if [ "$res" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1)); echo "  [PASS] $id  $desc${detail:+  ($detail)}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  [FAIL] $id  $desc${detail:+  ($detail)}"
  fi
}

# check <test_id> <description> <expected> <actual>
check() {
  if [ "$3" = "$4" ]; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "expected $3; got ${4:-nothing}"; fi
}

# check_ge <test_id> <description> <minimum> <actual>
check_ge() {
  if [[ "$4" =~ ^[0-9]+$ ]] && [ "$4" -ge "$3" ]; then record "$1" "$2" PASS "$4 (minimum $3)"
  else record "$1" "$2" FAIL "expected at least $3; got ${4:-nothing}"; fi
}

# evidence <name> <command...>  saves the command and its output as an evidence file
evidence() {
  local name="$1"; shift
  local f="$EVID_DIR/${PHASE}_${name}.txt"
  { echo "# $(now)"; echo "\$ $*"; echo; "$@"; } > "$f" 2>&1
  echo "  evidence saved: $(basename "$f")"
  printf -- '  - evidence: `%s`\n' "$(basename "$f")" >> "$LOG"
}

stack_status() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND"; }
stack_output() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null; }
stack_resource() { aws cloudformation describe-stack-resource --stack-name "$1" --logical-resource-id "$2" --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null; }

patch_group_ids() {
  aws ec2 describe-instances --filters "Name=tag:PatchGroup,Values=$PATCH_GROUP" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" --output text
}
name_of() { aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].Tags[?Key=='Name']|[0].Value" --output text; }
ip_of()   { aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].PublicIpAddress" --output text; }
state_of(){ aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].State.Name" --output text; }
tag_of()  { aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].Tags[?Key=='$2']|[0].Value" --output text; }
id_by_name() {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query "Reservations[].Instances[].InstanceId" --output text | awk '{print $1}'
}

# health <ip>  prints the body of http://<ip>/health or "unreachable"
health() { curl -s -m 5 "http://$1/health" 2>/dev/null || echo "unreachable"; }

# start_execution <name>  starts the patch cycle and prints the execution ARN
start_execution() {
  local sm; sm=$(stack_output "$PROJECT-automation" StateMachineArn)
  aws stepfunctions start-execution --state-machine-arn "$sm" --name "$1" --query executionArn --output text
}

# wait_execution <arn> [timeout_seconds]  prints the final status
wait_execution() {
  local arn="$1" limit="${2:-2400}" waited=0 st
  while [ "$waited" -lt "$limit" ]; do
    st=$(aws stepfunctions describe-execution --execution-arn "$arn" --query status --output text)
    if [ "$st" != "RUNNING" ]; then echo "$st"; return; fi
    sleep 20; waited=$((waited + 20))
    [ $((waited % 120)) -eq 0 ] && echo "  ... still running ($((waited / 60)) min)" >&2
  done
  echo "TIMEOUT"
}

# json_get <json> <python expression on d>
json_get() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null; }

summary() {
  echo
  echo "------------------------------------------------------------------"
  echo " Result: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo " Evidence folder: $EVID_DIR"
  echo "------------------------------------------------------------------"
  printf '\n**Phase result: %s passed, %s failed** (finished %s)\n' "$PASS_COUNT" "$FAIL_COUNT" "$(now)" >> "$LOG"
  [ "$FAIL_COUNT" -eq 0 ]
}
