#!/usr/bin/env bash
# Run inside the Vivado Docker container.
# Usage: bash scripts/run_vivado.sh sim tb_capture_main_fsm
#        bash scripts/run_vivado.sh synth
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="/home/alx/vivado_installed/Vivado/2023.1/settings64.sh"
if [[ ! -f "$SETTINGS" ]]; then
  echo "ERROR: Vivado settings not found: $SETTINGS" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$SETTINGS"

shopt -s nullglob
projects=("$ROOT"/*.xpr)
if (( ${#projects[@]} != 1 )); then
  echo "ERROR: Expected exactly one .xpr in $ROOT, found ${#projects[@]}" >&2
  exit 2
fi
XPR="${projects[0]}"
mkdir -p "$ROOT/build/logs" "$ROOT/build/reports"
MODE="${1:-}"
cd "$ROOT"
case "$MODE" in
  sim)
    TB="${2:?Usage: bash scripts/run_vivado.sh sim tb_name}"
    RUNLOG="$ROOT/build/logs/${TB}.log"
    echo "SIM: $TB"
    vivado -mode batch -nojournal -nolog \
      -source "$ROOT/scripts/run_sim.tcl" -tclargs "$XPR" "$TB" \
      2>&1 | tee "$RUNLOG"
    PRJ_NAME="$(basename "$XPR" .xpr)"
    SIMLOG="$ROOT/${PRJ_NAME}.sim/sim_1/behav/xsim/simulate.log"
    if [[ ! -f "$SIMLOG" ]]; then
      echo "ERROR: XSIM log not found: $SIMLOG" >&2
      exit 1
    fi
    if grep -Eq 'Fatal:|\$fatal|CHECK FAILED|^FAIL:' "$SIMLOG"; then
      echo "ERROR: Simulator reported failure (see $SIMLOG)" >&2
      exit 1
    fi
    if ! grep -q 'PASS:' "$SIMLOG"; then
      echo "ERROR: No PASS: marker in $SIMLOG (not considered successful)" >&2
      exit 1
    fi
    grep 'PASS:' "$SIMLOG" | tail -n 1
    echo "PASS: $TB"
    ;;
  synth)
    RUNLOG="$ROOT/build/logs/synth.log"
    vivado -mode batch -nojournal -nolog \
      -source "$ROOT/scripts/run_synth.tcl" \
      -tclargs "$XPR" "$ROOT/build/reports" \
      2>&1 | tee "$RUNLOG"
    echo "Synthesis reports: $ROOT/build/reports"
    ;;
  *)
    echo "Usage: bash scripts/run_vivado.sh {sim TESTBENCH_TOP|synth}" >&2
    exit 2
    ;;
esac
