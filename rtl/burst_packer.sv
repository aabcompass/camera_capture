// Camera Data Capture IP — burst_packer, interface contract v1.0.
// 200 MHz single clock. Two 16x64-bit ping-pong banks.
//   * One 128-byte preamble followed by six 128-byte bursts per frame.
//   * Input: one 65-bit FWFT FIFO word {TLAST,DATA}, VALID/READY handshake.
//   * Output: a burst descriptor (valid/ready), then exactly 16 W beats
//     (valid/ready). The writer MUST NOT consume W data before accepting the
//     descriptor for that burst. All data remain stable under backpressure.
//   * burst_done means data accepted on W channel, NOT a successful BRESP.
//   * Early STOP: main FSM sends revised final frame count AFTER deciding
//     capture boundary. No truncation within a frame is permitted.
//   * No AXI signalling/BRESP accounting in this module.
`default_nettype none
module burst_packer (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         abort,                // stop fetching; flush needs top-level coordination
    input  wire [17:0]  n_frames,
    input  wire [31:0]  header_id,
    input  wire [31:0]  fragment_index,
    input  wire [63:0]  timestamp,
    input  wire [63:0]  trigger_data,
    input  wire [255:0] aux_data,
    input  wire         stop_target_valid,
    input  wire [17:0]  stop_target_frames,

    input  wire [64:0]  in_data,
    input  wire         in_valid,
    output wire         in_ready,

    // Writer accepts each completed 16-word burst descriptor first.
    output wire         burst_valid,
    input  wire         burst_ready,
    output wire         burst_is_preamble,
    output wire         burst_ends_frame,
    output wire [3:0]   burst_word_count_minus_one, // always 15

    // Writer consumes sixteen words after a descriptor handshake.
    output wire [63:0]  w_data,
    output wire         w_valid,
    input  wire         w_ready,
    output wire         w_last,

    output logic        active,
    output logic        packer_done,          // held high until next start/reset
    output logic        format_error,         // sticky until start/reset
    output logic        target_error,         // stop count too small or too large
    output logic [17:0] frames_packed,        // full frames pulled from FIFO
    output logic [17:0] frames_sent,          // full frames accepted on W channel
    output logic [31:0] bursts_sent           // includes the preamble
);
    localparam logic [1:0] SEND_WAIT = 2'd0;
    localparam logic [1:0] SEND_WORD = 2'd1;
    logic [1:0] send_state;

    // Both banks are implemented as distributed registers (only 256 bytes).
    logic [63:0] bank [0:1][0:15];
    logic        bank_full [0:1];
    logic        bank_is_preamble [0:1];
    logic        bank_ends_frame [0:1];
    logic        fill_bank, send_bank;
    logic [3:0]  fill_pos, send_pos;
    logic [6:0]  frame_word_idx;
    logic [17:0] effective_target;
    logic        preamble_sent;
    logic        abort_latched;

    wire accept_input = in_valid && in_ready;
    wire accept_burst = burst_valid && burst_ready;
    wire accept_word = w_valid && w_ready;
    wire last_word = (send_pos == 4'd15);
    wire frame_word_last = (frame_word_idx == 7'd95);
    wire target_reached = (frames_packed >= effective_target);

    assign in_ready = active && !abort_latched && !format_error &&
                      !target_error && !packer_done &&
                      !target_reached && !bank_full[fill_bank];
    assign burst_valid = active && (send_state == SEND_WAIT) &&
                         bank_full[send_bank];
    assign burst_is_preamble = bank_is_preamble[send_bank];
    assign burst_ends_frame  = bank_ends_frame[send_bank];
    assign burst_word_count_minus_one = 4'd15;
    assign w_valid = active && (send_state == SEND_WORD);
    assign w_data  = bank[send_bank][send_pos];
    assign w_last  = w_valid && last_word;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            packer_done <= 1'b0;
            format_error <= 1'b0;
            target_error <= 1'b0;
            frames_packed <= 18'd0;
            frames_sent <= 18'd0;
            bursts_sent <= 32'd0;
            effective_target <= 18'd0;
            abort_latched <= 1'b0;
            preamble_sent <= 1'b0;
            fill_bank <= 1'b0;
            send_bank <= 1'b0;
            fill_pos <= 4'd0;
            send_pos <= 4'd0;
            frame_word_idx <= 7'd0;
            send_state <= SEND_WAIT;
            bank_full[0] <= 1'b0;
            bank_full[1] <= 1'b0;
            bank_is_preamble[0] <= 1'b0;
            bank_is_preamble[1] <= 1'b0;
            bank_ends_frame[0] <= 1'b0;
            bank_ends_frame[1] <= 1'b0;
        end else if (start) begin
            // The caller must start only after the previous run is drained.
            // The preamble occupies bank0 immediately; bank1 can then fill.
            active <= 1'b1;
            packer_done <= 1'b0;
            format_error <= 1'b0;
            target_error <= 1'b0;
            frames_packed <= 18'd0;
            frames_sent <= 18'd0;
            bursts_sent <= 32'd0;
            effective_target <= n_frames;
            abort_latched <= 1'b0;
            preamble_sent <= 1'b0;
            fill_bank <= 1'b1;
            send_bank <= 1'b0;
            fill_pos <= 4'd0;
            send_pos <= 4'd0;
            frame_word_idx <= 7'd0;
            send_state <= SEND_WAIT;
            bank_full[0] <= 1'b1;
            bank_full[1] <= 1'b0;
            bank_is_preamble[0] <= 1'b1;
            bank_is_preamble[1] <= 1'b0;
            bank_ends_frame[0] <= 1'b0;
            bank_ends_frame[1] <= 1'b0;
            bank[0][0] <= {fragment_index, header_id};
            bank[0][1] <= timestamp;
            bank[0][2] <= trigger_data;
            for (i = 0; i < 4; i = i+1)
                bank[0][i+3] <= aux_data[i*64 +: 64];
            for (i = 7; i < 16; i = i+1)
                bank[0][i] <= 64'h1234567812345678;
        end else if (active) begin
            if (abort)
                abort_latched <= 1'b1;

            // Applied at the capture boundary; counts include pretrigger.
            // Must not be issued with a count smaller than frames already
            // extracted from FIFO (would already have leaked extra data).
            if (stop_target_valid) begin
                if ((stop_target_frames > effective_target) ||
                    (stop_target_frames < frames_packed))
                    target_error <= 1'b1;
                else
                    effective_target <= stop_target_frames;
            end

            if (accept_input) begin
                bank[fill_bank][fill_pos] <= in_data[63:0];
                if (in_data[64] != frame_word_last)
                    format_error <= 1'b1;
                if (frame_word_last) begin
                    frame_word_idx <= 7'd0;
                    frames_packed <= frames_packed + 18'd1;
                end else
                    frame_word_idx <= frame_word_idx + 7'd1;

                if (fill_pos == 4'd15) begin
                    bank_full[fill_bank] <= 1'b1;
                    bank_is_preamble[fill_bank] <= 1'b0;
                    bank_ends_frame[fill_bank] <= frame_word_last;
                    fill_bank <= ~fill_bank;
                    fill_pos <= 4'd0;
                end else
                    fill_pos <= fill_pos + 4'd1;
            end

            if (accept_burst) begin
                send_state <= SEND_WORD;
                send_pos <= 4'd0;
            end
            if (accept_word) begin
                if (last_word) begin
                    bank_full[send_bank] <= 1'b0;
                    bursts_sent <= bursts_sent + 32'd1;
                    if (bank_is_preamble[send_bank])
                        preamble_sent <= 1'b1;
                    if (bank_ends_frame[send_bank])
                        frames_sent <= frames_sent + 18'd1;
                    send_bank <= ~send_bank;
                    send_pos <= 4'd0;
                    send_state <= SEND_WAIT;
                end else begin
                    send_pos <= send_pos + 4'd1;
                end
            end

            // This reports only 'data sent to W'. Actual DDR completion
            // requires successful BRESP tracking inside axi3_write_master.
            if (preamble_sent && (frames_sent == effective_target) &&
                (frames_packed == effective_target) &&
                !bank_full[0] && !bank_full[1] &&
                (send_state == SEND_WAIT))
                packer_done <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && start && active && !packer_done)
            $fatal(1, "burst_packer: start while active (caller must drain/reset)");
        if (!rst && active && !start && accept_word &&
            (send_state != SEND_WORD))
            $fatal(1, "burst_packer: W word without descriptor");
        if (!rst && active && !start && accept_input && (fill_pos == 4'd15) &&
            bank_full[~fill_bank]) begin
            // Other bank may be draining, in which case backpressure follows.
        end
    end
`endif
endmodule
`default_nettype wire
