# Start here - PatchPilot

Follow these in order. Full instructions with every click are in
`docs/guides/PatchPilot_AWS_Free_Account_Guide_English.pdf` (Bangla: `..._Bangla.pdf`).
Mark each step in `docs/tracker/PatchPilot_Deployment_Tracker.xlsx` as you go.

| # | Do this | Guide part | Proof |
|---|---|---|---|
| 1 | Create and secure the AWS account, set a budget | A | screenshots A1-A6 |
| 2 | Install Git/VS Code, create the GitHub repo and backlog board | B | screenshot B6 |
| 3 | CloudFormation: create stack `patchpilot-iam` from `infra/iam.yaml` | C | `00_preflight.sh` |
| 4 | GitHub variables `AWS_ROLE_ARN`, `INSTANCE_PROFILE`, `AUTOMATION_ROLE`; push code | D | green pipeline |
| 5 | Sprint 1 checks | D | `10_verify_sprint1.sh` |
| 6 | Variables `DEPLOY_AUTOMATION=true`, `ALERT_EMAIL`; confirm SNS email | E | |
| 7 | Sprint 2 patch cycle | E | `20_verify_sprint2.sh` |
| 8 | Sprint 3 rollback demo (record it) | F, T | `30_demo_rollback.sh` |
| 9 | `SCHEDULE_STATE=ENABLED`, Sprint 3 checks | F | `40_verify_sprint3.sh` |
| 10 | Build and download the proof-of-concept report | T | `50_poc_report.sh` |
| 11 | Stop servers between sessions | G | `servers.sh stop` |
| 12 | Delete everything at the end | H | `99_cleanup.sh` |

Quick commands (AWS CloudShell, inside the project folder):

```bash
bash scripts/00_preflight.sh
bash scripts/10_verify_sprint1.sh
bash scripts/20_verify_sprint2.sh
bash scripts/30_demo_rollback.sh
bash scripts/40_verify_sprint3.sh
bash scripts/50_poc_report.sh
```
