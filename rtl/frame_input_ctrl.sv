// Camera Data Capture IP -- frame_input_ctrl
// Target: Xilinx XC7Z035, single 200 MHz clock domain.
//
// Contract:
//   * The camera is NOT backpressure-capable: S_AXIS_TREADY is always 1.
//   * fifo_wr_accepted is a SAME-CYCLE grant for fifo_wr_req, NOT a delayed ACK.
//     fifo_wr_req && fifo_wr_accepted means the 65-bit word is stored on clk.
//   * frame_start, frame_done, captured_frame_done, capture_stopped,
//     frame_format_error and fifo_write_error are combinational edge events:
//     downstream synchronous logic samples them on the SAME rising clock edge
//     as the associated S_AXIS data or command.
//   * sync_request is a one-cycle pulse with priority over other inputs.
//     The sync_request cycle is discarded. The next valid TLAST establishes
//     alignment; the following valid word is the first new frame word.
//   * STOP finishes the current frame; when coincident with word 0, it finishes
//     that newly begun frame. Once STOP is acknowledged, no writes resume until
//     sync_request. RESET > SYNC > STOP.
//   * A malformed captured frame may already be partially present in FIFO;
//     the system controller MUST discard it (e.g. flush in error recovery).
//
// This is a leaf module. The ORIGINAL full user technical specification must
// be included verbatim as a comment in camera_capture_top.sv when top RTL is
// implemented; it is intentionally not duplicated in this leaf module.

`default_nettype none
module frame_input_ctrl #(
    parameter integer FRAME_WORDS = 96
) (
    input  wire         clk,
    input  wire         rst,

    input  wire [63:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,

    input  wire         sync_request,
    input  wire         capture_enable,
    input  wire         stop_request,

    output wire [64:0]  fifo_wr_data,
    output logic        fifo_wr_req,
    input  wire         fifo_wr_accepted,

    output logic        frame_start,
    output logic        frame_done,
    output logic        captured_frame_done,
    output wire         frame_active,
    output wire [6:0]   frame_word_index,
    output wire         frame_sync_ready,
    output logic        capture_stopped,
    output logic        frame_format_error,
    output logic        fifo_write_error,
    output logic [63:0] frame_sequence
);
    // Constant frame format: 96 64-bit words, TLAST on word index 95.
    // The assertion also guards the 7-bit index range.
`ifndef SYNTHESIS
    initial begin
        if (FRAME_WORDS != 96)
            $fatal(1, "frame_input_ctrl requires FRAME_WORDS=96 in capture IP v1");
    end
