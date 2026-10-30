// Camera Data Capture IP - Main FSM v1.2 (timing optimization)
// XC7Z035, one clock (200 MHz target), seven externally visible states.
// This controller coordinates existing VERIFIED leaf-module interfaces.
// In particular: guard validates SHADOW, run_start_pulse captures ACTIVE;
// frame_stored and trigger_accept are SAME-CLOCK events; packer/writer
// start one clock after trigger, so latched metadata is available.
// Normal STOP updates burst_packer.stop_target_frames, never halt_new.
// Fatal faults stop new AXI descriptors but wait for all AW/W/B to drain.
// The complete original user specification must appear verbatim in the
// comment of camera_capture_top.sv (not duplicated in this leaf module).
`default_nettype none
module capture_main_fsm (
    input  wire        clk,
    input  wire        rst,

    // From axi_lite_regs (commands are pulses, active_* are sampled on run_start).
    input  wire        cmd_start,
    input  wire        cmd_stop,
    input  wire        cmd_clear_error,
    input  wire [31:0] sticky_error_flags,
    input  wire [31:0] active_n_frames,
    input  wire [31:0] active_n_prev_frames,
    input  wire [31:0] active_n_fragments,
    input  wire [31:0] active_mem_addr,
    output wire        allow_start,
    output wire        allow_clear_error,
    output wire        allow_clear_stats,
    output wire        cfg_write_lock,
    output wire        guard_check_req,
    output wire        run_start_pulse,
    output wire [31:0] guard_error_set_mask,

    // From mem_range_guard (one check_done pulse for each check_req).
    input  wire        guard_check_done,
    input  wire        guard_check_ok,
    input  wire [31:0] guard_check_error_flags,
    input  wire [31:0] guard_fragment_bytes,

    // From frame_input_ctrl and capture_fifo_ctrl.
    input  wire        fifo_ready,
    input  wire [7:0]  fifo_complete_frames,
    input  wire        frame_sync_ready,
    input  wire        frame_stored,       // captured_frame_done, same-clock event
    input  wire        capture_stopped,   // frame_input_ctrl STOP boundary pulse
    input  wire        trigger_accept,   // synchronous decision, SAME input edge
    input  wire        fatal_error,      // pulse/level from active datapath
    output wire        frame_sync_request,
    output wire        capture_enable,
    output wire        frame_stop_request,
    output wire        fifo_flush,
    output wire        fifo_drop_enable,
    output wire        fifo_transfer_enable,
    output wire        trigger_run_active,
    output wire        trigger_accept_enable,
    output wire        trigger_count_enable,

    // To burst_packer and axi3_write_master; their start pulses coincide.
    output wire        fragment_start_pulse,
    output wire        packer_abort,
    output wire        writer_halt_new,
    output wire        stop_target_valid,
    output wire [17:0] stop_target_frames,
    output wire [17:0] fragment_n_frames,
    output wire [31:0] fragment_addr,
    output wire [31:0] fragment_index,

    // From burst_packer / axi3_write_master.
    input  wire        writer_done,       // all intended data committed, BRESP OKAY
    input  wire        writer_drain_done, // no AW/W/B pending; NOT fragment complete
    input  wire [17:0] writer_frames_committed,
    input  wire        writer_preamble_committed,

    // Status and stats for axi_lite_regs / capture_statistics.
    output logic [3:0] fsm_state,
    output wire        status_busy,
    output wire        status_stop_pending,
    output wire        status_trigger_latched,
    output wire        status_capture_complete,
    output logic [31:0] frames_captured,
    output logic [31:0] run_fragments_completed,
    output wire        fragment_complete_pulse,
    output logic [31:0] last_fragment_addr,
    output logic [31:0] last_fragment_frames,
    output logic [31:0] last_fragment_size,
    output logic [31:0] last_fragment_status
);
    localparam logic [3:0] S_IDLE  = 4'd0;
    localparam logic [3:0] S_FILL  = 4'd1;
    localparam logic [3:0] S_WAIT  = 4'd2;
    localparam logic [3:0] S_XFER  = 4'd3;
    localparam logic [3:0] S_AFTER = 4'd4;
    localparam logic [3:0] S_ERROR = 4'd5;
    localparam logic [3:0] S_END   = 4'd6;

    logic validating, sync_issued, fragment_started, abort_pending;
    // ACTIVE registers in axi_lite_regs update on run_start_pulse via NBA.
    // Their new values are visible only AFTER that edge.  Capture the
    // initial fragment address on the next edge, before camera sync begins.
    logic start_cfg_pending;
    logic stop_pending, stop_boundary_seen, stop_target_pending;
    logic stop_early, trigger_seen;
    logic flush_issued;
    logic [1:0] flush_wait;
    logic error_cleanup_done;
    logic [31:0] active_fragment_bytes;
    logic [31:0] fragment_addr_reg, fragment_index_reg;
    logic [31:0] next_frame_count;
    logic [17:0] next_frame_count18;
    logic full_frame_count;

    assign allow_start = (fsm_state == S_IDLE) && !validating &&
                         (sticky_error_flags == 32'd0);
    assign allow_clear_error = ((fsm_state == S_IDLE) && !validating) ||
                               ((fsm_state == S_ERROR) && error_cleanup_done && fifo_ready);
    assign allow_clear_stats = ((fsm_state == S_IDLE) && !validating) ||
                               (fsm_state == S_END);
    assign guard_check_req = (fsm_state == S_IDLE) && !validating &&
                             cmd_start && !cmd_stop &&
                             (sticky_error_flags == 32'd0);
    assign cfg_write_lock = validating || guard_check_req;
    // The guard has captured SHADOW and answered; ACTIVE captures on this edge.
    assign run_start_pulse = (fsm_state == S_IDLE) && validating &&
                             guard_check_done && guard_check_ok && !cmd_stop;
    assign guard_error_set_mask = ((fsm_state == S_IDLE) && validating &&
                                  guard_check_done && !guard_check_ok) ?
                                  guard_check_error_flags : 32'd0;

    assign frame_sync_request = (fsm_state == S_FILL) && !sync_issued &&
                                !start_cfg_pending && fifo_ready &&
                                !stop_pending && !cmd_stop;
    // In a stopped current frame we keep capture_enable high until TLAST.
    assign capture_enable = ((fsm_state == S_FILL && sync_issued) ||
                             (fsm_state == S_WAIT) ||
                             (fsm_state == S_XFER && !full_frame_count)) &&
                            !stop_boundary_seen && !abort_pending && !fatal_error;
    assign frame_stop_request = cmd_stop &&
                  (fsm_state == S_FILL || fsm_state == S_WAIT || fsm_state == S_XFER);
    assign fifo_drop_enable = (fsm_state == S_WAIT) && !stop_pending &&
                              !cmd_stop && !fatal_error;
    assign fifo_transfer_enable = (fsm_state == S_XFER) && !abort_pending &&
                                  !fatal_error && fragment_started;
    assign trigger_run_active = (fsm_state == S_FILL) || (fsm_state == S_WAIT) ||
                                (fsm_state == S_XFER) || (fsm_state == S_AFTER);
    assign trigger_accept_enable = (fsm_state == S_WAIT) && !stop_pending &&
                                   !cmd_stop && !fatal_error;
    assign trigger_count_enable = trigger_run_active;
    assign fragment_start_pulse = (fsm_state == S_XFER) && !fragment_started &&
                                  !abort_pending && !fatal_error;
    assign fragment_n_frames = active_n_frames[17:0];
    assign fragment_addr = fragment_addr_reg;
    assign fragment_index = fragment_index_reg;
    assign writer_halt_new = (fsm_state == S_XFER) &&
                             (abort_pending || fatal_error);
    assign packer_abort = writer_halt_new;

    // A STOP can finish in the very same cycle as the input command. Capture
    // its final frame count, then send the revised packer target one clock
    // LATER (packer.start has priority over its stop_target_valid input).
    // Validated configuration permits at most 131072 frames (18 bits).
    // Keep the public 32-bit count, but use an 18-bit increment/comparison
    // on the timing-critical capture/STOP path.
    assign next_frame_count18 = frames_captured[17:0] + {17'd0, frame_stored};
    assign next_frame_count = {14'd0, next_frame_count18};
    assign full_frame_count = (frames_captured[17:0] >= active_n_frames[17:0]);
    assign stop_target_valid = (fsm_state == S_XFER) &&
                               stop_target_pending && fragment_started &&
                               !abort_pending && !fatal_error;
    assign stop_target_frames = frames_captured[17:0];
    assign status_stop_pending = stop_pending;
    assign status_trigger_latched = trigger_seen;
    assign status_capture_complete = (fsm_state == S_XFER) &&
                                     (full_frame_count || stop_boundary_seen);
    assign status_busy = validating || (fsm_state == S_FILL) ||
                         (fsm_state == S_WAIT) || (fsm_state == S_XFER) ||
                         (fsm_state == S_AFTER);
    assign fragment_complete_pulse = (fsm_state == S_XFER) &&
                    fragment_started && writer_done && !abort_pending &&
                    !fatal_error && !stop_early &&
                    (frames_captured[17:0] >= active_n_frames[17:0]);
    // Controlled one-shot FIFO flush, only after master has completed/drained.
    assign fifo_flush = ((fsm_state == S_AFTER) || (fsm_state == S_ERROR)) &&
                        !flush_issued;

    always_ff @(posedge clk) begin
        if (rst) begin
            fsm_state <= S_IDLE;
            validating <= 1'b0;
            sync_issued <= 1'b0;
            start_cfg_pending <= 1'b0;
            fragment_started <= 1'b0;
            abort_pending <= 1'b0;
            stop_pending <= 1'b0;
            stop_boundary_seen <= 1'b0;
            stop_target_pending <= 1'b0;
            stop_early <= 1'b0;
            trigger_seen <= 1'b0;
            flush_issued <= 1'b0;
            flush_wait <= 2'd0;
            error_cleanup_done <= 1'b0;
            frames_captured <= 32'd0;
            run_fragments_completed <= 32'd0;
            active_fragment_bytes <= 32'd0;
            fragment_addr_reg <= 32'd0;
            fragment_index_reg <= 32'd0;
            last_fragment_addr <= 32'd0;
            last_fragment_frames <= 32'd0;
            last_fragment_size <= 32'd0;
            last_fragment_status <= 32'd0;
        end else begin
            case (fsm_state)
                S_IDLE: begin
                    if (cmd_stop)
                        validating <= 1'b0;
                    else if (guard_check_req)
                        validating <= 1'b1;
                    else if (validating && guard_check_done) begin
                        validating <= 1'b0;
                        if (guard_check_ok) begin
                            fsm_state <= S_FILL;
                            run_fragments_completed <= 32'd0;
                            frames_captured <= 32'd0;
                            active_fragment_bytes <= guard_fragment_bytes;
                            // Do NOT read active_mem_addr here: its new value
                            // is written by axi_lite_regs on this SAME edge.
                            start_cfg_pending <= 1'b1;
                            fragment_index_reg <= 32'd0;
                            sync_issued <= 1'b0;
                            stop_pending <= 1'b0;
                            stop_boundary_seen <= 1'b0;
                            abort_pending <= 1'b0;
                            trigger_seen <= 1'b0;
                            fragment_started <= 1'b0;
                            stop_target_pending <= 1'b0;
                            stop_early <= 1'b0;
                        end
                    end
                end

                S_FILL: begin
                    if (start_cfg_pending) begin
                        // AXI-Lite ACTIVE snapshot is now visible and stable.
                        fragment_addr_reg <= active_mem_addr;
                        start_cfg_pending <= 1'b0;
                    end
                    if (fatal_error) begin
                        fsm_state <= S_ERROR;
                        flush_issued <= 1'b0;
                        error_cleanup_done <= 1'b0;
                    end else begin
                        if (frame_sync_request)
                            sync_issued <= 1'b1;
                        if (cmd_stop)
                            stop_pending <= 1'b1;
                        if (capture_stopped && (stop_pending || cmd_stop)) begin
                            stop_boundary_seen <= 1'b1;
                            fsm_state <= S_AFTER;
                            flush_issued <= 1'b0;
                            flush_wait <= 2'd0;
                        end else if (!stop_pending && !cmd_stop && sync_issued &&
                                     frame_sync_ready && fifo_ready &&
                                     (fifo_complete_frames >= active_n_prev_frames[7:0]))
                            fsm_state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (fatal_error) begin
                        fsm_state <= S_ERROR;
                        flush_issued <= 1'b0;
                        error_cleanup_done <= 1'b0;
                    end else begin
                        if (cmd_stop)
                            stop_pending <= 1'b1;
                        if (capture_stopped && (stop_pending || cmd_stop)) begin
                            stop_boundary_seen <= 1'b1;
                            fsm_state <= S_AFTER;
                            flush_issued <= 1'b0;
                            flush_wait <= 2'd0;
                        end else if (trigger_accept && !stop_pending && !cmd_stop) begin
                            fsm_state <= S_XFER;
                            trigger_seen <= 1'b1;
                            fragment_started <= 1'b0;
                            stop_target_pending <= 1'b0;
                            stop_boundary_seen <= 1'b0;
                            stop_early <= 1'b0;
                            stop_pending <= 1'b0;
                            abort_pending <= 1'b0;
                            frames_captured <= active_n_prev_frames +
                                               {31'd0, frame_stored};
                            fragment_index_reg <= run_fragments_completed;
                            // Address is maintained as an accumulator after
                            // each successful full fragment; no wide multiplier.
                        end
                    end
                end

                S_XFER: begin
                    if (!fragment_started && !fatal_error && !abort_pending)
                        fragment_started <= 1'b1;
                    if (frame_stored && !full_frame_count && !stop_boundary_seen &&
                        !abort_pending && !fatal_error)
                        frames_captured <= next_frame_count;
                    if (cmd_stop)
                        stop_pending <= 1'b1;
                    // Stop boundary bookkeeping does not need to depend on
                    // fatal_error: the fault path below has priority over
                    // writer_done and sets abort_pending on this same edge.
                    // Any STOP limit captured concurrently with a fatal fault
                    // is consequently ignored. Removing the fault condition
                    // from this register enable shortens the timing path
                    // writer.range_error -> FSM.stop_limit/CE.
                    if (capture_stopped && (stop_pending || cmd_stop) &&
                        !stop_boundary_seen && !abort_pending) begin
                        stop_boundary_seen <= 1'b1;
                        if (next_frame_count18 < active_n_frames[17:0]) begin
                            stop_early <= 1'b1;
                            stop_target_pending <= 1'b1;
                        end
                    end
                    if (stop_target_valid)
                        stop_target_pending <= 1'b0;

                    if (fatal_error || abort_pending) begin
                        abort_pending <= 1'b1;
                        // No new bursts after fault; wait for accepted AW/W/B.
                        if (!fragment_started || writer_drain_done) begin
                            last_fragment_addr <= fragment_addr_reg;
                            last_fragment_frames <= {14'd0, writer_frames_committed};
                            last_fragment_size <= 32'd0; // NOT verified on error
                            last_fragment_status <= 32'd3; // ERROR
                            fsm_state <= S_ERROR;
                            flush_issued <= 1'b0;
                            error_cleanup_done <= 1'b0;
                        end
                    end else if (fragment_started && writer_done) begin
                        last_fragment_addr <= fragment_addr_reg;
                        last_fragment_frames <= {14'd0, writer_frames_committed};
                        last_fragment_size <= writer_preamble_committed ?
                           (32'd128 + {14'd0, writer_frames_committed} * 32'd768) : 32'd0;
                        if (!stop_early && frames_captured[17:0] >= active_n_frames[17:0]) begin
                            last_fragment_status <= 32'd1; // COMPLETE
                            run_fragments_completed <= run_fragments_completed + 32'd1;
                            fragment_addr_reg <= fragment_addr_reg + active_fragment_bytes;
                        end else
                            last_fragment_status <= 32'd2; // STOPPED, partial
                        fsm_state <= S_AFTER;
                        flush_issued <= 1'b0;
                        flush_wait <= 2'd0;
                    end
                end

                S_AFTER: begin
                    if (!flush_issued) begin
                        flush_issued <= 1'b1;
                        flush_wait <= 2'd2;
                    end else if (flush_wait != 2'd0) begin
                        flush_wait <= flush_wait - 2'd1;
                    end else if (fifo_ready) begin
                        flush_issued <= 1'b0;
                        trigger_seen <= 1'b0;
                        stop_boundary_seen <= 1'b0;
                        stop_target_pending <= 1'b0;
                        fragment_started <= 1'b0;
                        frames_captured <= 32'd0;
                        if (stop_pending || stop_early) begin
                            fsm_state <= S_IDLE;
                            stop_pending <= 1'b0;
                        end else if (run_fragments_completed >= active_n_fragments) begin
                            fsm_state <= S_END;
                        end else begin
                            fsm_state <= S_FILL;
                            sync_issued <= 1'b0;
                        end
                    end
                end

                S_ERROR: begin
                    if (!flush_issued) begin
                        flush_issued <= 1'b1;
                        flush_wait <= 2'd2;
                    end else if (flush_wait != 2'd0) begin
                        flush_wait <= flush_wait - 2'd1;
                    end else if (fifo_ready) begin
                        error_cleanup_done <= 1'b1;
                        if (cmd_clear_error) begin
                            fsm_state <= S_IDLE;
                            stop_pending <= 1'b0;
                            stop_boundary_seen <= 1'b0;
                            stop_target_pending <= 1'b0;
                            fragment_started <= 1'b0;
                            abort_pending <= 1'b0;
                            trigger_seen <= 1'b0;
                            frames_captured <= 32'd0;
                            error_cleanup_done <= 1'b0;
                        end
                    end
                end

                S_END: begin
                    if (cmd_stop) begin
                        fsm_state <= S_IDLE;
                        stop_pending <= 1'b0;
                        trigger_seen <= 1'b0;
                    end
                end
                default: fsm_state <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst) begin
            if (run_start_pulse && (!guard_check_ok || !guard_check_done))
                $fatal(1,"FSM start without successful guard result");
            if (fragment_complete_pulse && (writer_frames_committed != fragment_n_frames))
                $fatal(1,"FSM complete fragment but wrong committed frame count");
            if (stop_target_valid && stop_target_frames > fragment_n_frames)
                $fatal(1,"FSM STOP target exceeds fragment length");
        end
    end
`endif
endmodule
`default_nettype wire
