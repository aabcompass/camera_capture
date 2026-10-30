`timescale 1ns/1ps
module tb_axi_lite_regs;
    logic clk=0;
    always #2.5 clk = ~clk;
    logic rst=1;
    logic [31:0] s_axi_awaddr=0;
    logic [2:0] s_axi_awprot=0;
    logic s_axi_awvalid=0;
    wire s_axi_awready;
    logic [31:0] s_axi_wdata=0;
    logic [3:0] s_axi_wstrb=0;
    logic s_axi_wvalid=0;
    wire s_axi_wready;
    wire [1:0] s_axi_bresp;
    wire s_axi_bvalid;
    logic s_axi_bready=0;
    logic [31:0] s_axi_araddr=0;
    logic [2:0] s_axi_arprot=0;
    logic s_axi_arvalid=0;
    wire s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rvalid;
    logic s_axi_rready=0;
    logic allow_start=1;
    logic allow_clear_error=1;
    logic allow_clear_stats=1;
    logic cfg_write_lock=0;
    logic run_start_pulse=0;
    wire cmd_start, cmd_stop, cmd_clear_error, cmd_clear_stats, int_single_pulse;
    wire [2:0] cfg_trigger_enable;
    wire [31:0] cfg_n_frames, cfg_n_prev_frames, cfg_n_fragments;
    wire [31:0] cfg_mem_addr, cfg_mem_buffer_bytes, cfg_header_id;
    wire [255:0] cfg_aux_data;
    wire [31:0] cfg_int_trig_period;
    wire cfg_int_periodic_enable;
    wire [2:0] active_trigger_enable;
    wire [31:0] active_n_frames, active_n_prev_frames, active_n_fragments;
    wire [31:0] active_mem_addr, active_mem_buffer_bytes, active_header_id;
    wire [255:0] active_aux_data;
    wire [31:0] active_int_trig_period;
    wire active_int_periodic_enable;
    logic [3:0] fsm_state=0;
    logic status_busy=0, status_stop_pending=0, status_trigger_latched=0;
    logic status_capture_complete=0, status_axi_busy=0;
    logic status_fifo_empty=1, status_fifo_full=0;
    logic [31:0] error_set_mask=0;
    wire [31:0] error_flags;
    logic [31:0] last_error_code=0, last_error_addr=0, fifo_level=0;
    logic [31:0] frames_captured=0, frames_sent=0, frames_committed=0;
    logic [31:0] fragments_completed=0;
    logic [63:0] triggers_accepted_total=0, triggers_missed_total=0;
    logic [31:0] fifo_overflow_count=0, axi_error_count=0;
    logic [31:0] current_write_addr=0;
    logic [63:0] last_timestamp=0, last_trigger_data=0;
    logic [31:0] last_trigger_source=0;
    logic [31:0] last_fragment_addr=0, last_fragment_frames=0;
    logic [31:0] last_fragment_size=0, last_fragment_status=0;
    logic [31:0] run_fragments_completed=0;

    axi_lite_regs dut (.*);

    integer checks=0, groups=0;
    integer start_pulses=0, stop_pulses=0, clear_error_pulses=0;
    integer clear_stats_pulses=0, int_single_pulses=0;
    always @(posedge clk) begin
        if (!rst) begin
            if (cmd_start) start_pulses <= start_pulses+1;
            if (cmd_stop) stop_pulses <= stop_pulses+1;
            if (cmd_clear_error) clear_error_pulses <= clear_error_pulses+1;
            if (cmd_clear_stats) clear_stats_pulses <= clear_stats_pulses+1;
            if (int_single_pulse) int_single_pulses <= int_single_pulses+1;
        end
    end

    task automatic ck(input logic [31:0] got, input logic [31:0] expected, input string message);
        checks++;
        if (got !== expected)
            $fatal(1,"CHECK FAILED: %s got=%08h expected=%08h time=%0t", message, got, expected, $time);
    endtask
    task automatic ck2(input logic [1:0] got, input logic [1:0] expected, input string message);
        checks++;
        if (got !== expected)
            $fatal(1,"CHECK FAILED: %s got=%b expected=%b time=%0t", message, got, expected, $time);
    endtask
    task automatic grp(input string title);
        groups++;
        $display("[TEST] %s",title);
    endtask

    task automatic drive_aw(input logic [31:0] addr, input integer delay_cycles);
        repeat (delay_cycles) @(negedge clk);
        @(negedge clk);
        s_axi_awaddr=addr;
        s_axi_awvalid=1;
        do @(posedge clk); while (!s_axi_awready);
        @(negedge clk);
        s_axi_awvalid=0;
    endtask
    task automatic drive_w(input logic [31:0] data, input logic [3:0] strb, input integer delay_cycles);
        repeat (delay_cycles) @(negedge clk);
        @(negedge clk);
        s_axi_wdata=data;
        s_axi_wstrb=strb;
        s_axi_wvalid=1;
        do @(posedge clk); while (!s_axi_wready);
        @(negedge clk);
        s_axi_wvalid=0;
    endtask
    task automatic axi_write(
        input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb,
        input integer aw_delay, input integer w_delay,
        input logic [1:0] expected_bresp
    );
        fork
            drive_aw(addr,aw_delay);
            drive_w(data,strb,w_delay);
        join
        do @(posedge clk); while (!s_axi_bvalid);
        ck2(s_axi_bresp,expected_bresp,"BRESP");
        // Verify that BVALID/BRESP are held under BREADY backpressure.
        repeat (2) begin
            @(negedge clk);
            ck(s_axi_bvalid,1,"BVALID remains asserted while stalled");
            ck2(s_axi_bresp,expected_bresp,"BRESP remains stable while stalled");
        end
        s_axi_bready=1;
        @(posedge clk);
        @(negedge clk);
        s_axi_bready=0;
    endtask
    task automatic axi_read(input logic [31:0] addr, output logic [31:0] data,
                            output logic [1:0] resp);
        @(negedge clk);
        s_axi_araddr=addr;
        s_axi_arvalid=1;
        do @(posedge clk); while (!s_axi_arready);
        @(negedge clk);
        s_axi_arvalid=0;
        do @(posedge clk); while (!s_axi_rvalid);
        data=s_axi_rdata;
        resp=s_axi_rresp;
        repeat (2) begin
            @(negedge clk);
            ck(s_axi_rvalid,1,"RVALID held until RREADY");
            ck(s_axi_rdata,data,"RDATA held until RREADY");
            ck2(s_axi_rresp,resp,"RRESP held until RREADY");
        end
        s_axi_rready=1;
        @(posedge clk);
        @(negedge clk);
        s_axi_rready=0;
    endtask
    task automatic read_check(input logic [31:0] addr, input logic [31:0] expected);
        logic [31:0] value;
        logic [1:0] resp;
        axi_read(addr,value,resp);
        ck2(resp,2'b00,"read OKAY");
        ck(value,expected,"readback");
    endtask
    task automatic pulse_run_start;
        @(negedge clk);
        run_start_pulse=1;
        @(posedge clk);
        @(negedge clk);
        run_start_pulse=0;
    endtask

    initial begin : test_sequence
        logic [31:0] value;
        logic [1:0] response;
        integer prior_count;
        repeat (4) @(negedge clk);
        rst=0;
        repeat (2) @(negedge clk);

        grp("reset values, register address map and read-only status");
        read_check(32'h010,32'd2);
        read_check(32'h014,32'd0);
        read_check(32'h018,32'd1);
        read_check(32'h01C,32'd0);
        read_check(32'h00C,32'd0);
        read_check(32'h0B4,32'd0);
        read_check(32'h0B0,32'h0001_0000);
        ck(cfg_int_periodic_enable,0,"periodic reset");

        grp("AW before W, W before AW, independent channels");
        axi_write(32'h010,32'd123,4'hF,0,4,2'b00);
        read_check(32'h010,32'd123);
        axi_write(32'h014,32'd23,4'hF,4,0,2'b00);
        read_check(32'h014,32'd23);
        axi_write(32'h018,32'd10,4'hF,0,0,2'b00);
        read_check(32'h018,32'd10);

        grp("WSTRB byte writes and zero-strobe no-op");
        axi_write(32'h020,32'h11223344,4'hF,0,0,2'b00);
        axi_write(32'h020,32'hAA00BB00,4'b1010,0,0,2'b00);
        read_check(32'h020,32'hAA22BB44);
        axi_write(32'h020,32'hFFFFFFFF,4'b0000,0,0,2'b00);
        read_check(32'h020,32'hAA22BB44);
        axi_write(32'h00C,32'hFFFFFFFF,4'hF,0,0,2'b00);
        read_check(32'h00C,32'h00000007);

        grp("auxiliary 256-bit register mapping and run configuration snapshot");
        for (int i=0; i<8; i++) begin
            axi_write(32'h024 + i*4, 32'hDEAD0000+i,4'hF,0,0,2'b00);
            read_check(32'h024 + i*4,32'hDEAD0000+i);
        end
        axi_write(32'h01C,32'h10000000,4'hF,0,0,2'b00);
        axi_write(32'h0B4,32'h01000000,4'hF,0,0,2'b00);
        axi_write(32'h044,32'd200000,4'hF,0,0,2'b00);
        axi_write(32'h048,32'h00000002,4'h1,0,0,2'b00);
        pulse_run_start();
        ck(active_n_frames,123,"active frames on run start");
        ck(active_n_prev_frames,23,"active pretrigger on run start");
        ck(active_header_id,32'hAA22BB44,"active header");
        ck(active_mem_addr,32'h10000000,"active mem addr");
        ck(active_mem_buffer_bytes,32'h01000000,"active mem range");
        ck(active_int_trig_period,32'd200000,"active trigger period");
        ck(active_int_periodic_enable,1,"active periodic enable");
        ck(active_trigger_enable,3'b111,"active sources");
        for (int i=0; i<8; i++) ck(active_aux_data[i*32 +: 32],32'hDEAD0000+i,"active AUX snapshot");
        // Shadow updates while active; active set remains constant until next accepted START.
        cfg_write_lock=1;
        axi_write(32'h010,32'd789,4'hF,0,0,2'b10);
        read_check(32'h010,32'd123);
        cfg_write_lock=0;
        axi_write(32'h010,32'd456,4'hF,0,0,2'b00);
        axi_write(32'h024,32'hABCDEF89,4'hF,0,0,2'b00);
        read_check(32'h010,32'd456);
        ck(active_n_frames,123,"active frames did not change");
        ck(active_aux_data[31:0],32'hDEAD0000,"active AUX did not change");
        pulse_run_start();
        ck(active_n_frames,456,"active new frames after next run start");
        ck(active_aux_data[31:0],32'hABCDEF89,"active new AUX after next run start");

        grp("one-shot command pulses, command permissions and invalid combinations");
        prior_count=start_pulses;
        axi_write(32'h000,32'h00000001,4'h1,0,0,2'b00);
        repeat (2) @(negedge clk);
        ck(start_pulses,prior_count+1,"START exactly one pulse");
        allow_start=0;
        axi_write(32'h000,32'h00000001,4'h1,0,0,2'b10);
        ck(start_pulses,prior_count+1,"busy START rejected");
        prior_count=stop_pulses;
        axi_write(32'h000,32'h00000002,4'h1,0,0,2'b00);
        repeat (2) @(negedge clk);
        ck(stop_pulses,prior_count+1,"STOP exactly one pulse");
        axi_write(32'h000,32'h00000003,4'h1,0,0,2'b10);
        ck(stop_pulses,prior_count+1,"simultaneous command rejected");
        allow_start=1;
        prior_count=start_pulses;
        axi_write(32'h000,32'h00000001,4'b0010,0,0,2'b00);
        ck(start_pulses,prior_count,"masked command not asserted");
        read_check(32'h000,32'd0);

        grp("internal trigger single-shot and periodic enable mask");
        prior_count=int_single_pulses;
        axi_write(32'h048,32'h00000003,4'h1,0,0,2'b00);
        repeat (2) @(negedge clk);
        ck(int_single_pulses,prior_count+1,"one-shot pulse");
        read_check(32'h048,32'h00000002);
        axi_write(32'h048,32'h00000000,4'h1,0,0,2'b00);
        read_check(32'h048,32'd0);
        axi_write(32'h048,32'h80000000,4'hF,0,0,2'b10);
        read_check(32'h048,32'd0);

        grp("R channel status, read stalls and unmapped/readonly responses");
        fsm_state=4'd3;
        status_busy=1;
        status_stop_pending=1;
        status_trigger_latched=1;
        status_capture_complete=1;
        status_axi_busy=1;
        status_fifo_empty=0;
        status_fifo_full=1;
        fifo_level=32'd9600;
        frames_captured=32'd100;
        frames_sent=32'd99;
        frames_committed=32'd98;
        fragments_completed=32'd7;
        last_timestamp=64'h88776655_44332211;
        last_trigger_data=64'h01234567_89ABCDEF;
        last_trigger_source=32'd2;
        last_fragment_addr=32'h20000080;
        last_fragment_frames=32'd98;
        last_fragment_size=32'd75392;
        last_fragment_status=32'd2;
        run_fragments_completed=32'd5;
        read_check(32'h004,32'h000005F3); // state 3, bits4..8 set, full bit10
        read_check(32'h058,32'd9600);
        read_check(32'h05C,32'd100);
        read_check(32'h060,32'd99);
        read_check(32'h064,32'd98);
        read_check(32'h068,32'd7);
        read_check(32'h080,32'h44332211);
        read_check(32'h084,32'h88776655);
        read_check(32'h088,32'h89ABCDEF);
        read_check(32'h08C,32'h01234567);
        read_check(32'h090,32'd2);
        read_check(32'h094,32'h20000080);
        read_check(32'h098,32'd98);
        read_check(32'h09C,32'd75392);
        read_check(32'h0A0,32'd2);
        read_check(32'h0A4,32'd5);
        axi_write(32'h058,32'hFFFFFFFF,4'hF,0,0,2'b10);
        axi_read(32'h04C,value,response); ck2(response,2'b11,"unmapped RRESP DECERR");
        axi_write(32'h04C,32'd1,4'hF,0,0,2'b11);
        axi_read(32'h011,value,response); ck2(response,2'b11,"unaligned RRESP DECERR");
        axi_write(32'h011,32'd1,4'hF,0,0,2'b11);

        grp("sticky errors, hardware-set priority, clear permission");
        @(negedge clk); error_set_mask=32'h00000210; // ERR bit4, bit9
        @(posedge clk); @(negedge clk); error_set_mask=0;
        read_check(32'h008,32'h00000210);
        read_check(32'h004,32'h00000DF3); // previous status plus config_error bit11
        allow_clear_error=0;
        prior_count=clear_error_pulses;
        axi_write(32'h000,32'h00000004,4'h1,0,0,2'b10);
        ck(clear_error_pulses,prior_count,"CLEAR_ERROR forbidden");
        allow_clear_error=1;
        axi_write(32'h000,32'h00000004,4'h1,0,0,2'b00);
        repeat (2) @(negedge clk);
        ck(clear_error_pulses,prior_count+1,"CLEAR_ERROR permitted pulse");
        read_check(32'h008,32'd0);
        // Set another new fault and ensure it is reflected in STATUS.
        @(negedge clk); error_set_mask=32'h00000001;
        @(posedge clk); @(negedge clk); error_set_mask=0;
        read_check(32'h008,32'h00000001);
        read_check(32'h004,32'h000015F3);

        grp("64-bit trigger counter coherent LOW/HIGH snapshots");
        triggers_accepted_total=64'h12345678_FFFFFFFE;
        triggers_missed_total=64'hABCDEF01_00112233;
        read_check(32'h06C,32'hFFFFFFFE);
        triggers_accepted_total=64'h12345679_00000003;
        read_check(32'h0A8,32'h12345678);
        read_check(32'h06C,32'h00000003);
        read_check(32'h0A8,32'h12345679);
        read_check(32'h070,32'h00112233);
        triggers_missed_total=64'hABCDEF02_55667788;
        read_check(32'h0AC,32'hABCDEF01);
        read_check(32'h070,32'h55667788);
        read_check(32'h0AC,32'hABCDEF02);

        grp("clear statistics permission, hardware stats are external");
        allow_clear_stats=0;
        prior_count=clear_stats_pulses;
        axi_write(32'h000,32'h00000008,4'h1,0,0,2'b10);
        ck(clear_stats_pulses,prior_count,"CLEAR_STATS rejected while busy");
        allow_clear_stats=1;
        axi_write(32'h000,32'h00000008,4'h1,0,0,2'b00);
        repeat (2) @(negedge clk);
        ck(clear_stats_pulses,prior_count+1,"CLEAR_STATS accepted once");
        read_check(32'h068,32'd7); // External counter owner performs its own reset.

        $display("PASS: %0d groups, %0d checks",groups,checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"TIMEOUT at %0t",$time);
    end
endmodule
