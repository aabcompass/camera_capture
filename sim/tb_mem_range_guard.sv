`timescale 1ns/1ps
`default_nettype none
module tb_mem_range_guard;
    logic clk = 1'b0;
    always #2.5 clk = ~clk; // 200 MHz

    logic rst = 1'b1;
    logic check_req = 1'b0;
    logic [31:0] n_frames = 32'd2;
    logic [31:0] n_prev_frames = 32'd0;
    logic [31:0] n_fragments = 32'd1;
    logic [31:0] mem_addr = 32'h20000000;
    logic [31:0] mem_buffer_bytes = 32'd1664;
    logic periodic_enable = 1'b0;
    logic [31:0] int_trig_period = 32'd0;

    wire check_done, check_ok;
    wire [31:0] check_error_flags, fragment_bytes;
    wire [63:0] total_required_bytes, buffer_end_exclusive;

    mem_range_guard dut (.*);

    integer checks = 0;
    integer groups = 0;
    task automatic assert_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("CHECK FAILED: %s", message);
                $display("  ok=%b done=%b flags=%08h fragment=%0d total=%0d end=%016h",
                    check_ok, check_done, check_error_flags, fragment_bytes,
                    total_required_bytes, buffer_end_exclusive);
                $fatal(1, "mem_range_guard check failed");
            end
        end
    endtask

    task automatic defaults;
        begin
            n_frames = 32'd2;
            n_prev_frames = 32'd0;
            n_fragments = 32'd1;
            mem_addr = 32'h20000000;
            mem_buffer_bytes = 32'd1664; // 128 + 2*768
            periodic_enable = 1'b0;
            int_trig_period = 32'd0;
        end
    endtask

    task automatic check_now;
        begin
            @(negedge clk);
            check_req = 1'b1;
            @(posedge clk);
            #1;
            assert_true(!check_done, "check_done must wait for calculation");
            @(negedge clk);
            check_req = 1'b0;
            begin : wait_check_done
                integer cycles;
                cycles = 0;
                while (!check_done && cycles < 20) begin
                    @(posedge clk);
                    #1;
                    cycles = cycles + 1;
                end
                assert_true(check_done, "check_done must arrive within 20 clocks");
            end
            @(posedge clk);
            #1;
            assert_true(!check_done, "check_done is a one-clock pulse");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(posedge clk);
        #1;
        $display("[TEST] minimum legal configuration, exact buffer size");
        groups = groups + 1;
        defaults();
        check_now();
        assert_true(check_ok, "minimum config valid");
        assert_true(check_error_flags == 32'd0, "no errors");
        assert_true(fragment_bytes == 32'd1664, "fragment size includes preamble");
        assert_true(total_required_bytes == 64'd1664, "one fragment total");
        assert_true(buffer_end_exclusive == 64'h0000000020000680, "exclusive region end");

        $display("[TEST] maximum n_frames and pretrigger, multiple fragments");
        groups = groups + 1;
        defaults();
        n_frames = 32'd131072;
        n_prev_frames = 32'd64;
        n_fragments = 32'd2;
        mem_buffer_bytes = 32'd201326848;
        check_now();
        assert_true(check_ok, "maximum frame count valid");
        assert_true(fragment_bytes == 32'd100663424, "maximum fragment is 96 MiB + 128");
        assert_true(total_required_bytes == 64'd201326848, "two fragments exact fit");

        $display("[TEST] n_fragments=0 must be rejected");
        groups = groups + 1;
        defaults();
        n_fragments = 32'd0;
        check_now();
        assert_true(!check_ok, "zero fragments rejected");
        assert_true(check_error_flags[6], "INVALID_N_FRAGMENTS bit");

        $display("[TEST] invalid n_frames (0,1,131073)");
        groups = groups + 1;
        defaults();
        n_frames = 32'd0;
        check_now();
        assert_true(!check_ok && check_error_flags[4], "zero frames rejected");
        n_frames = 32'd1;
        check_now();
        assert_true(!check_ok && check_error_flags[4], "one frame rejected");
        n_frames = 32'd131073;
        check_now();
        assert_true(!check_ok && check_error_flags[4], "too many frames rejected");

        $display("[TEST] invalid n_prev_frames and empty post-trigger segment");
        groups = groups + 1;
        defaults();
        n_prev_frames = 32'd65;
        check_now();
        assert_true(!check_ok && check_error_flags[5], "pretrigger > 64 rejected");
        n_prev_frames = 32'd2;
        check_now();
        assert_true(!check_ok && check_error_flags[5], "n_prev >= n_frames rejected");
        n_prev_frames = 32'd1;
        check_now();
        assert_true(check_ok, "n_frames=2 n_prev=1 accepted");

        $display("[TEST] address 128-byte alignment");
        groups = groups + 1;
        defaults();
        mem_addr = 32'h20000040;
        check_now();
        assert_true(!check_ok && check_error_flags[7], "unaligned base rejected");

        $display("[TEST] buffer size zero and smaller than required");
        groups = groups + 1;
        defaults();
        mem_buffer_bytes = 32'd0;
        check_now();
        assert_true(!check_ok && check_error_flags[9], "zero buffer rejected");
        mem_buffer_bytes = 32'd1663;
        check_now();
        assert_true(!check_ok && check_error_flags[9], "one byte too small rejected");

        $display("[TEST] 32-bit region end overflow vs exactly 4 GiB");
        groups = groups + 1;
        defaults();
        mem_addr = 32'hFFFFF980; // 4 GiB - 1664, aligned to 128 B
        mem_buffer_bytes = 32'd1664;
        check_now();
        assert_true(check_ok, "exclusive end exactly 4 GiB permitted");
        assert_true(buffer_end_exclusive == 64'h0000000100000000,
                    "exclusive end exactly 2^32");
        mem_buffer_bytes = 32'd1792;
        check_now();
        assert_true(!check_ok && check_error_flags[10], "past 4 GiB rejected");

        $display("[TEST] internal periodic trigger period validated only if enabled");
        groups = groups + 1;
        defaults();
        periodic_enable = 1'b1;
        int_trig_period = 32'd0;
        check_now();
        assert_true(!check_ok && check_error_flags[11], "enabled period 0 rejected");
        int_trig_period = 32'd1;
        check_now();
        assert_true(check_ok, "enabled period 1 accepted");
        int_trig_period = 32'd0;
        periodic_enable = 1'b0;
        check_now();
        assert_true(check_ok, "disabled period 0 accepted");

        $display("[TEST] huge total size cannot wrap and accidentally pass");
        groups = groups + 1;
        defaults();
        n_frames = 32'd131072;
        n_prev_frames = 32'd64;
        n_fragments = 32'hFFFFFFFF;
        mem_buffer_bytes = 32'hFFFFFFFF;
        check_now();
        assert_true(!check_ok && check_error_flags[9], "huge request rejected");
        assert_true(total_required_bytes == (64'd100663424 * 64'hFFFFFFFF),
                    "multiplication retained in 64 bits");
        assert_true(total_required_bytes > 64'hFFFFFFFF, "total > 32-bit memory size");

        $display("[TEST] status holds until next request and can be replaced");
        groups = groups + 1;
        defaults();
        check_now();
        assert_true(check_ok && check_error_flags == 0, "new request clears old error");
        n_fragments = 0;  // changing inputs alone must not change registered result
        repeat (4) @(posedge clk);
        #1;
        assert_true(check_ok && check_error_flags == 0, "result held without request");

        $display("[TEST] inputs are snapshotted on check_req; later changes ignored");
        groups = groups + 1;
        defaults();
        @(negedge clk);
        check_req = 1'b1;
        @(posedge clk);
        #1;
        assert_true(!check_done,"snapshot request is not yet done");
        @(negedge clk);
        check_req = 1'b0;
        n_frames = 32'd131072;
        n_fragments = 32'hFFFFFFFF;
        mem_buffer_bytes = 32'd0;
        begin : wait_snapshot
            integer cycles;
            cycles = 0;
            while (!check_done && cycles < 20) begin
                @(posedge clk); #1;
                cycles = cycles + 1;
            end
            assert_true(check_done,"snapshot calculation finished");
        end
        assert_true(check_ok,"snapshot uses original valid inputs");
        assert_true(fragment_bytes == 32'd1664,"snapshot used original frame count");
        assert_true(total_required_bytes == 64'd1664,"snapshot used original fragment count");
        assert_true(check_error_flags == 32'd0,"snapshot flags unaffected by input changes");
        @(posedge clk); #1;
        assert_true(!check_done,"snapshot done pulse cleared");

        $display("PASS: %0d groups, %0d checks", groups, checks);
        $finish;
    end
endmodule
`default_nettype wire
