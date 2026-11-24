#!/usr/bin/env bash
# Sprint 2 test: automation resources, then a full patch cycle with backup, patching,
# status records, logs and the email report. Takes about 10-15 minutes.
PHASE=sprint2
# shellcheck source=poc_lib.sh
source "$(dirname "$0")/poc_lib.sh"

section "Sprint 2 test: backup and patch automation"

st=$(stack_status "$PROJECT-automation")
case "$st" in
  CREATE_COMPLETE|UPDATE_COMPLETE) record S2-01 "Automation stack deployed by the pipeline" PASS "$st" ;;
  *) record S2-01 "Automation stack deployed by the pipeline" FAIL "$st"; summary; exit 1 ;;
esac
evidence stack_outputs aws cloudformation describe-stacks --stack-name "$PROJECT-automation" --query "Stacks[0].Outputs" --output table

bl=$(aws ssm describe-patch-groups --query "Mappings[?PatchGroup=='$PATCH_GROUP']|[0].BaselineIdentity.BaselineName" --output text)
check S2-02 "Patch baseline registered for patch group" "$PROJECT-al2023-baseline" "$bl"

fn=$(aws lambda list-functions --query "length(Functions[?starts_with(FunctionName,'$PROJECT-')])" --output text)
check S2-03 "Lambda functions deployed" 7 "$fn"

topic=$(stack_output "$PROJECT-automation" AlertTopicArn)
sub=$(aws sns list-subscriptions-by-topic --topic-arn "$topic" --query "Subscriptions[0].SubscriptionArn" --output text)
if [[ "$sub" == arn:aws:sns:* ]]; then record S2-04 "Email subscription confirmed" PASS
else record S2-04 "Email subscription confirmed" FAIL "status: $sub (open the confirmation email)"; fi

chaos=$(aws ec2 describe-instances --filters "Name=tag:PatchGroup,Values=$PATCH_GROUP" "Name=tag:ChaosTest,Values=true" \
  "Name=instance-state-name,Values=running" --query "length(Reservations[].Instances[])" --output text)
check S2-05 "No server is tagged for the fault test (ChaosTest=false)" 0 "$chaos"

run="poc-sprint2-$(date -u +%Y%m%d-%H%M%S)"
info "Starting patch cycle $run (watch it in Step Functions > patchpilot-patch-cycle)"
arn=$(start_execution "$run")
status=$(wait_execution "$arn" 2400)
check S2-06 "Patch cycle execution finished" SUCCEEDED "$status"
evidence execution aws stepfunctions describe-execution --execution-arn "$arn" --query "{status:status,start:startDate,stop:stopDate,output:output}"

out=$(aws stepfunctions describe-execution --execution-arn "$arn" --query output --output text)
total=$(json_get "$out" "d['summary']['total']")
healthy=$(json_get "$out" "d['summary']['healthy']")
check S2-07 "Servers processed by the cycle" 3 "$total"
check S2-08 "Servers patched and healthy" 3 "$healthy"

amis=$(aws ec2 describe-images --owners self --filters "Name=tag:RunId,Values=$run" --query "length(Images)" --output text)
check S2-09 "Pre-patch backup AMIs created (one per server)" 3 "$amis"
evidence backup_amis aws ec2 describe-images --owners self --filters "Name=tag:RunId,Values=$run" \
  --query "Images[].[Name,ImageId,State,CreationDate]" --output table

rows=$(aws dynamodb scan --table-name "$PROJECT-status" --filter-expression "RunId = :r" \
  --expression-attribute-values "{\":r\":{\"S\":\"$run\"}}" --query "Items[].Status.S" --output text)
ok_rows=$(tr '\t' '\n' <<< "$rows" | grep -c PATCHED_HEALTHY)
check S2-10 "DynamoDB status rows marked PATCHED_HEALTHY" 3 "$ok_rows"
evidence dynamodb_rows aws dynamodb scan --table-name "$PROJECT-status" --filter-expression "RunId = :r" \
  --expression-attribute-values "{\":r\":{\"S\":\"$run\"}}" \
  --query "Items[].[Name.S,Status.S,BackupAmiId.S,Detail.S]" --output table

cmds=$(aws ssm list-commands --filters "key=DocumentName,value=AWS-RunPatchBaseline" --max-items 3 \
  --query "Commands[].Status" --output text | tr '\t' '\n' | grep -c Success)
check S2-11 "Patch Manager commands succeeded (AWS-RunPatchBaseline)" 3 "$cmds"
evidence patch_commands aws ssm list-commands --filters "key=DocumentName,value=AWS-RunPatchBaseline" --max-items 3 \
  --query "Commands[].[CommandId,Status,RequestedDateTime,TargetCount]" --output table

bucket=$(stack_resource "$PROJECT-automation" LogsBucket)
logs=$(aws s3 ls "s3://$bucket/patch-logs/" --recursive | wc -l | tr -d ' ')
check_ge S2-12 "Patch output saved in S3" 1 "$logs"

evidence patch_compliance aws ssm list-resource-compliance-summaries --filters "Key=ComplianceType,Values=Patch,Type=EQUAL" \
  --query "ResourceComplianceSummaryItems[].[ResourceId,Status,CompliantSummary.CompliantCount,NonCompliantSummary.NonCompliantCount]" --output table

echo
echo "  Check your inbox for: 'PatchPilot: all servers patched' (record it as evidence S2-13)."
summary
