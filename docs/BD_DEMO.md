# Camera Capture: minimal BD integration + internal 307.2 MB/s generator (v0.1)

This package is an **add-on**, not a patch to existing proven capture RTL.
It provides a deterministic synthesisable signal source and a Verilog-2001
adapter for Vivado 2023.1 Module Reference.

## Deliverables

- `rtl/test_camera_stream_gen.v`: 200 MHz pseudo-camera, 96x64-bit/frame,
  exact 307,200,000 B/s, 400,000 frames/s; algorithmic trigger every 128 frames.
- `rtl/capture_demo_bd.v`: Verilog-2001 module-reference adapter; instantiates
  the existing SystemVerilog `camera_capture_top` with `USE_XPM=1` and generator.
  It exposes only AXI4-Lite S_AXI, AXI3 64-bit write M_AXI, clock and reset.
- `sim/tb_test_camera_stream_gen.sv`: stand-alone self-checking RTL testbench
  (130 frames, exact rate and trigger checks).
- `bd/connect_capture_demo.tcl`: optional template for connection to an
  **already configured** Zynq PS7 in an open BD.

## Why not just add camera_capture_top.sv as BD Module Reference?

In Vivado 2023.1, the **top-level definition of a Module Reference must be
Verilog or VHDL**, not SystemVerilog (UG994). We use the `.v` wrapper for the
BD, while the original SystemVerilog capture core remains unchanged.

## Adding source files to an existing Vivado project

From Vivado Tcl Console, after changing the path to the Git checkout:

```tcl
set root /home/alx/xil_proj/Lovozero_vitis/ip_repo/CameraDataCaptureIP
add_files -fileset sources_1 -norecurse [file join $root rtl test_camera_stream_gen.v]
add_files -fileset sources_1 -norecurse [file join $root rtl capture_demo_bd.v]
add_files -fileset sim_1 -norecurse [file join $root sim tb_test_camera_stream_gen.sv]
update_compile_order -fileset sources_1
```

Do NOT `import_files`: that would create copies under `.srcs/imports` and
break the Git-to-Vivado single source of truth. Ensure the existing core RTL
is still in `sources_1` and points to the Git working tree.

### Generator smoke test

```tcl
set_property top tb_test_camera_stream_gen [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
launch_simulation
```

Expected testbench output:

```
PASS: camera generator, 130 frames, 12480 words, 2 algorithmic triggers, exact 307.2 MB/s
```

This output is an **expectation**, not a test result from this package author:
Vivado/XSIM was not available in the environment where the files were made.

### Generator details

- Incoming camera S_AXIS has no flow control (`TREADY` not consulted).
- `TDATA = {frame_index[31:0], word_index[31:0]}`.
  Example: first word of frame 128 is `64'h00000080_00000000`, and word 95
  is `64'h00000080_0000005F` with `TLAST=1`.
- `TVALID` pulses 24 times per 125 200-MHz clocks, automatically spaced
  5 or 6 cycles; this is the exact nominal 307.2 MB/s rate.
- Trigger has `TVALID=1` at word 0 of frames 0, 128, 256, etc.
  Trigger data = `64'h54524752_XXXXXXXX` (XXXXXXXX = frame number).
  The first trigger (frame 0) is ignored while the capture FIFO fills.
- `timestamp[63:32] = 0`; the lower 32 bits count 200 MHz clocks, wrapping
  every ~21.47 seconds. Benchmark source only; NOT a production timestamp.
- The generator runs after reset without any software configuration.
  PS software **must** still configure and START the capture core.
- At 400,000 frames/second, each frame lasts precisely 500 clock cycles.

## BD construction

**Important:** the PS7 MIO/DDR preset is BOARD-SPECIFIC. You have not
provided a board name or the PS DDR memory preset, so no script guesses it.
Use your existing board-configured PS7 block, or create a BD and select the
correct board/PS DDR preset.

1. Create/open a Block Design with `processing_system7_0` (ZYNQ7 Processing System).
   Enable `M_AXI_GP0` and `S_AXI_HP0`, select HP0 **64-bit** data, set
   `FCLK_CLK0 = 200 MHz`; enable DDR and PS FIXED_IO per your board preset.
