`timescale 1ns/1ps
`default_nettype none
module tb_camera_capture_top;
    logic clk=1'b0;
    always #2.5 clk=~clk;
    logic rst=1'b1;
    logic [63:0] s_axis_tdata=0;
    logic s_axis_tvalid=0, s_axis_tlast=0;
    wire s_axis_tready;
    logic [63:0] s_axis_trg_tdata=0;
    logic s_axis_trg_tvalid=0, ext_trig=0;
    logic [63:0] timestamp=0;
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
    logic m_axi_awready=1, m_axi_wready=1;
    logic [1:0] m_axi_bresp=0;
    wire m_axi_bvalid;

    camera_capture_top #(.USE_XPM(1'b1)) dut (.*);
    localparam integer MAXB=80;
    logic [31:0] rx_addr [0:MAXB-1];
    logic [63:0] rx_word [0:MAXB-1][0:15];
    logic [MAXB-1:0] aw_seen='0, w_seen='0;
    integer aw_rx=0, wb_rx=0, wi_rx=0, b_rx=0;
    integer tick=0;
    assign m_axi_bvalid = !rst && b_rx < MAXB && aw_seen[b_rx] && w_seen[b_rx] && (tick % 5 != 0);

    always @(posedge clk) begin
        tick <= tick+1;
        if (rst) begin
            aw_rx=0; wb_rx=0; wi_rx=0; b_rx=0;
            aw_seen<='0; w_seen<='0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw_rx>=MAXB || m_axi_awaddr !== (32'h1000_0000 + (aw_rx*128)) ||
                    m_axi_awlen !== 4'd15 || m_axi_awsize !== 3'd3 ||
                    m_axi_awburst !== 2'b01 || m_axi_awaddr[6:0] !== 7'd0)
                    $fatal(1,"Top TB AW invalid burst=%0d addr=%08h",aw_rx,m_axi_awaddr);
                rx_addr[aw_rx]=m_axi_awaddr;
                aw_seen[aw_rx]<=1'b1;
                aw_rx=aw_rx+1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (wb_rx>=MAXB || m_axi_wstrb !== 8'hFF ||
                    m_axi_wlast !== (wi_rx==15))
                    $fatal(1,"Top TB W invalid burst=%0d beat=%0d",wb_rx,wi_rx);
                rx_word[wb_rx][wi_rx]=m_axi_wdata;
                if (wi_rx==15) begin
                    w_seen[wb_rx]<=1'b1;
                    wb_rx=wb_rx+1;
                    wi_rx=0;
                end else wi_rx=wi_rx+1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                if (b_rx >= aw_rx || b_rx >= wb_rx)
                    $fatal(1,"Top TB BRESP before AW/W completion");
                b_rx=b_rx+1;
            end
        end
    end

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
        do @(posedge clk); while (!s_axi_bvalid);
        if (s_axi_bresp !== 2'b00) $fatal(1,"AXIL write error addr=%08h resp=%b",addr,s_axi_bresp);
        @(negedge clk); s_axi_bready=1;
        @(negedge clk); s_axi_bready=0;
    endtask

    task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(negedge clk); s_axi_araddr=addr; s_axi_arvalid=1;
        do @(posedge clk); while (!s_axi_arready);
        @(negedge clk); s_axi_arvalid=0;
        do @(posedge clk); while (!s_axi_rvalid);
        if (s_axi_rresp !== 2'b00) $fatal(1,"AXIL read error addr=%08h",addr);
        data=s_axi_rdata;
        @(negedge clk); s_axi_rready=1;
        @(negedge clk); s_axi_rready=0;
    endtask

    function automatic [63:0] science_word(input integer f, input integer w);
        science_word={32'hDA7A0000 + 32'(f), 32'(w)};
    endfunction
    task automatic send_frame(input integer f, input integer trg_word);
        for (integer w=0;w<96;w=w+1) begin
            @(negedge clk);
            s_axis_tdata=science_word(f,w);
            s_axis_tvalid=1;
            s_axis_tlast=(w==95);
            s_axis_trg_tvalid=(w==trg_word);
            s_axis_trg_tdata=(w==trg_word) ? 64'hA5A5000012345678 : 0;
            timestamp=64'h1122334455667788;
        end
        @(negedge clk);
        s_axis_tvalid=0; s_axis_tlast=0; s_axis_trg_tvalid=0;
        s_axis_trg_tdata=0;
        repeat(3) @(negedge clk);
    endtask

    integer checks=0;
    task automatic check64(input logic [63:0] got, input logic [63:0] exp, input string label);
        checks++;
        if (got !== exp) $fatal(1,"%s got=%016h expected=%016h",label,got,exp);
    endtask
    initial begin : scenario
        logic [31:0] rd;
        logic [63:0] expected;
        integer science_pos;
        integer wait_cycles;
        repeat(10) @(negedge clk); rst=0;
        $display("[TEST] Top-level AXIL -> trigger -> sliding FIFO -> preamble -> AXI3 DDR");
        axi_write(32'h00C,32'd1);         // alg trigger only
        axi_write(32'h010,32'd3);         // 3 frames in fragment
        axi_write(32'h014,32'd1);         // 1 pretrigger
        axi_write(32'h018,32'd1);         // one fragment -> END
        axi_write(32'h01C,32'h10000000);
        axi_write(32'h0B4,32'h00010000);
        axi_write(32'h020,32'h1234ABCD);
        axi_write(32'h024,32'hABCDEF01);
        axi_write(32'h000,32'd1);        // START
        wait_cycles=0;
        while (dut.fsm_state != 4'd1 && wait_cycles<1000) begin
            @(negedge clk); wait_cycles++;
        end
        if (dut.fsm_state!=4'd1) $fatal(1,"FSM did not reach BUFFER_FILLING");
        repeat(10) @(negedge clk);
        send_frame(0,-1);   // sync frame is discarded up to TLAST
        send_frame(1,-1);   // pretrigger frame
        if (dut.fsm_state != 4'd2)
            $fatal(1,"FSM not in TRIG_WAIT after pretrigger, state=%0d",dut.fsm_state);
        send_frame(2,37);   // first posttrigger frame (word 37)
        send_frame(3,-1);   // second posttrigger frame
        send_frame(4,-1);   // surplus: must be ignored
        wait_cycles=0;
        while (dut.fsm_state != 4'd6 && wait_cycles<100000) begin
            @(negedge clk); wait_cycles++;
        end
        if (dut.fsm_state!=4'd6)
            $fatal(1,"END timeout state=%0d captured=%0d committed=%0d packer_done=%b writer_done=%b error=%h",dut.fsm_state,dut.frames_captured,dut.writer_frames_committed,dut.packer_done,dut.writer_done,dut.sticky_error_flags);
        axi_read(32'h008,rd);
        if (rd!==0) $fatal(1,"Error flags after end-to-end capture %08h",rd);
        axi_read(32'h068,rd);
        if (rd!==1) $fatal(1,"Fragment count should be 1, got %0d",rd);
        if (aw_rx!=19 || wb_rx!=19 || b_rx!=19)
            $fatal(1,"AW/W/B total mismatch %0d/%0d/%0d expected 19",aw_rx,wb_rx,b_rx);
        for (integer k=0;k<304;k++) begin
            expected=0;
            if (k==0) expected={32'd0,32'h1234ABCD};
            else if(k==1) expected=64'h1122334455667788;
            else if(k==2) expected=64'hA5A5000012345678;
            else if(k==3) expected=64'h00000000ABCDEF01;
            else if(k<7) expected=64'd0;
            else if(k<16) expected=64'h1234567812345678;
            else begin
                science_pos=k-16;
                expected=science_word(1+science_pos/96, science_pos%96);
            end
            check64(rx_word[k/16][k%16],expected,"DDR word compare");
        end
        $display("PASS: top-level integration smoke, %0d DDR data checks",checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"Global timeout in top-level integration test");
    end
endmodule
`default_nettype wire
