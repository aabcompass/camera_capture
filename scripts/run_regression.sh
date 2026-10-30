#!/usr/bin/env bash
# Run inside Docker after sources have been relinked to Git-tracked paths.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tb in \
  tb_frame_input_ctrl \
  tb_capture_fifo_ctrl \
  tb_trigger_ctrl \
  tb_burst_packer \
  tb_axi3_write_master \
  tb_mem_range_guard \
  tb_axi_lite_regs \
  tb_capture_main_fsm \
  tb_camera_capture_top \
  tb_camera_capture_stress \
  tb_camera_capture_faults; do
  echo "========== $tb =========="
  bash "$ROOT/scripts/run_vivado.sh" sim "$tb"
done
printf '\nALL REGRESSION TESTBENCHES PASSED\n'
