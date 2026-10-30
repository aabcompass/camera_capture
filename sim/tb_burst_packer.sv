`timescale 1ns/1ps
`default_nettype none
module tb_burst_packer;
    logic clk=0;
    always #2.5 clk=~clk;
    logic rst=1, start=0, abort=0;
    logic [17:0] n_frames=18'd2;
    logic [31:0] header_id=32'h44332211;
    logic [31:0] fragment_index=0;
    logic [63:0] timestamp=64'h0102030405060708;
    logic [63:0] trigger_data=64'h8877665544332211;
    logic [255:0] aux_data=256'h0;
    logic stop_target_valid=0;
    logic [17:0] stop_target_frames=0;
    logic [64:0] in_data=65'd0;
    logic in_valid=0;
    wire in_ready;
    wire burst_valid, burst_is_preamble, burst_ends_frame;
    wire [3:0] burst_word_count_minus_one;
    wire [63:0] w_data;
    wire w_valid, w_last;
    logic stall_descriptor=0, stall_data=0;
    wire burst_ready, w_ready;
    wire active, packer_done, format_error, target_error;
    wire [17:0] frames_packed, frames_sent;
    wire [31:0] bursts_sent;
    integer tick=0;
    integer groups=0;
    integer checks=0;
    integer desc_total=0;
    integer w_total=0;
    integer current_desc=-1;
    integer current_beat=0;
    logic desc_in_progress=0;
    logic hold_w_prev=0;
    logic [63:0] hold_w_data;
    logic hold_w_last;
    logic hold_req_prev=0;
    logic hold_req_preamble, hold_req_frame_end;

    assign burst_ready = !stall_descriptor && ((tick%7)!=0);
    assign w_ready = !stall_data && ((tick%5)!=0) && ((tick%11)!=0);

    burst_packer dut (.*);

    function automatic [63:0] science_word(input integer frame, input integer word);
        science_word = {32'habcd1000+frame, 32'(word)};
    endfunction
    function automatic [63:0] header_word(input integer idx);
        case(idx)
            0: header_word = {fragment_index, header_id};
            1: header_word = timestamp;
            2: header_word = trigger_data;
            3: header_word = aux_data[0+:64];
            4: header_word = aux_data[64+:64];
            5: header_word = aux_data[128+:64];
            6: header_word = aux_data[192+:64];
            default: header_word = 64'h1234567812345678;
        endcase
    endfunction

    always @(posedge clk) begin
        tick <= tick+1;
        if (rst || start) begin
            desc_total=0;
            w_total=0;
            current_desc=-1;
            current_beat=0;
            desc_in_progress=0;
            hold_w_prev=0;
            hold_req_prev=0;
        end else begin
            if (hold_w_prev && (!w_valid || w_data !== hold_w_data ||
                                w_last !== hold_w_last))
                $fatal(1,"W channel changed under backpressure");
            if (hold_req_prev && (!burst_valid ||
                                  burst_is_preamble !== hold_req_preamble ||
                                  burst_ends_frame !== hold_req_frame_end))
                $fatal(1,"descriptor changed under backpressure");
            hold_w_prev = w_valid && !w_ready;
            hold_w_data = w_data;
            hold_w_last = w_last;
            hold_req_prev = burst_valid && !burst_ready;
            hold_req_preamble = burst_is_preamble;
            hold_req_frame_end = burst_ends_frame;
            checks=checks+2;
            if (burst_valid && burst_ready) begin
                if (desc_in_progress)
                    $fatal(1,"new descriptor before previous WLAST");
                if (burst_word_count_minus_one !== 4'd15)
                    $fatal(1,"descriptor must be 16 words");
                if (burst_is_preamble !== (desc_total==0))
                    $fatal(1,"preamble flag on descriptor %0d",desc_total);
                if (burst_ends_frame !== ((desc_total>0) && (((desc_total-1)%6)==5)))
                    $fatal(1,"frame end flag on descriptor %0d",desc_total);
                current_desc=desc_total;
                desc_total=desc_total+1;
                current_beat=0;
                desc_in_progress=1;
                checks=checks+3;
            end
            if (w_valid && w_ready) begin : score_w
                logic [63:0] exp_word;
                integer sci_index;
                if (!desc_in_progress)
                    $fatal(1,"W beat without burst descriptor");
                if (current_beat!=((w_total)%16))
                    $fatal(1,"W beat index inconsistent");
                if (w_total<16)
                    exp_word=header_word(w_total);
                else begin
                    sci_index=w_total-16;
                    exp_word=science_word(sci_index/96,sci_index%96);
                end
                if (w_data !== exp_word)
                    $fatal(1,"word %0d mismatch: got %016h expected %016h",w_total,w_data,exp_word);
                if (w_last !== (current_beat==15))
                    $fatal(1,"WLAST mismatch beat %0d",current_beat);
                checks=checks+2;
                w_total=w_total+1;
                if (current_beat==15) begin
                    desc_in_progress=0;
                    current_beat=0;
                end else
                    current_beat=current_beat+1;
            end
        end
    end

    task automatic reset_dut;
        @(negedge clk);
        rst=1;
        in_valid=0;
        start=0;
        stop_target_valid=0;
        stall_descriptor=0;
        stall_data=0;
        repeat(4) @(negedge clk);
        rst=0;
        repeat(2) @(negedge clk);
    endtask
    task automatic launch(input integer count, input integer index);
        @(negedge clk);
        n_frames=18'(count);
        fragment_index=32'(index);
        start=1;
        @(negedge clk);
        start=0;
    endtask
    task automatic send_one(input integer f, input integer w,
                            input bit corrupt_tlast);
        @(negedge clk);
        in_valid=1;
        in_data={corrupt_tlast,science_word(f,w)};
        // Input is consumed if both valid and ready on this rising edge.
        do begin
            @(posedge clk);
        end while (!in_ready);
        @(negedge clk);
        in_valid=0;
    endtask
    task automatic send_frames(input integer count);
        for (integer f=0;f<count;f=f+1)
            for (integer w=0;w<96;w=w+1)
                send_one(f,w,w==95);
    endtask
    task automatic wait_done(input integer expect_frames);
        integer timeout=0;
        @(negedge clk);
        while (!packer_done && timeout<300000) begin
            @(negedge clk);
            timeout=timeout+1;
        end
        if (!packer_done)
            $fatal(1,"packer_done timeout: sent=%0d packed=%0d",frames_sent,frames_packed);
        if (format_error || target_error)
            $fatal(1,"unexpected error bits format=%0d target=%0d",format_error,target_error);
        if (frames_packed != expect_frames || frames_sent != expect_frames)
            $fatal(1,"frame counters wrong: %0d/%0d expected %0d",frames_packed,frames_sent,expect_frames);
        if (desc_total != (1+6*expect_frames) || w_total != (16+96*expect_frames))
            $fatal(1,"burst/word counts wrong: %0d/%0d",desc_total,w_total);
        if (bursts_sent != 1+6*expect_frames)
            $fatal(1,"burst counter wrong");
        checks=checks+5;
        groups=groups+1;
    endtask

    initial begin
        aux_data[0+:64]   = 64'h1111111122222222;
        aux_data[64+:64]  = 64'h3333333344444444;
        aux_data[128+:64] = 64'h5555555566666666;
        aux_data[192+:64] = 64'h7777777788888888;

        $display("[TEST] preamble layout, 2 frames, six bursts each");
        reset_dut(); launch(2,0); send_frames(2); wait_done(2);

        $display("[TEST] 3 frames with WREADY stalls");
        reset_dut(); launch(3,1); send_frames(3); wait_done(3);

        $display("[TEST] descriptor AW-style backpressure, data buffered");
        reset_dut(); launch(2,2);
        stall_descriptor=1;
        fork
            send_frames(2);
            begin
                repeat(100) @(negedge clk);
                stall_descriptor=0;
            end
        join
        wait_done(2);

        $display("[TEST] W channel long pause while second bank fills");
        reset_dut(); launch(2,3);
        stall_data=1;
        fork
            send_frames(2);
            begin
                repeat(110) @(negedge clk);
                stall_data=0;
            end
        join
        wait_done(2);

        $display("[TEST] four frames, ordered bank ping-pong");
        reset_dut(); launch(4,4); send_frames(4); wait_done(4);

        $display("[TEST] 64 frames, long streaming sequence");
        reset_dut(); launch(64,5); send_frames(64); wait_done(64);

        $display("[TEST] STOP at frame boundary reduces effective target");
        reset_dut(); launch(4,6);
        send_frames(1);
        @(negedge clk); stop_target_frames=18'd1; stop_target_valid=1;
        @(negedge clk); stop_target_valid=0;
        wait_done(1);

        $display("[TEST] early TLAST flags malformed data");
        reset_dut(); launch(2,7);
        for (integer w=0;w<9;w=w+1)
            send_one(0,w,w==8);
        repeat(5) @(negedge clk);
        if (!format_error || in_ready)
            $fatal(1,"missing early-TLAST error");
        checks=checks+2; groups=groups+1;

        $display("[TEST] missing TLAST flags malformed data");
        reset_dut(); launch(2,8);
        for (integer w=0;w<96;w=w+1)
            send_one(0,w,1'b0);
        repeat(5) @(negedge clk);
        if (!format_error || in_ready)
            $fatal(1,"missing no-TLAST error");
        checks=checks+2; groups=groups+1;

        $display("PASS: %0d groups, %0d checks",groups,checks);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"global watchdog timeout");
    end
endmodule
`default_nettype wire
