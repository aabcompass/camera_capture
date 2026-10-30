// Camera Data Capture IP: 100-frame sliding FIFO controller.
// Single 200 MHz domain. Clock-edge events use SAME-CYCLE handshakes.
// The controller stores 65-bit words {TLAST, DATA} and counts only fully
// captured frames. DROP always consumes a whole oldest frame (up to TLAST).
// On trigger, the pre-trigger complete-frame count is frozen before the
// current edge's frame completion: the trigger frame becomes post-trigger.
// A DROP already in flight MUST finish, even if the trigger arrives now.
//
// Interface to frame_input_ctrl:
//   frame_input_ctrl.fifo_wr_req   -> write_req
//   frame_input_ctrl.fifo_wr_data  -> write_data
//   fifo_wr_accepted              <- write_accepted (same-edge grant)
//   captured_frame_done           -> frame_stored (same-edge pulse)
// FIFO drops do not consume a current incomplete frame.
`default_nettype none
module capture_fifo_ctrl #(
    parameter integer FRAME_WORDS = 96,
    parameter integer LOGICAL_DEPTH = 9600,
    parameter integer PHYSICAL_DEPTH = 16384,
    parameter bit USE_XPM = 1'b1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        fifo_flush,
    output wire        fifo_ready,

    input  wire [64:0] write_data,
    input  wire        write_req,
    output wire        write_accepted,
    input  wire        frame_stored,

    input  wire [6:0]  n_prev_frames,
    input  wire        drop_enable,
    input  wire        trigger_accept,
    input  wire        transfer_enable,

    output wire [64:0] read_data,
    output wire        read_valid,
    input  wire        read_ready,

    output logic [13:0] fifo_level_words,
    output logic [7:0]  complete_frames,
    output wire        logical_full,
    output wire        overflow_pulse,
    output logic       overflow_sticky,
    output logic       drop_active,
    output wire        drop_frame_done,
    output logic       triggered,
    output logic [7:0] drops_remaining,
    output wire        transfer_ready,
    output wire        popped_frame_done
);
    wire [64:0] stored_head;
    wire        stored_valid;
    wire        stored_can_write;
    wire        store_pop;
    wire        store_push;
    wire        drop_request;
    wire        drop_pop;
    wire        transfer_pop;
    wire        drop_tail;
    wire        transfer_tail;
    wire [7:0] surplus_pre_frames =
        (complete_frames > {1'b0, n_prev_frames}) ?
        (complete_frames - {1'b0, n_prev_frames}) : 8'd0;

    capture_fifo #(
        .WIDTH(65),
        .PHYSICAL_DEPTH(PHYSICAL_DEPTH),
        .USE_XPM(USE_XPM)
    ) u_storage (
        .clk(clk),
        .rst(rst),
        .flush(fifo_flush),
        .write_data(write_data),
        .write_en(store_push),
        .can_write(stored_can_write),
        .read_en(store_pop),
        .read_data(stored_head),
        .read_valid(stored_valid),
        .ready(fifo_ready)
    );

    // When drop_active=1 a started frame must be completely discarded.
    // With no trigger: maintain n_prev completed frames and the current
    // incomplete frame. After trigger: drop exactly the surplus PRE frames.
    assign drop_request = (triggered && (drops_remaining != 8'd0)) ||
                          (!triggered && drop_enable && !transfer_enable &&
                           (complete_frames > {1'b0, n_prev_frames}));

    assign drop_pop = stored_valid && drop_request;
    assign drop_tail = drop_pop && stored_head[64];

    // Triggered is a latch, not a pulse, so transfer gating remains valid
    // across gaps between completed frames.
    assign transfer_ready = fifo_ready && triggered &&
        (drops_remaining == 8'd0) && !drop_active;
    assign read_valid = transfer_enable && transfer_ready &&
                        (complete_frames != 8'd0) && stored_valid;
    assign read_data = stored_head;
    assign transfer_pop = read_valid && read_ready;
    assign transfer_tail = transfer_pop && stored_head[64];
    assign store_pop = drop_pop || transfer_pop;
    assign store_push = write_accepted;

    assign logical_full = (fifo_level_words >= LOGICAL_DEPTH);
    // Physical depth is greater than logical depth. If logical depth is
    // reached, a confirmed pop frees exactly one position on this edge.
    assign write_accepted = write_req && !rst && !fifo_flush &&
        stored_can_write && (!logical_full || store_pop);
    assign overflow_pulse = write_req && !write_accepted &&
                            !rst && !fifo_flush;
    assign drop_frame_done = drop_tail;
    assign popped_frame_done = transfer_tail;

    always_ff @(posedge clk) begin
        if (rst || fifo_flush) begin
            fifo_level_words <= 14'd0;
            complete_frames  <= 8'd0;
            overflow_sticky  <= 1'b0;
            drop_active      <= 1'b0;
            triggered        <= 1'b0;
            drops_remaining  <= 8'd0;
        end else begin
            if (overflow_pulse)
                overflow_sticky <= 1'b1;

            case ({store_push, store_pop})
                2'b10: fifo_level_words <= fifo_level_words + 14'd1;
                2'b01: fifo_level_words <= fifo_level_words - 14'd1;
                default: ;
            endcase

            case ({frame_stored, (drop_tail || transfer_tail)})
                2'b10: complete_frames <= complete_frames + 8'd1;
                2'b01: complete_frames <= complete_frames - 8'd1;
                default: ;
            endcase

            if (drop_pop)
                drop_active <= !drop_tail;

            if (trigger_accept && !triggered) begin
                triggered <= 1'b1;
                // complete_frames is PRE-edge state, excluding a newly
                // completed trigger frame on this very same clock edge.
                // Drop completion on the same edge is already consumed.
                drops_remaining <= surplus_pre_frames -
                                   (drop_tail ? 8'd1 : 8'd0);
            end else if (triggered && drop_tail) begin
                drops_remaining <= drops_remaining - 8'd1;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (FRAME_WORDS != 96 || LOGICAL_DEPTH != 9600)
            $fatal(1, "capture_fifo_ctrl v1 expects 96-word frames and 9600-word logical FIFO");
        if (PHYSICAL_DEPTH <= LOGICAL_DEPTH)
            $fatal(1, "physical depth must exceed logical depth");
    end
    always @(posedge clk) begin
        if (!rst && !fifo_flush && fifo_ready) begin
            if (frame_stored && !(write_accepted && write_data[64]))
                $fatal(1, "frame_stored must coincide with an accepted TLAST word");
            if (store_pop && !stored_valid)
                $fatal(1, "FIFO read without valid data");
            if (drop_tail && complete_frames == 0)
                $fatal(1, "DROP finished with no complete frame");
            if (transfer_tail && complete_frames == 0)
                $fatal(1, "TRANSFER finished with no complete frame");
            if (triggered && drop_tail && drops_remaining == 0)
                $fatal(1, "DROP finished after trigger despite zero remaining drops");
        end
    end
`endif
endmodule
`default_nettype wire
