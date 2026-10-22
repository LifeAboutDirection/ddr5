#!/usr/bin/env bash
# Run a ddr5_model testbench under Verilator inside a rootless podman container.
#
# Verilator (not Icarus) is required: the model uses interfaces, associative
# arrays and multi-dimensional unpacked arrays. The pinned iverilog image in
# this workspace miscompiles or crashes on all three.
#
# Usage: ./run.sh [top_module] [extra verilator args]
#        ./run.sh tb_dfi_smoke -GG=4      # 1:4 gear ratio
set -euo pipefail

TOP="${1:-tb_ddr5_smoke}"
shift || true
VEXTRA="$*"
IMAGE="${DDR5_SIM_IMAGE:-docker.io/verilator/verilator:latest}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRCS="rtl/ddr5_pkg.sv rtl/ddr5_timing_pkg.sv rtl/ddr5_ecc_pkg.sv rtl/dfi_pkg.sv \
      rtl/ddr5_device.sv rtl/dfi_if.sv rtl/dfi_ddr5_phy.sv tb/${TOP}.sv"

podman run --rm --entrypoint sh \
  -v "$ROOT":/w:Z -w /w "$IMAGE" -c "
    set -e
    verilator --binary --timing \
      -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-fatal \
      --top-module ${TOP} -o sim_${TOP} ${VEXTRA} \
      -Mdir sim/obj_dir ${SRCS}
    ./sim/obj_dir/sim_${TOP}
  "
