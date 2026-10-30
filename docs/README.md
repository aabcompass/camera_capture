# Camera Capture IP: Git (host) + Vivado 2023.1 (Docker)

This starter bundle contains scripts **only**, not RTL. Put the scripts and .gitignore at the root
of the existing `CameraDataCaptureIP` Vivado project directory that contains its `.xpr` file.

Important: Before running scripts, relink project sources to the working Git `rtl/` and `sim/`
files. Do not keep using `.srcs/**/imports/` copies of the same modules.

## On Ubuntu host (one-time setup)

```
cd ~/xil_proj/Lovozero_vitis/ip_repo/CameraDataCaptureIP
mkdir -p rtl sim scripts docs constraints build
# Extract this bundle into this directory, preserving scripts/.
# Copy your VERIFIED latest .sv files from the Vivado imports locations into rtl/ and sim/.
git init
git add rtl sim scripts docs constraints .gitignore README.md
git commit -m 'Baseline: verified Camera Data Capture RTL and tests'
```

## One-time Vivado migration

Open existing project in Vivado GUI. In Design Sources / Simulation Sources, remove the
old imported `.sv` copies **from project only, not from disk**. Add the files from `rtl/`
and `sim/` with **Copy sources into project unchecked**. Keep `.xpr` in the project root.
Save and close Vivado GUI before using batch scripts. Check the Sources window that file
paths point to Git-tracked files, not `.srcs/.../imports/...`.

## Docker

Your Docker run script already bind-mounts `/home/alx/xil_proj` to the same path in the
container. Optional: add `--name vivado23` to `docker run ...`; keep the container running
in one terminal. From the host in another terminal:

```
docker exec vivado23 bash -lc 'cd /home/alx/xil_proj/Lovozero_vitis/ip_repo/CameraDataCaptureIP && bash scripts/run_vivado.sh sim tb_capture_main_fsm'
docker exec vivado23 bash -lc 'cd /home/alx/xil_proj/Lovozero_vitis/ip_repo/CameraDataCaptureIP && bash scripts/run_vivado.sh synth'
```

Or in the container shell directly:

```
bash scripts/run_vivado.sh sim tb_capture_main_fsm
bash scripts/run_regression.sh
bash scripts/run_vivado.sh synth
```

Each test run checks `simulate.log` for a `PASS:` marker and failure patterns. This is a
simple guard, not a full test quality proof: every testbench must print PASS exactly once
only after finishing all checks, and use `$fatal` for failures. The set of testbenches
included in `run_regression.sh` assumes all these TBs have been added to the project's
Simulation Sources.

## Git workflow (host)

```
git status
git diff --check
git diff
git add rtl sim scripts
# After tests pass in Docker:
git commit -m 'Optimize stop boundary timing in FSM'
```

For assistant patches: `git apply --check file.patch`, `git apply file.patch`, then review
`git diff` and run regression. Do not apply patches from an unknown/untrusted source.

## Notes

- `run_synth.tcl` resets synth_1; it will overwrite previous synthesis results.
- Run Vivado GUI and batch scripts serially on the same .xpr (avoid simultaneous edits).
- The existing `.xpr` is intentionally Git-ignored as a *transitional* setup. For full
  reproducibility, the next step is a Tcl script that creates a clean project with the
  actual XC7Z035 **part number** and all source/constraint mappings.
- Existing generated archives, Vitis hardware exports, and .xci are not automatically
  included in this Git baseline. Preserve any manually customized IP/.xci in version
  control if needed.
- Your Docker startup uses `--privileged` and `xhost +local:docker` (broad permissions).
  They are not required for batch synthesis/simulation and should be narrowed later;
  USB/JTAG access may require additional device configuration for hardware debugging.
- `LIBRARY_PATH` in Docker run may cause the XSIM compiler-environment warning seen
  earlier. If batch compilation has problems, try removing that override first.
