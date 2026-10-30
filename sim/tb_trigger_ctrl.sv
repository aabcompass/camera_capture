`timescale 1ns/1ps
`default_nettype none
module tb_trigger_ctrl;
    logic clk=1'b0;
    always #2.5 clk=~clk; // 200 MHz

    logic rst=1'b1;
    logic [63:0] s_axis_trg_tdata=64'd0;
    logic s_axis_trg_tvalid=1'b0;
    logic ext_trig_async=1'b0;
    logic int_single_pulse=1'b0;
    logic int_periodic_enable=1'b0;
    logic [31:0] int_period_cycles=32'd0;
    logic [2:0] trigger_enable=3'd0;
    logic [63:0] timestamp=64'd0;
    logic run_start=1'b0;
    logic run_active=1'b0;
    logic accept_enable=1'b0;
    logic count_enable=1'b0;
    logic clear_stats=1'b0;

    wire alg_event,ext_event,int_event,trigger_event,trigger_accept;
    wire [1:0] trigger_event_count,trigger_missed_events,trigger_source;
    wire [63:0] trigger_data;
    wire [63:0] latched_timestamp,latched_trigger_data;
    wire [1:0] latched_trigger_source;
    wire [63:0] triggers_accepted_total,triggers_missed_total;

    trigger_ctrl dut (.*);

    integer checks=0;
    integer groups=0;
    logic [63:0] expect_accepted=64'd0;
    logic [63:0] expect_missed=64'd0;

    task automatic check(input bit ok, input string message);
        begin
            checks=checks+1;
            if (!ok) $fatal(1, "CHECK FAIL: %s (time=%0t)", message, $time);
        end
    endtask

    // Independently tally the instantaneous source events, rather than
    // reusing trigger_accept or trigger_missed_events to predict counters.
    // Individual tests also check the source edges and periodic phase.
    integer event_sum_ref;
    logic accept_ref;
    integer missed_ref;
    always @(posedge clk) begin
        if (rst || clear_stats) begin
            expect_accepted = 64'd0;
            expect_missed = 64'd0;
        end else begin
            event_sum_ref = (alg_event ? 1 : 0) + (ext_event ? 1 : 0) +
                            (int_event ? 1 : 0);
            accept_ref = (event_sum_ref != 0) && count_enable &&
                         accept_enable && !run_start;
            missed_ref = count_enable ? (event_sum_ref - (accept_ref ? 1 : 0)) : 0;
            if (trigger_event_count !== event_sum_ref[1:0])
                $fatal(1,"trigger_event_count mismatch at %0t", $time);
            if (trigger_event !== (event_sum_ref != 0))
                $fatal(1,"trigger_event mismatch at %0t", $time);
            if (trigger_accept !== accept_ref)
                $fatal(1,"trigger_accept mismatch at %0t", $time);
            if (trigger_missed_events !== missed_ref[1:0])
                $fatal(1,"trigger_missed_events mismatch at %0t", $time);
            if (accept_ref) expect_accepted=expect_accepted+64'd1;
            expect_missed=expect_missed+missed_ref;
        end
    end

    task automatic check_stats;
        begin
            #0.1;
            check(triggers_accepted_total === expect_accepted,
                  $sformatf("accepted count: actual=%0d expected=%0d",
                            triggers_accepted_total, expect_accepted));
            check(triggers_missed_total === expect_missed,
                  $sformatf("missed count: actual=%0d expected=%0d",
                            triggers_missed_total, expect_missed));
        end
    endtask

    task automatic quiet_inputs;
        begin
            @(negedge clk);
            s_axis_trg_tvalid=1'b0;
            s_axis_trg_tdata=64'd0;
            int_single_pulse=1'b0;
            ext_trig_async=1'b0;
        end
    endtask

    task automatic accept_alg(input logic [63:0] data_word,
                              input logic [63:0] time_word);
        begin
            @(negedge clk);
            s_axis_trg_tvalid=1'b1;
            s_axis_trg_tdata=data_word;
            timestamp=time_word;
            #0.1;
            check(alg_event && trigger_event && trigger_accept,
                  "nonzero algorithmic event accepted same cycle");
            check(trigger_event_count==2'd1 && trigger_source==2'd1,
                  "algorithmic source/count");
            check(trigger_data==data_word,"algorithmic data live before edge");
            @(posedge clk);
            #0.1;
            check(latched_timestamp==time_word,"algorithmic timestamp latched");
            check(latched_trigger_data==data_word,"algorithmic data latched");
            check(latched_trigger_source==2'd1,"algorithmic source latched");
            @(negedge clk);
            s_axis_trg_tvalid=1'b0;
            s_axis_trg_tdata=64'd0;
        end
    endtask

    task automatic await_external_edge;
        integer watchdog;
        begin
            watchdog=0;
            while (!ext_event && watchdog<8) begin
                @(negedge clk);
                watchdog=watchdog+1;
            end
            check(ext_event,"synchronized external edge within 8 clocks");
        end
    endtask

    integer i;
    logic [63:0] a0,m0;
    initial begin
        repeat(4) @(negedge clk);
        rst=1'b0;
        trigger_enable=3'b001;
        count_enable=1'b1;
        accept_enable=1'b1;
        run_active=1'b1;
        @(negedge clk);
        check_stats();

        $display("[TEST] algorithmic nonzero/TVALID gating and same-edge metadata latch");
        groups=groups+1;
        @(negedge clk);
        s_axis_trg_tvalid=1'b1;
        s_axis_trg_tdata=64'd0;
        #0.1;
        check(!alg_event && !trigger_event && !trigger_accept,
              "zero algorithmic word does not trigger");
        @(posedge clk);
        @(negedge clk);
        s_axis_trg_tvalid=1'b0;
        s_axis_trg_tdata=64'h123;
        #0.1;
        check(!alg_event,"nonzero data without TVALID ignored");
        accept_alg(64'h123456789abcdef0,64'h1122334455667788);
        check_stats();

        $display("[TEST] consecutive algorithmic beats are distinct events");
        groups=groups+1;
        @(negedge clk);
        a0=triggers_accepted_total;
        s_axis_trg_tvalid=1'b1;
        s_axis_trg_tdata=64'd17;
        timestamp=64'd300;
        #0.1;
        check(trigger_accept,"first consecutive event");
        @(posedge clk);
        #0.1;
        check(latched_trigger_data==64'd17,"first consecutive data");
        @(negedge clk);
        s_axis_trg_tdata=64'd18;
        timestamp=64'd301;
        #0.1;
        check(trigger_accept,"second consecutive event");
        @(posedge clk);
        #0.1;
        check(latched_trigger_data==64'd18 && latched_timestamp==64'd301,
              "second consecutive metadata");
        @(negedge clk);
        s_axis_trg_tvalid=1'b0;
        check(triggers_accepted_total==a0+64'd2,"two consecutive events counted");
        check_stats();

        $display("[TEST] source masks and inactive-state accounting");
        groups=groups+1;
        @(negedge clk);
        trigger_enable=3'b000;
        s_axis_trg_tvalid=1'b1;
        s_axis_trg_tdata=64'd1;
        #0.1;
        check(!trigger_event,"masked source ignored");
        @(posedge clk);
        @(negedge clk);
        trigger_enable=3'b001;
        count_enable=1'b0; // idle/error/end not counted
        #0.1;
        check(trigger_event && !trigger_accept && trigger_missed_events==0,
              "events inactive: observed but not accepted or missed");
        @(posedge clk);
        @(negedge clk);
        s_axis_trg_tvalid=1'b0;
        count_enable=1'b1;
        check_stats();

        $display("[TEST] algorithmic vs internal priority and source data");
        groups=groups+1;
        @(negedge clk);
        trigger_enable=3'b101;
        s_axis_trg_tdata=64'hbadcafe;
        s_axis_trg_tvalid=1'b1;
        int_single_pulse=1'b1;
        timestamp=64'habc;
        #0.1;
        check(alg_event && int_event && !ext_event,"two detected sources");
        check(trigger_event_count==2'd2 && trigger_missed_events==2'd1,
              "one accepted, one missed in two-source collision");
        check(trigger_source==2'd1 && trigger_data==64'hbadcafe,
              "algorithmic beats internal priority");
        @(posedge clk);
        #0.1;
        check(latched_trigger_data==64'hbadcafe && latched_timestamp==64'habc,
              "winner metadata stored");
        @(negedge clk);
        s_axis_trg_tvalid=1'b0;
        int_single_pulse=1'b1;
        #0.1;
        check(trigger_source==2'd3 && trigger_data==0,"internal source metadata zero");
        @(posedge clk);
        #0.1;
        check(latched_trigger_source==2'd3 && latched_trigger_data==0,
              "internal event snapshot");
        @(negedge clk);
        int_single_pulse=1'b0;
        check_stats();

        $display("[TEST] external asynchronous edge, held level, second rising edge");
        groups=groups+1;
        @(negedge clk);
        trigger_enable=3'b010;
        #0.7; ext_trig_async=1'b1; // deliberately off the active edge
        #0.1;
        check(!ext_event,"asynchronous input must not bypass synchronizer");
        await_external_edge();
        timestamp=64'hfeed0001;
        #0.1;
        check(trigger_accept && trigger_source==2'd2 && trigger_data==0,
              "external event accepted");
        @(posedge clk);
        #0.1;
        check(latched_timestamp==64'hfeed0001 && latched_trigger_data==0 &&
              latched_trigger_source==2'd2,"timestamp of synchronized external event");
        for (i=0;i<5;i=i+1) begin
            @(negedge clk);
            check(!ext_event,"external held high must not retrigger");
        end
        ext_trig_async=1'b0;
        repeat(5) @(negedge clk);
        check(!ext_event,"external low rearms detector");
        ext_trig_async=1'b1;
        await_external_edge();
        #0.1;
        check(ext_event && trigger_accept,"second external rising edge");
        @(posedge clk);
        @(negedge clk);
        ext_trig_async=1'b0;
        repeat(5) @(negedge clk);
        check_stats();

        $display("[TEST] simultaneous external, algorithmic, internal arbitration");
        groups=groups+1;
        @(negedge clk);
        trigger_enable=3'b111;
        ext_trig_async=1'b1;
        await_external_edge();
        s_axis_trg_tvalid=1'b1;
        s_axis_trg_tdata=64'h8badf00d;
        int_single_pulse=1'b1;
        timestamp=64'h1234567890;
        #0.1;
        check(alg_event && ext_event && int_event,"three sources concurrently");
        check(trigger_event_count==2'd3 && trigger_missed_events==2'd2,
              "three sources => one accepted, two missed");
        check(trigger_source==2'd2 && trigger_data==0,"external has highest priority");
        @(posedge clk);
        #0.1;
        check(latched_trigger_source==2'd2 && latched_trigger_data==0 &&
              latched_timestamp==64'h1234567890,"triple event metadata");
        @(negedge clk);
        s_axis_trg_tvalid=1'b0;
        int_single_pulse=1'b0;
        ext_trig_async=1'b0;
        repeat(5) @(negedge clk);
        check_stats();

        $display("[TEST] dead time and STOP priority expressed by accept_enable");
        groups=groups+1;
        @(negedge clk);
        trigger_enable=3'b101;
        accept_enable=1'b0; // data_transfer, or STOP wins in trig_wait
        count_enable=1'b1;
        a0=triggers_accepted_total;
        m0=triggers_missed_total;
        s_axis_trg_tvalid=1'b1;
        s_axis_trg_tdata=64'd71;
        int_single_pulse=1'b1;
        #0.1;
        check(!trigger_accept && trigger_missed_events==2'd2,
              "dead time counts both enabled events");
        @(posedge clk);
        @(negedge clk);
        s_axis_trg_tvalid=1'b0;
        int_single_pulse=1'b0;
        check(triggers_accepted_total==a0,"dead time does not accept trigger");
        check(triggers_missed_total==m0+64'd2,"two dead-time events counted");
        check_stats();

        $display("[TEST] periodic trigger phase, sustained during dead time");
        groups=groups+1;
        @(negedge clk);
        trigger_enable=3'b100;
        int_periodic_enable=1'b1;
        int_period_cycles=32'd4;
        run_start=1'b1;
        run_active=1'b1;
        accept_enable=1'b1;
        count_enable=1'b1;
        @(posedge clk);
        @(negedge clk);
        run_start=1'b0;
        // At loop iteration i, evaluate the event before the ith clock since
        // START. PERIOD=4 => ticks on clocks 4, 8, and 12.
        for (i=1;i<=12;i=i+1) begin
            #0.1;
            check(int_event === (i%4==0),
                  $sformatf("periodic phase at active clock %0d",i));
            if (i==4) check(trigger_accept,"periodic accepted while waiting");
            if (i==8 || i==12)
                check(!trigger_accept && trigger_missed_events==1,
                      "periodic ticks continue during dead time");
            @(posedge clk);
            #0.1;
            @(negedge clk);
            if (i==7) accept_enable=1'b0;
        end
        run_active=1'b0;
        #0.1;
        check(!int_event,"periodic generation stops when run ends");
        repeat(6) @(negedge clk);
        check(!int_event,"no periodic event after run ends");
        check_stats();

        $display("[TEST] period=1, period=0, clear_stats and reset");
        groups=groups+1;
        @(negedge clk);
        run_start=1'b1;
        run_active=1'b1;
        int_period_cycles=32'd1;
        accept_enable=1'b1;
        @(posedge clk);
        @(negedge clk);
        run_start=1'b0;
        int_single_pulse=1'b1;
        #0.1;
        check(int_event && trigger_accept,"period=1 fires first edge after START");
        check(trigger_event_count==2'd1,
              "periodic tick and single command count once as internal source");
        @(posedge clk);
        @(negedge clk);
        int_single_pulse=1'b0;
        check(int_event,"period=1 fires every active cycle");
        int_period_cycles=32'd0;
        #0.1;
        check(!int_event,"period=0 cannot generate event");
        repeat(3) @(negedge clk);
        check_stats();
        // Clear cumulative counters while preserving last accepted metadata.
        a0=latched_timestamp;
        @(negedge clk);
        run_active=1'b0;
        clear_stats=1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_stats=1'b0;
        check(triggers_accepted_total==0 && triggers_missed_total==0,
              "clear_stats resets both counters");
        check(latched_timestamp==a0,"clear_stats leaves last metadata intact");
        check_stats();
        @(negedge clk);
        rst=1'b1;
        @(posedge clk);
        @(negedge clk);
        check(latched_timestamp==0 && latched_trigger_data==0 &&
              latched_trigger_source==0,"reset clears metadata");
        check(triggers_accepted_total==0 && triggers_missed_total==0,
              "reset clears both counters");
        rst=1'b0;
        check_stats();

        $display("PASS: %0d groups, %0d checks",groups,checks);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Global simulation timeout");
    end
endmodule
`default_nettype wire
