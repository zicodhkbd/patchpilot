#!/usr/bin/env bash
# Sprint 3 test: dashboard, weekly schedule, CloudWatch alarm, logs and workflow design.
PHASE=sprint3
# shellcheck source=poc_lib.sh
source "$(dirname "$0")/poc_lib.sh"

section "Sprint 3 test: dashboard, schedule and monitoring"

dash=$(stack_output "$PROJECT-automation" DashboardUrl)
code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$dash")
check S3-01 "Dashboard page loads ($dash)" 200 "$code"
page=$(curl -s -m 10 "$dash" | grep -c "PatchPilot")
check_ge S3-02 "Dashboard page shows PatchPilot" 1 "$page"
json=$(curl -s -m 10 "${dash}status")
servers=$(json_get "$json" "len(d['servers'])")
check_ge S3-03 "Dashboard /status API returns server records" 3 "$servers"
evidence dashboard_status curl -s -m 10 "${dash}status"

rule_state=$(aws events describe-rule --name "$PROJECT-weekly-patch" --query State --output text 2>/dev/null)
rule_expr=$(aws events describe-rule --name "$PROJECT-weekly-patch" --query ScheduleExpression --output text 2>/dev/null)
if [ "$rule_state" = "ENABLED" ]; then record S3-04 "Weekly EventBridge schedule enabled" PASS "$rule_expr"
else record S3-04 "Weekly EventBridge schedule enabled" FAIL "state $rule_state (set SCHEDULE_STATE=ENABLED and run the pipeline)"; fi
target=$(aws events list-targets-by-rule --rule "$PROJECT-weekly-patch" --query "Targets[0].Arn" --output text 2>/dev/null)
check S3-05 "Schedule targets the patch workflow" "$(stack_output "$PROJECT-automation" StateMachineArn)" "$target"
evidence schedule aws events describe-rule --name "$PROJECT-weekly-patch"

alarm=$(aws cloudwatch describe-alarms --alarm-names "$PROJECT-patch-cycle-failed" --query "length(MetricAlarms)" --output text)
check S3-06 "CloudWatch alarm for failed patch cycles exists" 1 "$alarm"
act=$(aws cloudwatch describe-alarms --alarm-names "$PROJECT-patch-cycle-failed" --query "MetricAlarms[0].AlarmActions[0]" --output text)
check S3-07 "Alarm sends to the SNS topic" "$(stack_output "$PROJECT-automation" AlertTopicArn)" "$act"
evidence alarm aws cloudwatch describe-alarms --alarm-names "$PROJECT-patch-cycle-failed" \
  --query "MetricAlarms[].[AlarmName,StateValue,MetricName,Threshold]" --output table

groups=$(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$PROJECT-" --query "length(logGroups)" --output text)
check_ge S3-08 "Lambda log groups in CloudWatch Logs" 5 "$groups"

sm=$(stack_output "$PROJECT-automation" StateMachineArn)
def=$(aws stepfunctions describe-state-machine --state-machine-arn "$sm" --query definition --output text)
for state in Backup SendPatchCommand HealthCheck Rollback Report; do
  if grep -q "\"$state\"" <<< "$def"; then found=1; else found=0; fi
  check "S3-SM-$state" "Workflow contains the $state step" 1 "$found"
done
conc=$(json_get "$def" "d['States']['PatchEachServer']['MaxConcurrency']")
check S3-09 "Rolling patching: one server at a time" 1 "$conc"
evidence executions aws stepfunctions list-executions --state-machine-arn "$sm" --max-items 10 \
  --query "executions[].[name,status,startDate]" --output table

summary
