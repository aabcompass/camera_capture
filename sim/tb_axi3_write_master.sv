`timescale 1ns/1ps
`default_nettype none
module tb_axi3_write_master;
    logic clk = 0;
    always #2.5 clk = ~clk;
    logic rst = 1;
    logic start = 0;
    logic halt_new = 0;
    logic [31:0] start_addr = 32'h1000_0000;
    logic [31:0] mem_base_addr = 32'h1000_0000;
    logic [31:0] mem_buffer_bytes = 32'h0010_0000;

    logic [17:0] n_frames = 18'd2;
    logic [31:0] header_id = 32'h44332211;
    logic [31:0] fragment_index = 0;
    logic [63:0] timestamp = 64'h0102030405060708;
    logic [63:0] trigger_data = 64'h8877665544332211;
    logic [255:0] aux_data = {
        64'h7777777788888888, 64'h5555555566666666,
        64'h3333333344444444, 64'h1111111122222222
    };
    logic stop_target_valid = 0;
    logic [17:0] stop_target_frames = 0;
    logic abort = 0;
    logic [64:0] in_data = 0;
    logic in_valid = 0;
    wire in_ready;
    wire burst_valid, burst_ready, burst_is_preamble, burst_ends_frame;
    wire [3:0] burst_word_count_minus_one;
    wire [63:0] p_wdata;
    wire p_wvalid, p_wready, p_wlast;
    wire packer_active, packer_done, format_error, target_error;
    wire [17:0] frames_packed, frames_sent;
    wire [31:0] bursts_sent;

    wire [5:0] m_axi_awid, m_axi_wid, m_axi_bid;
    wire [31:0] m_axi_awaddr;
    wire [3:0] m_axi_awlen, m_axi_awcache;
    wire [2:0] m_axi_awsize, m_axi_awprot;
    wire [1:0] m_axi_awburst, m_axi_awlock;
    wire m_axi_awvalid, m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    wire m_axi_wlast, m_axi_wvalid, m_axi_wready;
    wire [1:0] m_axi_bresp;
    wire m_axi_bvalid, m_axi_bready;
    wire writer_active, drain_done, writer_done;
    wire range_error, bresp_error, protocol_error;
    wire [31:0] last_error_addr, current_write_addr;
    wire [1:0] last_bresp;
    wire [2:0] outstanding;
    wire [31:0] bursts_issued, bursts_w_sent, bursts_committed;
    wire [17:0] frames_committed;
    wire preamble_committed;

    burst_packer packer (
        .clk(clk),.rst(rst),.start(start),.abort(abort),
        .n_frames(n_frames),.header_id(header_id),
        .fragment_index(fragment_index),.timestamp(timestamp),
        .trigger_data(trigger_data),.aux_data(aux_data),
        .stop_target_valid(stop_target_valid),.stop_target_frames(stop_target_frames),
        .in_data(in_data),.in_valid(in_valid),.in_ready(in_ready),
        .burst_valid(burst_valid),.burst_ready(burst_ready),
        .burst_is_preamble(burst_is_preamble),.burst_ends_frame(burst_ends_frame),
        .burst_word_count_minus_one(burst_word_count_minus_one),
        .w_data(p_wdata),.w_valid(p_wvalid),.w_ready(p_wready),.w_last(p_wlast),
        .active(packer_active),.packer_done(packer_done),
        .format_error(format_error),.target_error(target_error),
        .frames_packed(frames_packed),.frames_sent(frames_sent),
        .bursts_sent(bursts_sent)
    );
    axi3_write_master dut (
        .clk(clk),.rst(rst),.start(start),.halt_new(halt_new),
        .start_addr(start_addr),.mem_base_addr(mem_base_addr),
        .mem_buffer_bytes(mem_buffer_bytes),.packer_done(packer_done),
        .burst_valid(burst_valid),.burst_ready(burst_ready),
        .burst_is_preamble(burst_is_preamble),.burst_ends_frame(burst_ends_frame),
        .burst_word_count_minus_one(burst_word_count_minus_one),
        .p_wdata(p_wdata),.p_wvalid(p_wvalid),.p_wready(p_wready),.p_wlast(p_wlast),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),.m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wid(m_axi_wid),.m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .active(writer_active),.drain_done(drain_done),.writer_done(writer_done),
        .range_error(range_error),.bresp_error(bresp_error),
        .protocol_error(protocol_error),.last_error_addr(last_error_addr),
        .last_bresp(last_bresp),.outstanding(outstanding),
        .bursts_issued(bursts_issued),.bursts_w_sent(bursts_w_sent),
        .bursts_committed(bursts_committed),.frames_committed(frames_committed),
        .preamble_committed(preamble_committed),.current_write_addr(current_write_addr)
    );

    // Minimal independent AXI3 slave: AW and W are accepted independently;
    // B is only generated after both AW and all sixteen W beats have arrived.
    localparam integer MAXB = 256;
    logic [31:0] rx_addr [0:MAXB-1];
    logic [63:0] rx_words [0:MAXB-1][0:15];
    logic [MAXB-1:0] aw_seen = '0;
    logic [MAXB-1:0] w_seen = '0;
    integer aw_rx = 0;
    integer w_burst_rx = 0;
    integer w_beat_rx = 0;
    integer b_rx = 0;
    integer tick = 0;
    integer group_count = 0, check_count = 0;
    integer max_outstanding = 0;
    logic saw_w_before_aw = 0;
    integer injected_b_index = -1;
    logic [1:0] injected_bresp = 2'b10;
    logic stall_aw = 0, stall_w = 0, hold_b = 0;
    logic prev_aw_stall = 0, prev_w_stall = 0;
    logic [31:0] old_awaddr;
    logic [63:0] old_wdata;
    logic old_wlast;

    assign m_axi_awready = !rst && !stall_aw && ((tick % 7) != 0);
    assign m_axi_wready = !rst && !stall_w && ((tick % 5) != 0) && ((tick % 13) != 0);
    assign m_axi_bid = 6'd0;
    assign m_axi_bvalid = !rst && !hold_b && b_rx < MAXB &&
                          aw_seen[b_rx] && w_seen[b_rx] && ((tick % 4) != 0);
    assign m_axi_bresp = (b_rx == injected_b_index) ? injected_bresp : 2'b00;

    function automatic [63:0] science_word(input integer f, input integer w);
        science_word = {32'habcd1000 + 32'(f), 32'(w)};
    endfunction
    function automatic [63:0] header_word(input integer idx);
        case(idx)
            0: header_word = {fragment_index,header_id};
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
        tick <= tick + 1;
        if (rst) begin
            aw_rx = 0;
            w_burst_rx = 0;
            w_beat_rx = 0;
            b_rx <= 0;
            aw_seen <= '0;
            w_seen <= '0;
            max_outstanding = 0;
            saw_w_before_aw = 0;
            prev_aw_stall = 0;
            prev_w_stall = 0;
        end else begin
            if (prev_aw_stall && (!m_axi_awvalid || m_axi_awaddr !== old_awaddr))
                $fatal(1,"AW changed while stalled");
            if (prev_w_stall && (!m_axi_wvalid || m_axi_wdata !== old_wdata || m_axi_wlast !== old_wlast))
                $fatal(1,"W changed while stalled");
            prev_aw_stall = m_axi_awvalid && !m_axi_awready;
            old_awaddr = m_axi_awaddr;
            prev_w_stall = m_axi_wvalid && !m_axi_wready;
            old_wdata = m_axi_wdata;
            old_wlast = m_axi_wlast;
            check_count = check_count + 2;

            if (outstanding > max_outstanding)
                max_outstanding = outstanding;
            if (outstanding > 4) $fatal(1,"More than four outstanding");
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw_rx >= MAXB) $fatal(1,"AW model array overflow");
                if (m_axi_awid !== 6'd0 || m_axi_awlen !== 4'd15 ||
                    m_axi_awsize !== 3'd3 || m_axi_awburst !== 2'b01 ||
                    m_axi_awlock !== 2'b00 || m_axi_awaddr[6:0] != 0 ||
                    m_axi_awaddr[11:0] > 12'd3968)
                    $fatal(1,"AXI3 AW parameters invalid on burst %0d",aw_rx);
                rx_addr[aw_rx] = m_axi_awaddr;
                aw_seen[aw_rx] <= 1;
                aw_rx = aw_rx + 1;
                check_count = check_count + 7;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (aw_rx == 0) saw_w_before_aw = 1;
                if (w_burst_rx >= MAXB) $fatal(1,"W model array overflow");
                if (m_axi_wstrb !== 8'hff || m_axi_wid !== 6'd0 ||
                    m_axi_wlast !== (w_beat_rx == 15))
                    $fatal(1,"AXI3 W parameters invalid burst %0d beat %0d",w_burst_rx,w_beat_rx);
                rx_words[w_burst_rx][w_beat_rx] = m_axi_wdata;
                check_count = check_count + 3;
                if (w_beat_rx == 15) begin
                    w_seen[w_burst_rx] <= 1;
                    w_burst_rx = w_burst_rx + 1;
                    w_beat_rx = 0;
                end else
                    w_beat_rx = w_beat_rx + 1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                if (b_rx >= aw_rx || b_rx >= w_burst_rx)
                    $fatal(1,"B response preceded AW/W completion");
                b_rx <= b_rx + 1;
                check_count = check_count + 1;
            end
        end
    end

    task automatic reset_all;
        @(negedge clk);
        rst=1;
        in_valid=0;
        start=0;
        abort=0;
        halt_new=0;
        stop_target_valid=0;
        stall_aw=0;
        stall_w=0;
        hold_b=0;
        injected_b_index=-1;
        mem_buffer_bytes=32'h0010_0000;
        repeat(5) @(negedge clk);
        rst=0;
        repeat(2) @(negedge clk);
    endtask
    task automatic launch(input integer frames, input integer frag_index);
        @(negedge clk);
        n_frames=18'(frames);
        fragment_index=32'(frag_index);
        start=1;
        @(negedge clk);
        start=0;
    endtask
    task automatic send_frames(input integer frames);
        for (integer f=0;f<frames;f=f+1) begin
            for (integer w=0;w<96;w=w+1) begin
                @(negedge clk);
                in_data={w==95,science_word(f,w)};
                in_valid=1;
                do begin
                    @(posedge clk);
                end while (!in_ready);
            end
        end
        @(negedge clk);
        in_valid=0;
    endtask
    task automatic check_memory(input integer frames, input integer expected_bursts);
        logic [63:0] expected_data;
        integer abs_index, science_index;
        if (aw_rx != expected_bursts || w_burst_rx != expected_bursts || b_rx != expected_bursts)
            $fatal(1,"burst totals AW/W/B=%0d/%0d/%0d expected %0d",aw_rx,w_burst_rx,b_rx,expected_bursts);
        for (integer i=0;i<expected_bursts;i=i+1) begin
            if (rx_addr[i] !== (start_addr + 32'(128*i)))
                $fatal(1,"AWADDR[%0d] got %08h expected %08h",i,rx_addr[i],start_addr+32'(128*i));
            check_count=check_count+1;
            for (integer j=0;j<16;j=j+1) begin
                abs_index=i*16+j;
                if (abs_index<16)
                    expected_data=header_word(abs_index);
                else begin
                    science_index=abs_index-16;
                    expected_data=science_word(science_index/96,science_index%96);
                end
                if (rx_words[i][j] !== expected_data)
                    $fatal(1,"DATA[%0d][%0d] got %016h expected %016h",i,j,rx_words[i][j],expected_data);
                check_count=check_count+1;
            end
        end
        if (frames>0 && expected_bursts != (1+frames*6))
            $fatal(1,"incorrect frame/burst test expectation");
    endtask
    task automatic wait_good(input integer frames);
        integer cycles = 0;
        @(negedge clk);
        while (!writer_done && cycles < 200000) begin
            @(negedge clk); cycles=cycles+1;
        end
        if (!writer_done) $fatal(1,"writer_done timeout, status: AW=%0d W=%0d B=%0d outstanding=%0d",aw_rx,w_burst_rx,b_rx,outstanding);
        if (!packer_done || format_error || target_error || range_error || bresp_error || protocol_error)
            $fatal(1,"unexpected status: packer=%0d format=%0d target=%0d range=%0d bresp=%0d proto=%0d",packer_done,format_error,target_error,range_error,bresp_error,protocol_error);
        if (bursts_issued != 1+6*frames || bursts_w_sent != 1+6*frames ||
            bursts_committed != 1+6*frames || frames_committed != frames || !preamble_committed)
            $fatal(1,"writer counters incorrect");
        check_memory(frames,1+6*frames);
        group_count=group_count+1;
        check_count=check_count+7;
    endtask
    task automatic wait_drain;
        integer cycles = 0;
        @(negedge clk);
        while (!drain_done && cycles < 200000) begin
            @(negedge clk); cycles=cycles+1;
        end
        if (!drain_done) $fatal(1,"drain timeout: AW=%0d W=%0d B=%0d",aw_rx,w_burst_rx,b_rx);
        repeat(2) @(negedge clk);
    endtask

    // drain_done means "no AXI transaction is pending RIGHT NOW".
    // During normal streaming it may pulse between bursts. For tests that
    // require the final BRESP, wait for the exact response count as well.
    task automatic wait_responses_and_drain(input integer expected_responses);
        integer cycles;
        cycles = 0;
        @(negedge clk);
        while ((b_rx < expected_responses || !drain_done) && cycles < 200000) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (b_rx != expected_responses || !drain_done)
            $fatal(1,"response drain timeout: expected B=%0d actual AW/W/B=%0d/%0d/%0d outstanding=%0d drain_done=%0b fault=%0b",
                   expected_responses, aw_rx, w_burst_rx, b_rx, outstanding, drain_done, bresp_error);
        repeat(2) @(negedge clk);
    endtask

    initial begin
        $display("[TEST] 2 frames, preamble + 12 AXI3 bursts, DDR word-level compare");
        reset_all(); launch(2,0); send_frames(2); wait_good(2);

        $display("[TEST] 3 frames, AWREADY stalls");
        reset_all(); launch(3,1); stall_aw=1;
        fork
            send_frames(3);
            begin repeat(95) @(negedge clk); stall_aw=0; end
        join
        wait_good(3);
        if (!saw_w_before_aw) $fatal(1,"AW stall did not prove W-channel independence");

        $display("[TEST] 3 frames, WREADY held low with AW independent");
        reset_all(); launch(3,2); stall_w=1;
        fork
            send_frames(3);
            begin repeat(120) @(negedge clk); stall_w=0; end
        join
        wait_good(3);

        $display("[TEST] four outstanding, delayed BRESP saturation and release");
        reset_all(); launch(8,3); hold_b=1;
        fork
            send_frames(8);
            begin
                integer timeout=0;
                while (max_outstanding<4 && timeout<100000) begin
                    @(negedge clk); timeout=timeout+1;
                end
                if (max_outstanding<4) $fatal(1,"outstanding never reached four");
                repeat(40) @(negedge clk);
                hold_b=0;
            end
        join
        wait_good(8);
        if (max_outstanding != 4) $fatal(1,"peak outstanding != 4");

        $display("[TEST] long 12-frame sequence with AW/W/B stalls");
        reset_all(); launch(12,4); send_frames(12); wait_good(12);

        $display("[TEST] STOP boundary: programmed 5, effective 3 full frames");
        reset_all(); launch(5,5);
        @(negedge clk); stop_target_frames=18'd3; stop_target_valid=1;
        @(negedge clk); stop_target_valid=0;
        send_frames(3); wait_good(3);

        $display("[TEST] injected SLVERR in final BRESP, completion rejected");
        reset_all(); injected_b_index=12; injected_bresp=2'b10;
        launch(2,6); send_frames(2); wait_responses_and_drain(13);
        if (!bresp_error || last_bresp != 2'b10 || writer_done ||
            bursts_committed != 12 || frames_committed != 1 ||
            last_error_addr !== start_addr+32'(12*128)) begin
            $display("SLVERR DIAG: AW/W/B=%0d/%0d/%0d outstanding=%0d drain_done=%0b packer_done=%0b",
                     aw_rx, w_burst_rx, b_rx, outstanding, drain_done, packer_done);
            $display("SLVERR DIAG: bresp_error=%0b last_bresp=%02b writer_done=%0b",
                     bresp_error, last_bresp, writer_done);
            $display("SLVERR DIAG: bursts_committed=%0d frames_committed=%0d last_error_addr=%08h expected=%08h",
                     bursts_committed, frames_committed, last_error_addr, start_addr+32'(12*128));
            $fatal(1,"SLVERR response handling failed (see diagnostic values above)");
        end
        check_memory(2,13);
        group_count=group_count+1;

        $display("[TEST] per-burst memory guard blocks first out-of-range AW");
        reset_all(); mem_buffer_bytes=32'(12*128); launch(2,7);
        send_frames(2);
        begin : range_wait
            integer t=0;
            while (!range_error && t<100000) begin @(negedge clk); t=t+1; end
            if (!range_error) $fatal(1,"range guard never fired");
        end
        wait_drain();
        if (aw_rx!=12 || w_burst_rx!=12 || b_rx!=12 || writer_done ||
            bursts_committed != 12 || frames_committed != 1 ||
            last_error_addr !== start_addr+32'(12*128))
            $fatal(1,"range guard failed: AW/W/B=%0d/%0d/%0d addr=%h",aw_rx,w_burst_rx,b_rx,last_error_addr);
        group_count=group_count+1;

        $display("[TEST] halt_new drains an already accepted burst");
        reset_all(); launch(2,8);
        begin : halt_wait
            integer t=0;
            while (bursts_issued<1 && t<100000) begin @(negedge clk); t=t+1; end
            if (bursts_issued!=1) $fatal(1,"preamble AW never sent");
        end
        @(negedge clk); halt_new=1;
        wait_drain();
        if (aw_rx!=1 || w_burst_rx!=1 || b_rx!=1 || !preamble_committed || writer_done)
            $fatal(1,"halt_new did not finish outstanding preamble");
        group_count=group_count+1;

        $display("PASS: %0d groups, %0d checks",group_count,check_count);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"global testbench timeout");
    end
endmodule
`default_nettype wire