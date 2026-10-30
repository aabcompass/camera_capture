`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for frame_input_ctrl.sv.
// Run e.g.: iverilog -g2012 -s tb_frame_input_ctrl -o tb.vvp \
//              rtl/frame_input_ctrl.sv sim/tb_frame_input_ctrl.sv
//           vvp tb.vvp
module tb_frame_input_ctrl;
    localparam logic [6:0] WR    = 7'b0000001;
    localparam logic [6:0] START = 7'b0000010;
    localparam logic [6:0] DONE  = 7'b0000100;
    localparam logic [6:0] CAP   = 7'b0001000;
    localparam logic [6:0] STOP  = 7'b0010000;
    localparam logic [6:0] FMT   = 7'b0100000;
    localparam logic [6:0] FAIL  = 7'b1000000;

    logic clk = 1'b0;
    always #2.5 clk = ~clk; // 200 MHz

    logic rst;
    logic [63:0] s_axis_tdata;
    logic s_axis_tvalid;
    logic s_axis_tlast;
    wire  s_axis_tready;
    logic sync_request;
    logic capture_enable;
    logic stop_request;
    wire [64:0] fifo_wr_data;
    wire fifo_wr_req;
    logic fifo_wr_accepted;
    wire frame_start;
    wire frame_done;
    wire captured_frame_done;
    wire frame_active;
    wire [6:0] frame_word_index;
    wire frame_sync_ready;
    wire capture_stopped;
    wire frame_format_error;
    wire fifo_write_error;
    wire [63:0] frame_sequence;

    int checks;
    int wr_count;
    int cap_count;
    int done_count;
    int stop_count;
    int fmt_count;
    int fail_count;
    int test_count;

    frame_input_ctrl dut (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .sync_request(sync_request),
        .capture_enable(capture_enable),
        .stop_request(stop_request),
        .fifo_wr_data(fifo_wr_data),
        .fifo_wr_req(fifo_wr_req),
        .fifo_wr_accepted(fifo_wr_accepted),
        .frame_start(frame_start),
        .frame_done(frame_done),
        .captured_frame_done(captured_frame_done),
        .frame_active(frame_active),
        .frame_word_index(frame_word_index),
        .frame_sync_ready(frame_sync_ready),
        .capture_stopped(capture_stopped),
        .frame_format_error(frame_format_error),
        .fifo_write_error(fifo_write_error),
        .frame_sequence(frame_sequence)
    );

    function automatic [63:0] word_data(input int fid, input int wi);
        word_data = {fid[31:0], wi[31:0]};
    endfunction

    task automatic reset_dut;
        @(negedge clk);
        rst = 1'b1;
        s_axis_tdata = 64'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        sync_request = 1'b0;
        capture_enable = 1'b0;
        stop_request = 1'b0;
        fifo_wr_accepted = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        checks = 0;
        wr_count = 0;
        cap_count = 0;
        done_count = 0;
        stop_count = 0;
        fmt_count = 0;
        fail_count = 0;
    endtask

    // The expected flag mask is {FAIL,FMT,STOP,CAP,DONE,START,WR}.
    // expected_index=-1 skips word-index verification for this cycle.
    task automatic step(
        input logic valid_i,
        input logic last_i,
        input logic capture_i,
        input logic sync_i,
        input logic stop_i,
        input logic accepted_i,
        input logic [63:0] data_i,
        input logic [6:0] expected_flags,
        input integer expected_index
    );
        logic [6:0] actual_flags;
        @(negedge clk);
        s_axis_tvalid = valid_i;
        s_axis_tlast = last_i;
        s_axis_tdata = data_i;
        capture_enable = capture_i;
        sync_request = sync_i;
        stop_request = stop_i;
        fifo_wr_accepted = accepted_i;
        #1;
        actual_flags = {fifo_write_error, frame_format_error,
                        capture_stopped, captured_frame_done,
                        frame_done, frame_start, fifo_wr_req};
        if (actual_flags !== expected_flags) begin
            $error("t=%0t expected flags=%07b actual=%07b idx=%0d data=%h",
                   $time, expected_flags, actual_flags, frame_word_index, data_i);
            $fatal(1, "Flag mismatch");
        end
        if (s_axis_tready !== 1'b1)
            $fatal(1,"TREADY must always be 1");
        if (fifo_wr_req && fifo_wr_data !== {last_i, data_i})
            $fatal(1,"Wrong FIFO data/TLAST");
        if ((expected_index >= 0) &&
            (frame_word_index !== expected_index[6:0]))
            $fatal(1,"Wrong word index: exp=%0d got=%0d",
                   expected_index, frame_word_index);
        if (fifo_wr_req && !valid_i)
            $fatal(1,"FIFO write while TVALID=0");
        if (captured_frame_done && !frame_done)
            $fatal(1,"Captured frame without frame_done");
        checks++;
        if (fifo_wr_req && accepted_i) wr_count++;
        if (captured_frame_done) cap_count++;
        if (frame_done) done_count++;
        if (capture_stopped) stop_count++;
        if (frame_format_error) fmt_count++;
        if (fifo_write_error) fail_count++;
        @(posedge clk);
        #1;
    endtask

    // First sync edge is discarded; the following valid TLAST aligns us.
    task automatic align_input;
        step(1, 0, 1, 1, 0, 1, 64'hABC, 0, -1);
        if (frame_sync_ready !== 1'b0)
            $fatal(1,"sync_request must cause UNSYNCED");
        step(1, 0, 1, 0, 0, 1, 64'hABD, 0, -1);
        step(1, 1, 1, 0, 0, 1, 64'hABE, 0, -1);
        if (frame_sync_ready !== 1'b1)
            $fatal(1,"Expected alignment after valid TLAST");
    endtask

    task automatic send_frame(
        input int fid,
        input bit capture_i,
        input int gap_period,
        input int refuse_word, // -1 for none
        input int stop_word    // -1 for none
    );
        logic [6:0] flags;
        bit granted;
        for (int i = 0; i < 96; i++) begin
            if (gap_period > 0 && i > 0 && ((i % gap_period) == 0)) begin
                step(0, 1, capture_i, 0, 0, 1, 64'h0, 0, i);
                if (!frame_active)
                    $fatal(1,"TVALID pause must not end frame");
            end
            granted = (i != refuse_word);
            flags = 0;
            if (capture_i) flags |= WR;
            if (i == 0) flags |= START;
            if (i == 95) begin
                flags |= DONE;
                if (capture_i && refuse_word == -1) flags |= CAP;
                if (stop_word >= 0) flags |= STOP;
            end
            if (capture_i && !granted) flags |= FAIL;
            step(1, (i == 95), capture_i, 0, (i == stop_word),
                 granted, word_data(fid, i), flags, i);
        end
    endtask

    task automatic expect_counts(
        input int exp_writes,
        input int exp_done,
        input int exp_captured,
        input int exp_stops,
        input int exp_format_errors,
        input int exp_write_errors
    );
        if (wr_count != exp_writes || done_count != exp_done ||
            cap_count != exp_captured || stop_count != exp_stops ||
            fmt_count != exp_format_errors || fail_count != exp_write_errors) begin
            $fatal(1, "Counts mismatch: wr=%0d/%0d done=%0d/%0d cap=%0d/%0d stop=%0d/%0d fmt=%0d/%0d fail=%0d/%0d",
                   wr_count,exp_writes, done_count,exp_done, cap_count,exp_captured,
                   stop_count,exp_stops,fmt_count,exp_format_errors,
                   fail_count,exp_write_errors);
        end
    endtask

    initial begin
        rst = 1;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        sync_request = 0;
        capture_enable = 0;
        stop_request = 0;
        fifo_wr_accepted = 1;
        test_count = 0;

        $display("[TEST] normal frames, gaps and continuous full-rate frames");
        reset_dut();
        align_input();
        send_frame(1, 1, 7, -1, -1);
        send_frame(2, 1, 0, -1, -1);
        for (int n=0; n<128; n++) send_frame(100+n, 1, 0, -1, -1);
        expect_counts(130*96, 130, 130, 0, 0, 0);
        if (frame_sequence !== 64'd130) $fatal(1,"Sequence mismatch");
        test_count++;

        $display("[TEST] capture disabled vs enabled");
        reset_dut();
        align_input();
        send_frame(1, 0, 0, -1, -1);
        send_frame(2, 1, 0, -1, -1);
        expect_counts(96, 2, 1, 0, 0, 0);
        if (frame_sequence !== 64'd2) $fatal(1,"Sequence mismatch");
        test_count++;

        $display("[TEST] FIFO grant refused inside an otherwise valid frame");
        reset_dut();
        align_input();
        send_frame(1, 1, 0, 40, -1);
        send_frame(2, 1, 0, -1, -1);
        expect_counts(191, 2, 1, 0, 0, 1);
        test_count++;

        $display("[TEST] early TLAST and recovery on the next frame");
        reset_dut();
        align_input();
        for (int i=0; i<9; i++) begin
            logic [6:0] f;
            f = WR;
            if (i==0) f |= START;
            if (i==8) f |= FMT;
            step(1, (i==8), 1, 0, 0, 1, word_data(10,i), f, i);
        end
        send_frame(11, 1, 0, -1, -1);
        expect_counts(105, 1, 1, 0, 1, 0);
        if (frame_sequence !== 64'd1) $fatal(1,"Sequence after early TLAST");
        test_count++;

        $display("[TEST] missing TLAST on word 95, discard until next TLAST");
        reset_dut();
        align_input();
        for (int i=0; i<96; i++) begin
            logic [6:0] f;
            f = WR;
            if (i==0) f |= START;
            if (i==95) f |= FMT;
            step(1, 0, 1, 0, 0, 1, word_data(5,i), f, i);
        end
        if (frame_sync_ready !== 1'b0) $fatal(1,"Missing TLAST must unsync");
        for (int i=0; i<5; i++)
            step(1, (i==4), 1, 0, 0, 1, word_data(6,i), 0, -1);
        send_frame(7, 1, 0, -1, -1);
        expect_counts(192, 1, 1, 0, 1, 0);
        test_count++;

        $display("[TEST] STOP mid-frame, then writes remain halted");
        reset_dut();
        align_input();
        send_frame(1, 1, 11, -1, 37);
        send_frame(2, 0, 0, -1, -1); // camera runs, but data discarded
        expect_counts(96, 2, 1, 1, 0, 0);
        // Re-arm only through sync_request, not by setting capture_enable.
        step(0, 0, 1, 1, 0, 1, 0, 0, -1);
        step(1, 1, 1, 0, 0, 1, 64'hF00, 0, -1);
        send_frame(3, 1, 0, -1, -1);
        expect_counts(192, 3, 2, 1, 0, 0);
        if (frame_sequence !== 64'd1) $fatal(1,"Re-sync resets frame sequence");
        test_count++;

        $display("[TEST] STOP between frames without new camera word");
        reset_dut();
        align_input();
        send_frame(1, 1, 0, -1, -1);
        step(0, 0, 1, 0, 1, 1, 0, STOP, 0);
        send_frame(2, 0, 0, -1, -1);
        expect_counts(96, 2, 1, 1, 0, 0);
        test_count++;

        $display("[TEST] STOP on word 0 and on word 95");
        reset_dut();
        align_input();
        send_frame(1, 1, 0, -1, 0);
        expect_counts(96, 1, 1, 1, 0, 0);
        reset_dut();
        align_input();
        send_frame(2, 1, 0, -1, 95);
        expect_counts(96, 1, 1, 1, 0, 0);
        test_count++;

        $display("[TEST] START/sync while a camera frame is already in progress");
        reset_dut();
        step(1, 0, 1, 1, 0, 1, 64'h123, 0, -1);
        for (int i=0; i<40; i++)
            step(1, (i==39), 1, 0, 0, 1, word_data(55,i), 0, -1);
        send_frame(56, 1, 0, -1, -1);
        expect_counts(96, 1, 1, 0, 0, 0);
        test_count++;

        $display("PASS: %0d test groups, %0d checks in last group", test_count, checks);
        $finish;
    end

    initial begin
        #2000000; // 2ms in simulation; independent deadlock watchdog
        $fatal(1, "TB global timeout");
    end
endmodule
`default_nettype wire
