`timescale 1ns/1ps
`default_nettype none
module tb_capture_fifo_ctrl;
    logic clk=0;
    always #2.5 clk=~clk; // 200 MHz
    logic rst=1;
    logic fifo_flush=0;
    wire fifo_ready;
    logic [64:0] write_data=0;
    logic write_req=0;
    wire write_accepted;
    logic frame_stored=0;
    logic [6:0] n_prev_frames=0;
    logic drop_enable=0;
    logic trigger_accept=0;
    logic transfer_enable=0;
    wire [64:0] read_data;
    wire read_valid;
    logic read_ready=0;
    wire [13:0] fifo_level_words;
    wire [7:0] complete_frames;
    wire logical_full, overflow_pulse, overflow_sticky;
    wire drop_active, drop_frame_done;
    wire triggered, transfer_ready, popped_frame_done;
    wire [7:0] drops_remaining;
    integer groups=0, checks=0;
    integer compare_first=0, compare_frames=0, observed=0;
    logic compare_active=0;
    integer drop_completions=0;
    integer overflow_count=0;

    capture_fifo_ctrl #(.USE_XPM(1'b1)) dut (.*);

    function automatic [63:0] datum(input integer f, input integer w);
        datum = {f[31:0], w[31:0]};
    endfunction

    task automatic check(input bit ok, input string why);
        begin
            checks=checks+1;
            if (!ok) $fatal(1,"CHECK FAIL: %s at %0t",why,$time);
        end
    endtask

    // The scoreboard checks every popped 64-bit word, not just frame counts.
    always @(posedge clk) begin
        if (!rst && !fifo_flush) begin
            if (drop_frame_done) drop_completions=drop_completions+1;
            if (overflow_pulse) overflow_count=overflow_count+1;
            if (read_valid && read_ready && compare_active) begin
                if (observed >= compare_frames*96)
                    $fatal(1,"unexpected extra read word at %0t",$time);
                if (read_data[63:0] !== datum(compare_first+(observed/96), observed%96))
                    $fatal(1,"data mismatch at read %0d: got %h expected %h",observed,
                        read_data[63:0],datum(compare_first+(observed/96),observed%96));
                if (read_data[64] !== ((observed%96)==95))
                    $fatal(1,"TLAST mismatch at word %0d", observed);
                observed=observed+1;
                checks=checks+1;
            end
        end
    end

    task automatic do_flush;
        integer i;
        begin
            @(negedge clk);
            write_req=0; frame_stored=0; trigger_accept=0;
            transfer_enable=0; read_ready=0; drop_enable=0;
            compare_active=0;
            fifo_flush=1;
            @(negedge clk);
            fifo_flush=0;
            for(i=0; i<20 && !fifo_ready; i=i+1) @(negedge clk);
            check(fifo_ready,"FIFO ready after flush");
            check(fifo_level_words==0,"zero word count after flush");
            check(complete_frames==0,"zero complete-frame count after flush");
            check(!triggered,"trigger state cleared on flush");
            check(!overflow_sticky,"overflow status cleared on flush");
        end
    endtask

    // Continuous-cycle 96-word frames. No backpressure is ever applied to
    // the sender; every offered word is checked for same-edge admission.
    task automatic send_frame(input integer frame_no,
                              input integer trigger_word,
                              input bit expect_every_word);
        integer i;
        begin
            for(i=0;i<96;i=i+1) begin
                @(negedge clk);
                write_req=1;
                frame_stored=(i==95);
                write_data={(i==95), datum(frame_no,i)};
                trigger_accept=(i==trigger_word);
                #0.1;
                if (expect_every_word)
                    check(write_accepted,"input word accepted");
                if (trigger_accept)
                    check(!triggered,"trigger has not been latched prematurely");
                @(posedge clk);
                #0.1;
            end
            @(negedge clk);
            write_req=0;
            frame_stored=0;
            trigger_accept=0;
        end
    endtask

    task automatic begin_compare(input integer first, input integer count);
        begin
            @(negedge clk);
            compare_first=first;
            compare_frames=count;
            observed=0;
            compare_active=1;
            transfer_enable=1;
            read_ready=1;
        end
    endtask

    task automatic expect_words(input integer count);
        integer timeout;
        begin
            timeout=0;
            while (observed < count && timeout < 100000) begin
                @(negedge clk);
                timeout=timeout+1;
            end
            check(observed==count,"expected complete transfer");
            @(negedge clk);
            read_ready=0;
            transfer_enable=0;
            compare_active=0;
            check(fifo_level_words==0,"FIFO emptied after transfer");
            check(complete_frames==0,"all complete frames popped");
        end
    endtask

    task automatic await_transfer_ready;
        integer timeout;
        begin
            timeout=0;
            while (!transfer_ready && timeout<2000) begin
                @(negedge clk);
                timeout=timeout+1;
            end
            check(transfer_ready,"triggered FIFO finished necessary drops");
        end
    endtask

    integer i;
    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        repeat(5) @(negedge clk);
        check(fifo_ready,"initial reset completed");

        $display("[TEST] rolling last-four pretrigger frames, trigger inside frame");
        groups=groups+1;
        do_flush();
        n_prev_frames=7'd4;
        drop_enable=1;
        for(i=0;i<=10;i=i+1) send_frame(i,-1,1);
        send_frame(11,37,1);
        await_transfer_ready();
        // Output starts at 7: 7..10 are PRE; 11 is first POST.
        begin_compare(7,5);
        expect_words(5*96);
        check(overflow_count==0,"no overflow in rolling mode");

        $display("[TEST] trigger on TLAST preserves that entire frame");
        groups=groups+1;
        do_flush();
        n_prev_frames=7'd4;
        drop_enable=1;
        for(i=100;i<104;i=i+1) send_frame(i,-1,1);
        send_frame(104,95,1);
        await_transfer_ready();
        begin_compare(100,5);
        expect_words(5*96);

        $display("[TEST] trigger while oldest frame DROP is in progress");
        groups=groups+1;
        do_flush();
        n_prev_frames=7'd4;
        drop_enable=1;
        for(i=200;i<=204;i=i+1) send_frame(i,-1,1);
        // Ensure the current DROP has started but isn't finished.
        check(drop_active || complete_frames==5,"a surplus frame exists");
        send_frame(205,10,1);
        await_transfer_ready();
        begin_compare(201,5);
        expect_words(5*96);

        $display("[TEST] trigger simultaneous with last DROP word");
        groups=groups+1;
        do_flush();
        n_prev_frames=7'd4;
        drop_enable=1;
        for(i=210;i<=214;i=i+1) send_frame(i,-1,1);
        // The next frame starts after one idle cycle. The 95th incoming
        // word aligns with TLAST of the background drop in this model.
        send_frame(215,94,1);
        await_transfer_ready();
        begin_compare(211,5);
        expect_words(5*96);

        $display("[TEST] trigger between frames; next frame is first POST");
        groups=groups+1;
        do_flush();
        n_prev_frames=7'd4;
        drop_enable=1;
        for(i=220;i<224;i=i+1) send_frame(i,-1,1);
        @(negedge clk); trigger_accept=1;
        @(negedge clk); trigger_accept=0;
        check(triggered,"between-frame trigger registered");
        send_frame(224,-1,1);
        await_transfer_ready();
        begin_compare(220,5);
        expect_words(5*96);

        $display("[TEST] n_prev_frames=0; retain frame containing trigger");
        groups=groups+1;
        do_flush();
        n_prev_frames=0;
        drop_enable=1;
        send_frame(300,-1,1);
        send_frame(301,-1,1);
        send_frame(302,50,1);
        await_transfer_ready();
        begin_compare(302,1);
        expect_words(96);

        $display("[TEST] maximum pretrigger=64, continuous input");
        groups=groups+1;
        do_flush();
        n_prev_frames=7'd64;
        drop_enable=1;
        for(i=400;i<=464;i=i+1) send_frame(i,-1,1);
        send_frame(465,20,1);
        await_transfer_ready();
        begin_compare(401,65);
        expect_words(65*96);

        $display("[TEST] full 100-frame FIFO, simultaneous pop+push at limit");
        groups=groups+1;
        do_flush();
        n_prev_frames=0;
        // Capture an early trigger to freeze drop, while transfer is disabled.
        @(negedge clk); trigger_accept=1;
        @(negedge clk); trigger_accept=0;
        check(transfer_ready,"ready immediately after trigger with 0 PRE");
        for(i=500;i<600;i=i+1) send_frame(i,-1,1);
        check(fifo_level_words==9600,"100 frames = 9600 words");
        check(logical_full,"logical FULL set");
        compare_first=500; compare_frames=100; observed=0;
        compare_active=1;
        @(negedge clk);
        transfer_enable=1; read_ready=1;
        write_req=1; write_data={1'b0, datum(600,0)};
        frame_stored=0;
        #0.1;
        check(read_valid,"first full-FIFO word available");
        check(write_accepted,"read and write same edge at logical full");
        @(negedge clk);
        write_req=0;
        // We inserted the first word of frame 600 on purpose; now drain only
        // 100 complete frames, leaving that single partial word in the FIFO.
        begin : drain100
            integer timeout;
            timeout=0;
            while(observed<9600 && timeout<30000) begin
                @(negedge clk); timeout=timeout+1;
            end
            check(observed==9600,"all 100 complete frames drained");
        end
        @(negedge clk);
        transfer_enable=0; read_ready=0; compare_active=0;
        check(fifo_level_words==1,"one newly inserted partial word remains");
        check(complete_frames==0,"no complete frames remain");
        check(overflow_count==0,"no false overflow on simultaneous pop+push");

        $display("[TEST] overflow detected at 9600-word logical limit");
        groups=groups+1;
        do_flush();
        n_prev_frames=64;
        // No drop and no transfer: this intentionally fills to 100 frames.
        for(i=700;i<800;i=i+1) send_frame(i,-1,1);
        check(logical_full,"full before overflow attempt");
        @(negedge clk);
        write_req=1; write_data={1'b0, datum(800,0)}; frame_stored=0;
        #0.1;
        check(!write_accepted,"the 9601st word is refused");
        check(overflow_pulse,"overflow event generated");
        @(negedge clk);
        write_req=0;
        check(overflow_sticky,"overflow sticky status set");
        check(fifo_level_words==9600,"overflow does not overwrite stored frames");
        check(overflow_count==1,"overflow count increments on refused write");

        $display("PASS: %0d groups, %0d checks",groups,checks);
        $finish;
    end
endmodule
`default_nettype wire
