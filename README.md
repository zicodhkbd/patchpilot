# PatchPilot - Automated Server Patching with Backup, Health Check and Rollback

DEVP-600 Final Project (Business Innovation with DevOps), Saskatchewan Polytechnic.

PatchPilot automates the full patch cycle for a fleet of Amazon Linux 2023 web servers:

1. **Discover** the servers tagged `PatchGroup=patchpilot-web`
2. **Back up** each server (pre-patch AMI) before touching it
3. **Patch** it with AWS Systems Manager Patch Manager (`AWS-RunPatchBaseline`)
4. **Health-check** the website (`http://<server>/health`)
5. **Roll back** automatically if the check fails: launch a replacement from the backup and quarantine the broken server
6. **Report** the result by email (SNS) and on a live dashboard (API Gateway + Lambda + DynamoDB)

Servers are patched one at a time (rolling), so the service stays available.

## Repository layout

| Path | Purpose |
|---|---|
| `infra/iam.yaml` | Stack 0 (personal account only): instance profile, automation role, GitHub OIDC deploy role |
| `infra/servers.yaml` | Stack 1: VPC, 2 public subnets (2 AZs), security group, 3 web servers |
| `infra/automation.yaml` | Stack 2: Patch baseline, Step Functions workflow, Lambdas, DynamoDB, SNS, EventBridge schedule, CloudWatch alarm, HTTP API |
| `src/handlers.py` | Lambda handlers (discover, backup, check_patch, health_check, rollback, report, api) |
| `src/common.py` | Pure helper functions (unit-tested) |
| `src/dashboard.html` | Dashboard page served by the API Lambda |
| `tests/` | Unit tests run by the pipeline |
| `scripts/` | Test, demo, proof-of-concept and clean-up scripts (AWS CloudShell) |
| `docs/` | Step-by-step guides (English and Bangla), tracker, diagrams |
| `.github/workflows/pipeline.yml` | CI/CD: lint, test, then deploy both stacks |

## Personal AWS account (Free Tier)

Deploy `infra/iam.yaml` once from the CloudFormation console (stack name `patchpilot-iam`), then set the GitHub
variables `AWS_ROLE_ARN`, `INSTANCE_PROFILE` and `AUTOMATION_ROLE` from its Outputs. The pipeline then signs in
with OIDC and no secrets are needed. See `docs/guides/` for the full step-by-step guide (English and Bangla).

## Pipeline settings (GitHub -> Settings -> Secrets and variables -> Actions)

Secrets (copy from the AWS Academy Learner Lab "AWS Details" panel; they expire with each lab session):
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`

Variables:

| Variable | Value | When |
|---|---|---|
| `DEPLOY_AUTOMATION` | `true` | From Sprint 2 |
| `ALERT_EMAIL` | your email | From Sprint 2 |
| `SCHEDULE_STATE` | `ENABLED` or `DISABLED` | Sprint 3 |
| `CHAOS_TEST` | `true` only for the rollback test | Sprint 3 |

## Run a patch cycle manually

```bash
ARN=$(aws cloudformation describe-stacks --stack-name patchpilot-automation \
  --query "Stacks[0].Outputs[?OutputKey=='StateMachineArn'].OutputValue" --output text)
aws stepfunctions start-execution --state-machine-arn $ARN
```

Or open Step Functions in the console, select `patchpilot-patch-cycle` and choose **Start execution**.

## Test phase and proof of concept

Run these in AWS CloudShell (us-east-1) from the project folder. Every check prints PASS/FAIL and saves
evidence in `~/patchpilot-poc`.

| Script | Purpose |
|---|---|
| `scripts/00_preflight.sh` | Account, Region, IAM stack; prints the GitHub variables |
| `scripts/10_verify_sprint1.sh` | Network, 3 servers, health pages, no SSH, Systems Manager |
| `scripts/20_verify_sprint2.sh` | Runs a full patch cycle and checks backups, status, logs |
| `scripts/30_demo_rollback.sh` | Demo: breaks web-3 and proves automatic rollback |
| `scripts/40_verify_sprint3.sh` | Dashboard, schedule, alarm, logs, workflow design |
| `scripts/50_poc_report.sh` | Builds `poc-report.html` and zips all evidence |
| `scripts/run_all_tests.sh` | All of the above (`--quick` skips the patch run and demo) |
| `scripts/90_reset_demo.sh` | Brings web-3 back so the demo can be repeated |
| `scripts/servers.sh stop\|start\|status` | Save money between sessions |
| `scripts/99_cleanup.sh` | Deletes everything at the end |

Track every step and its evidence in `docs/tracker/PatchPilot_Deployment_Tracker.xlsx`.

## Local tests

```bash
pip install pytest cfn-lint flake8 boto3
cfn-lint --ignore-checks W3002 -- infra/*.yaml && flake8 src tests --max-line-length 130 && pytest -v tests
```

See `START_HERE.md` for the order of work.
