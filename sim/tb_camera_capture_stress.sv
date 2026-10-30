`timescale 1ns/1ps
`default_nettype none
// Camera Data Capture IP: extended top-level self-checking tests.
// Vivado 2023.1 XSIM. No changes to checked RTL modules.
module tb_camera_capture_stress;
    localparam bit TB_USE_XPM = 1'b1;      // Change to 0 for behavioral FIFO.
    localparam bit RUN_LONG_TEST = 1'b1;    // Change to 1 for 1000-frame stress.
    localparam integer MAX_BURSTS = 6500; // 1000 frames = 6001 bursts.
    localparam logic [31:0] BASE_MULTI = 32'h1000_0000;
    localparam logic [31:0] BASE_STOP  = 32'h1100_0000;
    localparam logic [31:0] BASE_LONG  = 32'h1200_0000;
    localparam logic [63:0] TIME_VALUE = 64'h1122_3344_5566_7788;
    localparam logic [63:0] TRIG_VALUE = 64'hA5A5_0000_1234_5678;
    localparam logic [31:0] HEADER_ID  = 32'h1234_ABCD;
    localparam logic [31:0] AUX0 = 32'hABCDEF01;

    logic clk = 1'b0;
    always #2.5 clk = ~clk;
    logic rst = 1'b1;
    logic [63:0] s_axis_tdata = 0;
    logic s_axis_tvalid = 0, s_axis_tlast = 0;
    wire s_axis_tready;
    logic [63:0] s_axis_trg_tdata = 0;
    logic s_axis_trg_tvalid = 0, ext_trig = 0;
    logic [63:0] timestamp = TIME_VALUE;

    logic [31:0] s_axi_awaddr=0, s_axi_wdata=0, s_axi_araddr=0;
    logic [2:0] s_axi_awprot=0, s_axi_arprot=0;
    logic [3:0] s_axi_wstrb=4'hF;
    logic s_axi_awvalid=0, s_axi_wvalid=0, s_axi_bready=0;
    logic s_axi_arvalid=0, s_axi_rready=0;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;

    wire [5:0] m_axi_awid, m_axi_wid;
    logic [5:0] m_axi_bid=0;
    wire [31:0] m_axi_awaddr;
    wire [3:0] m_axi_awlen, m_axi_awcache;
    wire [2:0] m_axi_awsize, m_axi_awprot;
    wire [1:0] m_axi_awburst, m_axi_awlock;
    wire m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    wire m_axi_awready, m_axi_wready;
    logic [1:0] m_axi_bresp = 0;
    wire m_axi_bvalid;

    camera_capture_top #(.USE_XPM(TB_USE_XPM)) dut (.*);

    // AXI3 in-order slave model. AW and W are independently throttled.
    // B may be returned only after both channels have finished that burst.
    logic [31:0] rx_addr [0:MAX_BURSTS-1];
    logic [63:0] rx_word [0:MAX_BURSTS-1][0:15];
    logic [MAX_BURSTS-1:0] aw_seen='0, w_seen='0;
    integer aw_rx=0, wb_rx=0, wi_rx=0, b_rx=0;
    integer tick=0;
    logic use_stalls=0;
    logic force_w_stop=0;
    logic [31:0] expected_base=BASE_MULTI;
    integer total_checks=0;
    integer groups=0;

    assign m_axi_awready = !rst && (!use_stalls || ((tick%11)<8));
    assign m_axi_wready  = !rst && !force_w_stop && (!use_stalls || ((tick%13)<9));
    assign m_axi_bvalid  = !rst && b_rx<MAX_BURSTS &&
                           aw_seen[b_rx] && w_seen[b_rx] &&
                           (!use_stalls || ((tick%17)<14));

    always @(posedge clk) begin
        tick <= tick + 1;
        if (rst) begin
            aw_rx=0; wb_rx=0; wi_rx=0; b_rx=0;
            aw_seen<='0; w_seen<='0;
        end else begin
            if (s_axis_tready !== 1'b1)
                $fatal(1,"S_AXIS_TREADY dropped at t=%0t",$time);
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw_rx>=MAX_BURSTS ||
                    m_axi_awaddr !== expected_base+32'(aw_rx*128) ||
                    m_axi_awlen !== 4'd15 || m_axi_awsize !== 3'd3 ||
                    m_axi_awburst !== 2'b01 || m_axi_awaddr[6:0] !== 7'd0 ||
                    m_axi_awid !== 6'd0)
                    $fatal(1,"Unexpected AW #%0d addr=%08h expected=%08h",aw_rx,
                           m_axi_awaddr,expected_base+32'(aw_rx*128));
                rx_addr[aw_rx]=m_axi_awaddr;
                aw_seen[aw_rx]<=1'b1;
                aw_rx=aw_rx+1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (wb_rx>=MAX_BURSTS || m_axi_wstrb !== 8'hFF ||
                    m_axi_wlast !== (wi_rx==15) || m_axi_wid !== 6'd0)
                    $fatal(1,"Unexpected W burst=%0d beat=%0d",wb_rx,wi_rx);
                rx_word[wb_rx][wi_rx]=m_axi_wdata;
                if (wi_rx==15) begin
                    w_seen[wb_rx]<=1'b1;
                    wb_rx=wb_rx+1;
                    wi_rx=0;
                end else wi_rx=wi_rx+1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                if (b_rx>=aw_rx || b_rx>=wb_rx)
                    $fatal(1,"BRESP before AW/W accepted b=%0d aw=%0d w=%0d",b_rx,aw_rx,wb_rx);
                b_rx=b_rx+1;
            end
        end
    end

    task automatic check(input bit condition, input string label);
        total_checks++;
        if (!condition) $fatal(1,"CHECK FAILED: %s, t=%0t, state=%0d",label,$time,dut.fsm_state);
    endtask
    task automatic check_word(input logic [63:0] got, input logic [63:0] expected,
                              input string label);
        total_checks++;
        if (got !== expected)
            $fatal(1,"%s: got=%016h expected=%016h t=%0t",label,got,expected,$time);
    endtask

    task automatic reset_system(input logic [31:0] base);
        @(negedge clk);
        rst=1; use_stalls=0; force_w_stop=0; expected_base=base;
        s_axis_tdata=0; s_axis_tvalid=0; s_axis_tlast=0;
        s_axis_trg_tdata=0; s_axis_trg_tvalid=0; ext_trig=0; timestamp=TIME_VALUE;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_arvalid=0;
        s_axi_bready=0; s_axi_rready=0;
        repeat(15) @(negedge clk);
        rst=0;
        repeat(5) @(negedge clk);
    endtask

    task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
        @(negedge clk);
        s_axi_awaddr=addr; s_axi_awvalid=1;
        s_axi_wdata=data; s_axi_wstrb=4'hF; s_axi_wvalid=1;
        fork
            begin
                do @(posedge clk); while(!s_axi_awready);
                @(negedge clk); s_axi_awvalid=0;
            end
            begin
                do @(posedge clk); while(!s_axi_wready);
                @(negedge clk); s_axi_wvalid=0;
            end
        join
        do @(posedge clk); while(!s_axi_bvalid);
        if (s_axi_bresp !== 2'b00)
            $fatal(1,"AXIL write addr=%08h resp=%b",addr,s_axi_bresp);
        @(negedge clk); s_axi_bready=1;
        @(negedge clk); s_axi_bready=0;
    endtask

    task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(negedge clk); s_axi_araddr=addr; s_axi_arvalid=1;
        do @(posedge clk); while(!s_axi_arready);
        @(negedge clk); s_axi_arvalid=0;
        do @(posedge clk); while(!s_axi_rvalid);
        if (s_axi_rresp !== 2'b00)
            $fatal(1,"AXIL read addr=%08h resp=%b",addr,s_axi_rresp);
        data=s_axi_rdata;
        @(negedge clk); s_axi_rready=1;
        @(negedge clk); s_axi_rready=0;
    endtask

    task automatic configure_run(input logic [31:0] base, input integer nframes,
                                 input integer nprev, input integer nfragments);
        axi_write(32'h00C,32'd1);
        axi_write(32'h010,32'(nframes));
        axi_write(32'h014,32'(nprev));
        axi_write(32'h018,32'(nfragments));
        axi_write(32'h01C,base);
        axi_write(32'h0B4,32'h0100_0000);  // 16 MiB, sufficient for all tests.
        axi_write(32'h020,HEADER_ID);
        axi_write(32'h024,AUX0);
        axi_write(32'h000,32'd1);
    endtask

    task automatic wait_state(input logic [3:0] target, input integer timeout_cycles);
        integer t;
        t=0;
        while (dut.fsm_state !== target && t<timeout_cycles) begin
            @(negedge clk); t++;
        end
        if (dut.fsm_state !== target)
            $fatal(1,"Timeout awaiting state %0d (now %0d) at t=%0t, captured=%0d committed=%0d",
                   target,dut.fsm_state,$time,dut.frames_captured,dut.writer_frames_committed);
    endtask

    function automatic [63:0] science_word(input integer f, input integer w);
        science_word={32'hDA7A0000 + 32'(f),32'(w)};
    endfunction
    task automatic send_frame(input integer f, input integer trigger_word,
                              input integer gap_cycles);
        for (integer w=0; w<96; w++) begin
            @(negedge clk);
            s_axis_tdata=science_word(f,w);
            s_axis_tvalid=1;
            s_axis_tlast=(w==95);
            s_axis_trg_tvalid=(w==trigger_word);
            s_axis_trg_tdata=(w==trigger_word) ? TRIG_VALUE : 64'd0;
            timestamp=TIME_VALUE;
        end
        @(negedge clk);
        s_axis_tvalid=0; s_axis_tlast=0;
        s_axis_trg_tvalid=0; s_axis_trg_tdata=0;
        repeat(gap_cycles) @(negedge clk);
    endtask
    task automatic pulse_trigger_between_frames();
        @(negedge clk);
        check(!s_axis_tvalid,"trigger intended between frames");
        s_axis_trg_tvalid=1; s_axis_trg_tdata=TRIG_VALUE;
        timestamp=TIME_VALUE;
        @(negedge clk);
        s_axis_trg_tvalid=0; s_axis_trg_tdata=0;
    endtask

    // Compare complete DDR contents (including 128-byte preamble).
    task automatic verify_fragment(input integer first_frame, input integer nframes,
                                   input integer frag_no, input integer burst_offset);
        integer burst_total;
        integer global_word;
        integer frame_data_pos;
        integer k;
        logic [63:0] expected;
        burst_total=1+6*nframes;
        for (k=0; k<burst_total*16; k++) begin
            expected=0;
            if (k==0) expected={32'(frag_no),HEADER_ID};
            else if (k==1) expected=TIME_VALUE;
            else if (k==2) expected=TRIG_VALUE;
            else if (k==3) expected={32'd0,AUX0};
            else if (k>=7 && k<16) expected=64'h1234567812345678;
            else if (k>=16) begin
                frame_data_pos=k-16;
                expected=science_word(first_frame+frame_data_pos/96,frame_data_pos%96);
            end
            global_word=burst_offset*16+k;
            check_word(rx_word[global_word/16][global_word%16],expected,"DDR science/preamble");
        end
    endtask
    task automatic verify_total_bursts(input integer count);
        check(aw_rx==count && wb_rx==count && b_rx==count,
              $sformatf("burst count actual AW/W/B=%0d/%0d/%0d expected %0d",
                        aw_rx,wb_rx,b_rx,count));
    endtask

    initial begin : main_test
        logic [31:0] rd;
        integer base_f;
        integer frag_bursts;
        integer group_start;

        $display("[TEST] multiple full fragments, sliding n_prev=4, trigger on beat/TLAST/between frames");
        reset_system(BASE_MULTI);
        use_stalls=1;
        configure_run(BASE_MULTI,7,4,3);
        frag_bursts=1+7*6;
        for (integer fragment=0; fragment<3; fragment++) begin
            base_f=fragment*20;
            wait_state(4'd1,20000);
            send_frame(base_f,-1,3);            // Resynchronization frame; discarded.
            for(integer pre=1; pre<=4; pre++)
                send_frame(base_f+pre,-1,3);
            wait_state(4'd2,20000);
            if(fragment==2) begin
                pulse_trigger_between_frames();
                send_frame(base_f+5,-1,3);
            end else
                send_frame(base_f+5,(fragment==0) ? 37 : 95,3);
            send_frame(base_f+6,-1,3);
            send_frame(base_f+7,-1,3);
            if(fragment!=2) wait_state(4'd1,100000);
        end
        wait_state(4'd6,100000);
        verify_total_bursts(3*frag_bursts);
        for(integer fragment=0;fragment<3;fragment++)
            verify_fragment(fragment*20+1,7,fragment,fragment*frag_bursts);
        axi_read(32'h068,rd); check(rd==3,"total fragments completed = 3");
        axi_read(32'h0A4,rd); check(rd==3,"run fragments completed = 3");
        axi_read(32'h008,rd); check(rd==0,"no errors after three fragments");
        axi_read(32'h06C,rd); check(rd==3,"three algorithmic triggers accepted");
        groups++;

        $display("[TEST] STOP mid-frame, do not send another frame, DDR contains only whole frames");
        reset_system(BASE_STOP);
        use_stalls=1;
        configure_run(BASE_STOP,8,1,1);
        wait_state(4'd1,20000);
        send_frame(100,-1,3);  // sync
        send_frame(101,-1,3);  // prev
        wait_state(4'd2,20000);
        send_frame(102,37,3); // first post
        send_frame(103,-1,3);
        fork
            begin
                send_frame(104,-1,3);
            end
            begin
                wait(s_axis_tvalid && s_axis_tdata === science_word(104,40));
                axi_write(32'h000,32'd2); // STOP while frame 104 is being received
            end
        join
        wait_state(4'd0,100000);
        verify_total_bursts(1+6*4);
        verify_fragment(101,4,0,0);
        axi_read(32'h0A0,rd); check(rd==2,"last fragment STOPPED");
        axi_read(32'h098,rd); check(rd==4,"last fragment has four frames");
        axi_read(32'h09C,rd); check(rd==128+768*4,"last fragment byte count");
        axi_read(32'h068,rd); check(rd==0,"STOP does not count as full fragment");
        axi_read(32'h008,rd); check(rd==0,"STOP without errors");
        groups++;

        if(RUN_LONG_TEST) begin
            $display("[TEST] 1000 full frames at camera rate: 96 beats per 500 clocks, n_prev=64");
            reset_system(BASE_LONG);
            use_stalls=1;
            configure_run(BASE_LONG,1000,64,1);
            wait_state(4'd1,20000);
            send_frame(100,-1,403); // sync frame
            for(integer f=101;f<=164;f++) send_frame(f,-1,403);
            wait_state(4'd2,20000);
            send_frame(165,37,403);
            for(integer f=166;f<=1100;f++) send_frame(f,-1,403);
            wait_state(4'd6,1000000);
            verify_total_bursts(1+6*1000);
            verify_fragment(101,1000,0,0);
            axi_read(32'h008,rd); check(rd==0,"1000 frames no errors");
            axi_read(32'h068,rd); check(rd==1,"1000-frame fragment committed");
            groups++;
        end
        $display("PASS: top-level stress, %0d groups, %0d checks, XPM=%0d, LONG=%0d",
                 groups,total_checks,TB_USE_XPM,RUN_LONG_TEST);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"Top-level stress global timeout");
    end
endmodule
`default_nettype wire
