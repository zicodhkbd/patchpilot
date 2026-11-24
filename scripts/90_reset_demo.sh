#!/usr/bin/env bash
# Puts the original web-3 back after a rollback demo so the demo can be run again:
# terminates web-3-restored, starts the original web-3, returns it to the patch group.
PHASE=reset
# shellcheck source=poc_lib.sh
source "$(dirname "$0")/poc_lib.sh"

section "Reset the rollback demo"

restored=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJECT-web-3-restored" \
  "Name=instance-state-name,Values=running,stopped,pending" --query "Reservations[].Instances[].InstanceId" --output text)
orig=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PROJECT-web-3" "Name=tag:Quarantined,Values=true" \
  "Name=instance-state-name,Values=running,stopped,stopping" --query "Reservations[].Instances[].InstanceId" --output text | awk '{print $1}')

if [ -n "$restored" ]; then info "Terminating $restored"; aws ec2 terminate-instances --instance-ids $restored >/dev/null; fi
if [ -z "$orig" ]; then
  echo "  No quarantined web-3 found. Nothing else to reset."; summary; exit 0
fi
info "Restoring original web-3 $orig"
aws ec2 wait instance-stopped --instance-ids "$orig" 2>/dev/null
aws ec2 start-instances --instance-ids "$orig" >/dev/null
aws ec2 create-tags --resources "$orig" --tags Key=PatchGroup,Value="$PATCH_GROUP" Key=ChaosTest,Value=false
aws ec2 delete-tags --resources "$orig" --tags Key=Quarantined Key=ReplacedBy
aws ec2 wait instance-running --instance-ids "$orig"
info "Waiting for the website to start"
body=""
for _ in $(seq 1 18); do body=$(health "$(ip_of "$orig")"); [ "$body" = OK ] && break; sleep 10; done
check X-01 "Original web-3 is back and healthy" OK "$body"
check X-02 "Original web-3 is back in the patch group" "$PATCH_GROUP" "$(tag_of "$orig" PatchGroup)"
summary
