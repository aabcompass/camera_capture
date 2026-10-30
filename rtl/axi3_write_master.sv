// Camera Data Capture IP: AXI3 64-bit basic write master, revision 1.0.
// One fixed 6-bit AXI ID, 16 beats per INCR burst, maximum four AW-to-B outstanding.
// Source is the verified burst_packer: descriptor handshake FIRST, then 16 W beats.
// AW and W operate independently after descriptor handshake; W may precede AW.
// Stop_target/normal STOP are handled by burst_packer, not by halt_new.
// halt_new and internal faults prevent further descriptors, but never cancel a
// previously accepted descriptor or an already asserted AWVALID/WVALID.
// Error recovery requires draining previously accepted AW/W/B transactions;
// a permanently unresponsive slave requires a coordinated system-level reset.
`default_nettype none
module axi3_write_master #(
    parameter integer MAX_OUTSTANDING = 4
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         halt_new,        // fatal abort only; ordinary STOP leaves 0
    input  wire [31:0]  start_addr,      // 128-byte aligned fragment address
    input  wire [31:0]  mem_base_addr,
    input  wire [31:0]  mem_buffer_bytes,
    input  wire         packer_done,

    // From burst_packer
    input  wire         burst_valid,
    output wire         burst_ready,
    input  wire         burst_is_preamble,
    input  wire         burst_ends_frame,
    input  wire [3:0]   burst_word_count_minus_one,
    input  wire [63:0]  p_wdata,
    input  wire         p_wvalid,
    output wire         p_wready,
    input  wire         p_wlast,

    // AXI3 AW channel (Zynq S_AXI_HP, 64-bit data, 6-bit ID)
    output wire [5:0]   m_axi_awid,
    output wire [31:0]  m_axi_awaddr,
    output wire [3:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire [1:0]   m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [2:0]   m_axi_awprot,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,

    // AXI3 W channel
    output wire [5:0]   m_axi_wid,
    output wire [63:0]  m_axi_wdata,
    output wire [7:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,

    // AXI3 B channel
    input  wire [5:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,

    output logic        active,
    output wire         drain_done,     // no accepted transaction remains
    output wire         writer_done,    // packer_done + all BRESP OKAY
    output logic        range_error,
    output logic        bresp_error,
    output logic        protocol_error,
    output logic [31:0] last_error_addr,
    output logic [1:0]  last_bresp,
    output logic [2:0]  outstanding,
    output logic [31:0] bursts_issued,
    output logic [31:0] bursts_w_sent,
    output logic [31:0] bursts_committed,
    output logic [17:0] frames_committed,
    output logic        preamble_committed,
    output wire [31:0] current_write_addr
);
    // Saturation guard assumes MAX_OUTSTANDING is in [1,4] for this initial IP.
    logic [63:0] next_addr;
    logic [63:0] mem_start_ext, mem_end_ext;
    wire [63:0] next_burst_end = next_addr + 64'd128;
    wire range_ok = (mem_end_ext > mem_start_ext) &&
                    (next_addr >= mem_start_ext) &&
                    (next_burst_end <= mem_end_ext) &&
                    (next_burst_end <= 64'h0000000100000000) &&
                    (next_addr[6:0] == 7'd0);
    wire fault = range_error || bresp_error || protocol_error;

    // Only one descriptor's AW/W channels active at a time; B responses can
    // lag behind up to MAX_OUTSTANDING accepted AW transactions.
    logic        desc_busy;
    logic        aw_pending;
    logic        w_active;
    logic [31:0] aw_addr_reg;
    logic [3:0]  expected_awlen;
    logic        desc_is_preamble;
    logic        desc_ends_frame;
    logic [4:0]  w_beat_idx;

    // Metadata is pushed on AW handshake, popped on B handshake. All AXI IDs
    // are the same, therefore BRESP is required to follow AW issuance order.
    logic [31:0] response_addr [0:MAX_OUTSTANDING-1];
    logic        response_preamble [0:MAX_OUTSTANDING-1];
    logic        response_frame_end [0:MAX_OUTSTANDING-1];
    integer wr_ptr, rd_ptr;

    wire accept_desc = burst_valid && burst_ready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;

    assign burst_ready = active && !halt_new && !fault && !desc_busy &&
                         (outstanding < MAX_OUTSTANDING) && range_ok &&
                         (burst_word_count_minus_one == 4'd15);
    assign p_wready = active && desc_busy && w_active && m_axi_wready;
    assign m_axi_awid = 6'd0;
    assign m_axi_awaddr = aw_addr_reg;
    assign m_axi_awlen = expected_awlen;
    assign m_axi_awsize = 3'd3;
    assign m_axi_awburst = 2'b01; // INCR
    assign m_axi_awlock = 2'b00;  // normal
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot = 3'b000;
    assign m_axi_awvalid = active && aw_pending;
    assign m_axi_wid = 6'd0;
    assign m_axi_wdata = p_wdata;
    assign m_axi_wstrb = 8'hff;
    assign m_axi_wlast = p_wlast;
    assign m_axi_wvalid = active && desc_busy && w_active && p_wvalid;
    assign m_axi_bready = active; // Always drain responses, including after fault
    assign drain_done = active && !desc_busy && (outstanding == 0);
    assign writer_done = drain_done && packer_done && !fault && preamble_committed;
    assign current_write_addr = next_addr[31:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            next_addr <= 64'd0;
            mem_start_ext <= 64'd0;
            mem_end_ext <= 64'd0;
            desc_busy <= 1'b0;
            aw_pending <= 1'b0;
            w_active <= 1'b0;
            aw_addr_reg <= 32'd0;
            expected_awlen <= 4'd15;
            desc_is_preamble <= 1'b0;
            desc_ends_frame <= 1'b0;
            w_beat_idx <= 5'd0;
            wr_ptr <= 0;
            rd_ptr <= 0;
            outstanding <= 3'd0;
            bursts_issued <= 32'd0;
            bursts_w_sent <= 32'd0;
            bursts_committed <= 32'd0;
            frames_committed <= 18'd0;
            preamble_committed <= 1'b0;
            range_error <= 1'b0;
            bresp_error <= 1'b0;
            protocol_error <= 1'b0;
            last_error_addr <= 32'd0;
            last_bresp <= 2'b00;
        end else if (start) begin
            // Integration contract: start only when no AXI transaction is active.
            active <= 1'b1;
            next_addr <= {32'd0, start_addr};
            mem_start_ext <= {32'd0, mem_base_addr};
            mem_end_ext <= {32'd0, mem_base_addr} + {32'd0, mem_buffer_bytes};
            desc_busy <= 1'b0;
            aw_pending <= 1'b0;
            w_active <= 1'b0;
            expected_awlen <= 4'd15;
            w_beat_idx <= 5'd0;
            wr_ptr <= 0;
            rd_ptr <= 0;
            outstanding <= 3'd0;
            bursts_issued <= 32'd0;
            bursts_w_sent <= 32'd0;
            bursts_committed <= 32'd0;
            frames_committed <= 18'd0;
            preamble_committed <= 1'b0;
            range_error <= 1'b0;
            bresp_error <= 1'b0;
            protocol_error <= 1'b0;
            last_error_addr <= 32'd0;
            last_bresp <= 2'b00;
        end else if (active) begin
            // A pending descriptor may remain on burst_valid even if rejected
            // for an address-guard failure: log the fault and block new issues.
            if (burst_valid && !desc_busy && !range_ok && !fault) begin
                range_error <= 1'b1;
                last_error_addr <= next_addr[31:0];
            end
            if (burst_valid && burst_word_count_minus_one != 4'd15 && !fault) begin
                protocol_error <= 1'b1;
                last_error_addr <= next_addr[31:0];
            end

            if (accept_desc) begin
                desc_busy <= 1'b1;
                aw_pending <= 1'b1;
                w_active <= 1'b1;
                aw_addr_reg <= next_addr[31:0];
                expected_awlen <= 4'd15;
                desc_is_preamble <= burst_is_preamble;
                desc_ends_frame <= burst_ends_frame;
                w_beat_idx <= 5'd0;
                next_addr <= next_burst_end;
            end
            if (aw_fire) begin
                aw_pending <= 1'b0;
                response_addr[wr_ptr] <= aw_addr_reg;
                response_preamble[wr_ptr] <= desc_is_preamble;
                response_frame_end[wr_ptr] <= desc_ends_frame;
                wr_ptr <= (wr_ptr == MAX_OUTSTANDING-1) ? 0 : wr_ptr+1;
                bursts_issued <= bursts_issued + 32'd1;
            end
            if (w_fire) begin
                if (p_wlast !== (w_beat_idx == 5'd15)) begin
                    protocol_error <= 1'b1;
                    last_error_addr <= aw_addr_reg;
                end
                if (w_beat_idx == 5'd15) begin
                    w_active <= 1'b0;
                    w_beat_idx <= 5'd0;
                    bursts_w_sent <= bursts_w_sent + 32'd1;
                end else begin
                    w_beat_idx <= w_beat_idx + 5'd1;
                end
            end
            if (desc_busy && !aw_pending && !w_active)
                desc_busy <= 1'b0;

            if (b_fire) begin
                if (outstanding == 3'd0 && !aw_fire) begin
                    protocol_error <= 1'b1;
                end else begin
                    if (m_axi_bid != 6'd0) begin
                        protocol_error <= 1'b1;
                        last_error_addr <= response_addr[rd_ptr];
                    end else if (m_axi_bresp != 2'b00) begin
                        bresp_error <= 1'b1;
                        last_bresp <= m_axi_bresp;
                        last_error_addr <= response_addr[rd_ptr];
                    end else if (!fault) begin
                        bursts_committed <= bursts_committed + 32'd1;
                        if (response_preamble[rd_ptr])
                            preamble_committed <= 1'b1;
                        if (response_frame_end[rd_ptr])
                            frames_committed <= frames_committed + 18'd1;
                    end
                    rd_ptr <= (rd_ptr == MAX_OUTSTANDING-1) ? 0 : rd_ptr+1;
                end
            end
            case ({aw_fire, b_fire})
                2'b10: outstanding <= outstanding + 3'd1;
                2'b01: if (outstanding != 0) outstanding <= outstanding - 3'd1;
                default: ;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (MAX_OUTSTANDING < 1 || MAX_OUTSTANDING > 4)
            $fatal(1,"axi3_write_master: MAX_OUTSTANDING must be 1..4");
    end
    always @(posedge clk) if (!rst && active && !start) begin
        if (outstanding > MAX_OUTSTANDING)
            $fatal(1,"axi3_write_master: outstanding exceeds limit");
        if (aw_fire && outstanding == MAX_OUTSTANDING && !b_fire)
            $fatal(1,"axi3_write_master: AW exceeded outstanding limit");
    end
`endif
endmodule
`default_nettype wire
