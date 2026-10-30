`timescale 1ns/1ps
`default_nettype none
// Camera Data Capture IP: extended top-level self-checking tests.
// Vivado 2023.1 XSIM. No changes to checked RTL modules.
module tb_camera_capture_faults;
    localparam bit TB_USE_XPM = 1'b1;      // Change to 0 for behavioral FIFO.
        localparam integer MAX_BURSTS = 6500; // 1000 frames = 6001 bursts.
    localparam logic [31:0] BASE_MULTI = 32'h1000_0000;
    localparam logic [31:0] BASE_STOP  = 32'h1100_0000;
    localparam logic [31:0] BASE_SLV   = 32'h1300_0000;
    localparam logic [31:0] BASE_DEC   = 32'h1400_0000;
    localparam logic [31:0] BASE_OVF   = 32'h1500_0000;
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
    wire [1:0] m_axi_bresp;
    logic inject_bresp=0;
    logic [1:0] inject_bresp_code=2'b00;
    integer inject_bresp_index=-1;
    assign m_axi_bresp = (inject_bresp && b_rx==inject_bresp_index) ?
                         inject_bresp_code : 2'b00;
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
        inject_bresp=0; inject_bresp_code=2'b00; inject_bresp_index=-1;
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


    // Error-path integration tests; deliberately retain previous verified RTL.
    // Every test is isolated by reset_system except explicit CLEAR_ERROR.
    initial begin : main_test
        logic [31:0] rd;

        $display("[TEST] SLVERR in last BRESP: ERROR, incomplete fragment, no false completion");
        reset_system(BASE_SLV);
        configure_run(BASE_SLV,2,1,1);
        wait_state(4'd1,20000);
        send_frame(100,-1,3); // sync discarded
        send_frame(101,-1,3); // one complete PRE
        wait_state(4'd2,20000);
        inject_bresp=1;
        inject_bresp_code=2'b10; // SLVERR
        inject_bresp_index=12;  // 1 preamble + 2*6 frame bursts = 13 responses
        send_frame(102,37,3);
        wait_state(4'd5,100000);
        verify_total_bursts(13);
        axi_read(32'h008,rd); check((rd & 32'h2)!=0,"SLVERR sticky flag");
        axi_read(32'h0A0,rd); check(rd==3,"SLVERR marks fragment ERROR");
        axi_read(32'h09C,rd); check(rd==0,"ERROR fragment has no trusted size");
        axi_read(32'h098,rd); check(rd==1,"first frame committed, second failed BRESP");
        axi_read(32'h068,rd); check(rd==0,"SLVERR must not count a completed fragment");
        axi_read(32'h078,rd); check(rd>=1,"SLVERR counted as AXI fault episode");
        axi_read(32'h054,rd); check(rd==BASE_SLV+12*128,"SLVERR exact burst address");
        check(dut.writer_outstanding==0,"no outstanding AW after error drain");
        groups++;

        $display("[TEST] CLEAR_ERROR from ERROR permits a new START, without hardware reset");
        inject_bresp=0;
        // The FSM must complete FIFO flush before clear is accepted.
        repeat(30) @(negedge clk);
        axi_write(32'h000,32'h4); // CLEAR_ERROR
        wait_state(4'd0,20000);
        axi_read(32'h008,rd); check(rd==0,"error flags cleared");
        // Restart with the same configuration; do not emit a new AXI write.
        axi_write(32'h000,32'h1); // START
        wait_state(4'd1,20000);
        check(dut.fsm_state==4'd1,"START accepted after clear error");
        // STOP during FILL, before a new trigger: should return to IDLE.
        axi_write(32'h000,32'h2);
        wait_state(4'd0,20000);
        groups++;

        $display("[TEST] DECERR in last BRESP: distinct error flag and last address");
        reset_system(BASE_DEC);
        configure_run(BASE_DEC,2,1,1);
        wait_state(4'd1,20000);
        send_frame(200,-1,3);
        send_frame(201,-1,3);
        wait_state(4'd2,20000);
        inject_bresp=1;
        inject_bresp_code=2'b11; // DECERR
        inject_bresp_index=12;
        send_frame(202,67,3);
        wait_state(4'd5,100000);
        verify_total_bursts(13);
        axi_read(32'h008,rd);
        check((rd & 32'h4)!=0 && (rd & 32'h2)==0,"DECERR classified separately from SLVERR");
        axi_read(32'h050,rd); check(rd==3,"last error code DECERR");
        axi_read(32'h054,rd); check(rd==BASE_DEC+12*128,"DECERR exact burst address");
        axi_read(32'h0A0,rd); check(rd==3,"DECERR marks fragment ERROR");
        axi_read(32'h068,rd); check(rd==0,"DECERR does not count completed fragment");
        check(dut.writer_outstanding==0,"all DECERR transactions drained");
        groups++;

        $display("[TEST] FIFO OVERFLOW with WREADY low: error latched, drain only after release");
        reset_system(BASE_OVF);
        configure_run(BASE_OVF,200,64,1);
        wait_state(4'd1,20000);
        send_frame(1000,-1,3); // discarded for sync
        for(integer f=1001; f<=1064; f++) send_frame(f,-1,3);
        wait_state(4'd2,20000);
        force_w_stop=1;  // prevent all AXI W handshakes, AW may still be issued
        send_frame(1065,37,3);
        wait_state(4'd3,20000);
        // Fill until the 9600-word logical capacity is reached and exceeded.
        // Keep pushing camera data regardless of WREADY: no AXI backpressure.
        for(integer f=1066; f<=1115; f++) send_frame(f,-1,0);
        axi_read(32'h008,rd); check((rd & 32'h1)!=0,"FIFO_OVERFLOW sticky error bit");
        axi_read(32'h074,rd); check(rd>=1,"overflow error event observed");
        axi_read(32'h068,rd); check(rd==0,"no fragment completed on overflow");
        check(dut.fsm_state==4'd3,"still draining active AXI transaction with WREADY low");
        check(dut.fifo_level_words <= 14'd9600,"logical FIFO depth never exceeded");
        // Must not insist on ERROR while slave refuses a previously accepted burst.
        @(negedge clk); force_w_stop=0;
        wait_state(4'd5,200000);
        check(dut.writer_outstanding==0,"after releasing WREADY all pending AW/B drained");
        axi_read(32'h0A0,rd); check(rd==3,"overflow fragment marked ERROR");
        axi_read(32'h09C,rd); check(rd==0,"overflow has no trusted DDR size");
        axi_read(32'h050,rd); check(rd==1,"overflow last error code");
        groups++;

        $display("PASS: top-level faults, %0d groups, %0d checks, XPM=%0d",
                 groups,total_checks,TB_USE_XPM);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"Fault integration global timeout");
    end
endmodule