`endif

    typedef enum logic [1:0] {
        UNSYNCED       = 2'd0,
        BETWEEN_FRAMES = 2'd1,
        IN_FRAME       = 2'd2
    } frame_state_t;

    frame_state_t state;
    logic [6:0] word_index;        // next expected word in the current frame
    logic       storing_frame;     // sampled when the first word arrives
    logic       frame_storage_ok;  // all previous words of frame were stored
    logic       stop_pending;
    logic       halted;            // latched after STOP until next sync
    logic       store_current;

    assign s_axis_tready   = 1'b1;
    assign fifo_wr_data    = {s_axis_tlast, s_axis_tdata};
    assign frame_active    = (state == IN_FRAME);
    assign frame_word_index = word_index;
    assign frame_sync_ready = (state != UNSYNCED);

    always_comb begin
        store_current       = 1'b0;
        fifo_wr_req         = 1'b0;
        frame_start         = 1'b0;
        frame_done          = 1'b0;
        captured_frame_done = 1'b0;
        capture_stopped     = 1'b0;
        frame_format_error = 1'b0;
        fifo_write_error    = 1'b0;

        if (!rst && !sync_request) begin
            case (state)
                UNSYNCED: begin
                    // No known frame boundary; incoming words are discarded.
                    if (stop_request && !halted)
                        capture_stopped = 1'b1;
                end

                BETWEEN_FRAMES: begin
                    if (s_axis_tvalid) begin
                        frame_start   = 1'b1;
                        store_current = capture_enable && !halted;
                        fifo_wr_req   = store_current;
                        if (s_axis_tlast) begin
                            // A one-word frame is always malformed.
                            frame_format_error = 1'b1;
                            if (stop_request && !halted)
                                capture_stopped = 1'b1;
                        end
                    end else if (stop_request && !halted) begin
                        // STOP between frames does not wait for another frame.
                        capture_stopped = 1'b1;
                    end
                end

                IN_FRAME: begin
                    if (s_axis_tvalid) begin
                        fifo_wr_req = storing_frame && !halted;
                        if (s_axis_tlast) begin
                            if (word_index == FRAME_WORDS-1) begin
                                frame_done = 1'b1;
                                captured_frame_done = storing_frame &&
                                    frame_storage_ok &&
                                    (!fifo_wr_req || fifo_wr_accepted);
                            end else begin
                                frame_format_error = 1'b1;
                            end
                            if ((stop_pending || stop_request) && !halted)
                                capture_stopped = 1'b1;
                        end else if (word_index == FRAME_WORDS-1) begin
                            // 96th word has no TLAST. Do not accept a 97th
                            // word as part of this frame: resynchronize.
                            frame_format_error = 1'b1;
                        end
                    end
                end
                default: ;
            endcase

            fifo_write_error = fifo_wr_req && !fifo_wr_accepted;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= UNSYNCED;
            word_index       <= 7'd0;
            storing_frame    <= 1'b0;
            frame_storage_ok <= 1'b1;
            stop_pending     <= 1'b0;
            halted           <= 1'b0;
            frame_sequence   <= 64'd0;
        end else if (sync_request) begin
            state            <= UNSYNCED;
            word_index       <= 7'd0;
            storing_frame    <= 1'b0;
            frame_storage_ok <= 1'b1;
            stop_pending     <= 1'b0;
            halted           <= 1'b0;
            frame_sequence   <= 64'd0;
        end else begin
            case (state)
                UNSYNCED: begin
                    // Discard through an actual valid TLAST, inclusive.
                    if (s_axis_tvalid && s_axis_tlast) begin
                        state      <= BETWEEN_FRAMES;
                        word_index <= 7'd0;
                    end
                    if (capture_stopped) begin
                        halted       <= 1'b1;
                        stop_pending <= 1'b0;
                    end
                end

                BETWEEN_FRAMES: begin
                    if (s_axis_tvalid) begin
                        if (s_axis_tlast) begin
                            // Invalid short frame: TLAST itself does give
                            // us an unambiguous next-frame boundary.
                            state            <= BETWEEN_FRAMES;
                            word_index       <= 7'd0;
                            storing_frame    <= 1'b0;
                            frame_storage_ok <= 1'b1;
                            stop_pending     <= 1'b0;
                            if (capture_stopped)
                                halted <= 1'b1;
                        end else begin
                            state            <= IN_FRAME;
                            word_index       <= 7'd1;
                            storing_frame    <= capture_enable && !halted;
                            frame_storage_ok <= !fifo_write_error;
                            if (stop_request && !halted)
                                stop_pending <= 1'b1;
                        end
                    end else if (capture_stopped) begin
                        halted       <= 1'b1;
                        stop_pending <= 1'b0;
                    end
                end

                IN_FRAME: begin
                    if (stop_request && !halted)
                        stop_pending <= 1'b1;

                    if (s_axis_tvalid) begin
                        if (fifo_write_error)
                            frame_storage_ok <= 1'b0;

                        if (s_axis_tlast) begin
                            if (frame_done)
                                frame_sequence <= frame_sequence + 64'd1;
                            state            <= BETWEEN_FRAMES;
                            word_index       <= 7'd0;
                            storing_frame    <= 1'b0;
                            frame_storage_ok <= 1'b1;
                            if (capture_stopped) begin
                                halted       <= 1'b1;
                                stop_pending <= 1'b0;
                            end
                        end else if (word_index == FRAME_WORDS-1) begin
                            // Missing TLAST. Drop data until the next
                            // valid TLAST can re-establish frame alignment.
                            state            <= UNSYNCED;
                            word_index       <= 7'd0;
                            storing_frame    <= 1'b0;
                            frame_storage_ok <= 1'b1;
                            stop_pending     <= 1'b0;
                        end else begin
                            word_index <= word_index + 7'd1;
                        end
                    end
                end
                default: begin
                    state <= UNSYNCED;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
