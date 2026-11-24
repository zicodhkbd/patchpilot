#!/usr/bin/env bash
# Step 0: check the AWS account is ready and print the GitHub variables to set.
PHASE=preflight
# shellcheck source=poc_lib.sh
source "$(dirname "$0")/poc_lib.sh"

section "Preflight: account, Region and IAM stack"

ident=$(aws sts get-caller-identity --query Arn --output text 2>&1)
if [[ "$ident" == arn:aws:* ]]; then record P-01 "Signed in to AWS" PASS "$ident"; else record P-01 "Signed in to AWS" FAIL "$ident"; fi
check P-02 "Region is us-east-1" us-east-1 "$AWS_DEFAULT_REGION"

st=$(stack_status "$PROJECT-iam")
case "$st" in
  CREATE_COMPLETE|UPDATE_COMPLETE) record P-03 "IAM stack patchpilot-iam deployed" PASS "$st" ;;
  NOT_FOUND) record P-03 "IAM stack patchpilot-iam deployed" FAIL "not found (Learner Lab users can ignore this)" ;;
  *) record P-03 "IAM stack patchpilot-iam deployed" FAIL "$st" ;;
esac

if [ "$st" != "NOT_FOUND" ]; then
  role=$(stack_output "$PROJECT-iam" GitHubDeployRoleArn)
  prof=$(stack_output "$PROJECT-iam" InstanceProfileName)
  auto=$(stack_output "$PROJECT-iam" AutomationRoleName)
  evidence iam_outputs aws cloudformation describe-stacks --stack-name "$PROJECT-iam" --query "Stacks[0].Outputs" --output table
  echo
  echo "  Set these GitHub repository variables (Settings > Secrets and variables > Actions > Variables):"
  echo "    AWS_ROLE_ARN     = $role"
  echo "    INSTANCE_PROFILE = $prof"
  echo "    AUTOMATION_ROLE  = $auto"
  oidc=$(aws iam list-open-id-connect-providers --query "length(OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')])" --output text)
  check P-04 "GitHub OIDC provider exists" 1 "$oidc"
fi

echo
echo "  Current PatchPilot stacks:"
for s in iam servers automation; do printf '    %-24s %s\n' "$PROJECT-$s" "$(stack_status "$PROJECT-$s")"; done
summary