2. Add `capture_demo_bd` as **Add Module** (not the SystemVerilog core itself).
   Vivado should infer `S_AXI` (slave, AXI4-Lite) and `M_AXI` (master,
   write-only AXI3, 64-bit) from explicit port attributes.
3. Put an **AXI Interconnect** (1 SI, 1 MI) between PS `M_AXI_GP0` and
   `capture_demo_bd/S_AXI` for AXI3->AXI4-Lite adaptation.
4. Connect `capture_demo_bd/M_AXI` **directly** to PS `S_AXI_HP0`,
   with no AXI interconnect on the write datapath.
5. Drive `clk` and PS `M_AXI_GP0_ACLK` / `S_AXI_HP0_ACLK` from 200-MHz
   `FCLK_CLK0`. Use `proc_sys_reset` with active-low `FCLK_RESET0_N`
   and drive wrapper `rst` from `peripheral_reset` (active high).
   Interconnect resets are active-low `interconnect_aresetn`.
6. In **Address Editor**, assign the control slave a base/segment. You may
   choose `0x43C00000` for example if free; **this is NOT DDR MEM_ADDR**.
   Verify the HP0 master has a valid reachable PS DDR segment.
7. Run `Validate Design`, `Generate Output Products`, `Create HDL Wrapper`,
   then set the BD HDL wrapper as top. Synthesize and implement.

If the PS block is named `processing_system7_0`, the optional starter script
can perform steps 2–5 in the **open BD**, after adding RTL files:

```tcl
source /home/alx/xil_proj/Lovozero_vitis/ip_repo/CameraDataCaptureIP/bd/connect_capture_demo.tcl
```

The script has **not been executed in Vivado**. The PS configuration or
Vivado's interface checking can require adjusting it. If the inferred AXI3
write-only interface cannot connect directly, stop at Validate Design and
send the exact messages; do NOT silently insert an AXI converter on HP0.

## Timing and optimizer notes

The test stream cannot be optimized away when its data can reach the PS DDR
through an active AXI bus and the PS controls the capture by AXI-Lite. Merely
adding a standalone unused generator **does not** preserve capture logic.
The external PS AXI ports must remain connected, not tied to inactive constants.

A previous standalone XDC such as
`create_clock -period 5 [get_ports clk]` must not be reused verbatim when
`clk` becomes an **internal BD signal**. PS `FCLK_CLK0` should be represented
by a generated clock; inspect `report_clocks` and `report_timing_summary` in
the completed BD. Do not add a fake top-level clock port to make the XDC pass.

The post-synthesis hold slack previously observed at standalone top is not
proof that routed implementation will fail. Check **post-route** setup/hold.

## First software capture smoke test (after bitstream and board boot)

1. Reserve a **real PS DDR region** for DMA, aligned to 128 bytes; do not
   overwrite OS/kernel/bootloader memory. For Linux use reserved memory,
   DMA APIs, and cache maintenance; bare-metal uses linker/allocator and
   cache invalidation before CPU reads the captured DDR region.
2. Write control AXI-Lite registers: `TRIGGER_ENABLE=1` (`0x00C`),
   `N_FRAMES=4` (`0x010`), `N_PREV_FRAMES=2` (`0x014`),
   `N_FRAGMENTS=2` (`0x018`), `MEM_ADDR` (`0x01C`, reserved DDR address),
   `MEM_BUFFER_BYTES=8192` (`0x0B4`, if 8192 reserved), then START
   `COMMAND=1` (`0x000`). 2 * (128 + 4 * 768) = 6400 bytes <= 8192.
3. Trigger at frame 128 should start the first fragment if FIFO is filled.
   Trigger at frame 256 should start the second. Read STATUS (`0x004`),
   ERROR_FLAGS (`0x008`) and DDR contents. Preamble is 128 bytes;
   subsequent frame words can be checked from the high/low halves.
4. Check no FIFO, AXI BRESP, range, or frame-format error. Do not
   start the capture before valid HP DDR addressing is configured.

## Limitations

- This is a first bring-up generator: no gaps/errors/STOP/programmable
  data format and no real camera input. It is not the later full-featured
  programmable camera simulator.
- The wrapper ties `ext_trig=0`; generator supplies algorithmic triggers.
- Integration is not verified until your Vivado BD `Validate Design` passes.
- Physical PS DDR settings depend on the board preset, and runtime access
  depends on CPU software configuration.
