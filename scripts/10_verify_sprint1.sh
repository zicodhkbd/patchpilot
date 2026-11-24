#!/usr/bin/env bash
# Sprint 1 test: network, three web servers, health pages, Systems Manager, no SSH.
PHASE=sprint1
# shellcheck source=poc_lib.sh
source "$(dirname "$0")/poc_lib.sh"

section "Sprint 1 test: network, servers and Systems Manager"

st=$(stack_status "$PROJECT-servers")
case "$st" in
  CREATE_COMPLETE|UPDATE_COMPLETE) record S1-01 "Servers stack deployed by the pipeline" PASS "$st" ;;
  *) record S1-01 "Servers stack deployed by the pipeline" FAIL "$st" ;;
esac
evidence stack_outputs aws cloudformation describe-stacks --stack-name "$PROJECT-servers" --query "Stacks[0].Outputs" --output table

vpc=$(stack_output "$PROJECT-servers" VpcId)
azs=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query "length(Subnets[].AvailabilityZone)" --output text 2>/dev/null)
check S1-02 "VPC has two public subnets" 2 "$azs"

ids=$(patch_group_ids)
count=$(wc -w <<< "$ids" | tr -d ' ')
check S1-03 "Running servers in patch group $PATCH_GROUP" 3 "$count"
evidence instances aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name,Placement.AvailabilityZone,PublicIpAddress]" --output table

for id in $ids; do
  nm=$(name_of "$id"); ip=$(ip_of "$id")
  check "S1-H-${nm##*-web-}" "Health page http://$ip/health on $nm" OK "$(health "$ip")"
  home=$(curl -s -m 5 "http://$ip/" | grep -c "PatchPilot demo server")
  check "S1-W-${nm##*-web-}" "Home page on $nm" 1 "$home"
done

sg=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=$PROJECT-web-sg" \
  --query "SecurityGroups[0].IpPermissions[].FromPort" --output text)
check S1-04 "Security group allows only HTTP port 80 (no SSH)" 80 "$sg"

keys=$(aws ec2 describe-instances --instance-ids $ids --query "length(Reservations[].Instances[?KeyName!=null][])" --output text 2>/dev/null)
check S1-05 "No SSH key pair attached to the servers" 0 "$keys"

online=$(aws ssm describe-instance-information \
  --query "length(InstanceInformationList[?PingStatus=='Online'])" --output text)
check_ge S1-06 "Servers online as managed nodes in Systems Manager" 3 "$online"
evidence ssm_nodes aws ssm describe-instance-information \
  --query "InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]" --output table

summary
