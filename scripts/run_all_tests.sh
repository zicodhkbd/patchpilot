#!/usr/bin/env bash
# Runs the whole test phase in order and builds the proof-of-concept report.
#   bash scripts/run_all_tests.sh            all tests including the rollback demo (~40 min)
#   bash scripts/run_all_tests.sh --quick    skip the Sprint 2 patch run and the rollback demo
dir="$(dirname "$0")"
bash "$dir/00_preflight.sh"
bash "$dir/10_verify_sprint1.sh"
if [ "${1:-}" != "--quick" ]; then
  bash "$dir/20_verify_sprint2.sh"
  bash "$dir/30_demo_rollback.sh"
fi
bash "$dir/40_verify_sprint3.sh"
bash "$dir/50_poc_report.sh"
