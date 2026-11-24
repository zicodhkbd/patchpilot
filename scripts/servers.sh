#!/usr/bin/env bash
# Start, stop or list the PatchPilot servers to save money between work sessions.
#   bash scripts/servers.sh status | stop | start
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
action="${1:-status}"
list() {
  aws ec2 describe-instances --filters "Name=tag:Project,Values=patchpilot" \
    "Name=instance-state-name,Values=$1" --query "Reservations[].Instances[].InstanceId" --output text
}
case "$action" in
  stop)
    ids=$(list running); [ -n "$ids" ] && aws ec2 stop-instances --instance-ids $ids --output table ;;
  start)
    # quarantined servers stay stopped
    ids=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=patchpilot" "Name=instance-state-name,Values=stopped" \
      --query "Reservations[].Instances[?!(Tags[?Key=='Quarantined'])].InstanceId" --output text)
    [ -n "$ids" ] && aws ec2 start-instances --instance-ids $ids --output table
    echo "Wait about 2 minutes for the websites and the SSM Agent. Public IPs have changed." ;;
  *) ;;
esac
aws ec2 describe-instances --filters "Name=tag:Project,Values=patchpilot" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name,PublicIpAddress]" --output table
