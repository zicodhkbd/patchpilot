#!/usr/bin/env bash
# Deletes everything PatchPilot created in this AWS account, in the safe order.
# Download your evidence (scripts/50_poc_report.sh) BEFORE running this.
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
echo "This deletes ALL PatchPilot resources (servers, automation, backups, buckets, IAM roles)."
read -r -p "Type DELETE to continue: " answer
[ "$answer" = "DELETE" ] || { echo "Cancelled."; exit 1; }

echo "1/6 Servers created by rollback"
r=$(aws ec2 describe-instances --filters "Name=tag-key,Values=RestoredFrom" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text)
[ -n "$r" ] && aws ec2 terminate-instances --instance-ids $r >/dev/null && aws ec2 wait instance-terminated --instance-ids $r

echo "2/6 Logs bucket and automation stack"
b=$(aws cloudformation describe-stack-resource --stack-name patchpilot-automation --logical-resource-id LogsBucket \
  --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null)
[ -n "$b" ] && aws s3 rm "s3://$b" --recursive >/dev/null
aws cloudformation delete-stack --stack-name patchpilot-automation
aws cloudformation wait stack-delete-complete --stack-name patchpilot-automation

echo "3/6 Servers stack"
aws cloudformation delete-stack --stack-name patchpilot-servers
aws cloudformation wait stack-delete-complete --stack-name patchpilot-servers

echo "4/6 Backup AMIs and snapshots"
for ami in $(aws ec2 describe-images --owners self --filters "Name=tag:Project,Values=patchpilot" --query "Images[].ImageId" --output text); do
  snaps=$(aws ec2 describe-images --image-ids "$ami" --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" --output text)
  aws ec2 deregister-image --image-id "$ami"
  for s in $snaps; do aws ec2 delete-snapshot --snapshot-id "$s"; done
done

echo "5/6 Artifact bucket"
acct=$(aws sts get-caller-identity --query Account --output text)
aws s3 rb "s3://patchpilot-artifacts-$acct" --force 2>/dev/null

echo "6/6 IAM stack (skip in Learner Lab)"
if aws cloudformation describe-stacks --stack-name patchpilot-iam >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name patchpilot-iam
  aws cloudformation wait stack-delete-complete --stack-name patchpilot-iam
fi

echo "Remaining PatchPilot resources (should be empty):"
aws ec2 describe-instances --filters "Name=tag:Project,Values=patchpilot" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName,'patchpilot')].StackName" --output text
echo "Done. Check Billing and Cost Management > Bills tomorrow."
