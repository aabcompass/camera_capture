// Camera Data Capture IP - AXI4-Lite register bank v1.0
// Xilinx Zynq-7000 XC7Z035; single clk domain (200 MHz target).
// Independent AW/W reception, one outstanding write and one outstanding read.
// Config SHADOW registers are software-writable while busy, ACTIVE registers
// update only on run_start_pulse (issued by FSM AFTER mem_range_guard check_ok).
// START command is a request for validation, not a successful run itself.
// W1 command bits are pulsed once per committed AXI-Lite write.
// The complete original user specification must be included verbatim as a
// comment in camera_capture_top.sv when that module is written.
`default_nettype none
module axi_lite_regs #(
    parameter logic [31:0] IP_VERSION_VALUE = 32'h0001_0000
) (
    input  wire         clk,
    input  wire         rst,
    // AXI4-Lite write address channel
    input  wire [31:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    // AXI4-Lite write data channel
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    // AXI4-Lite write response channel
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire         s_axi_bready,
    // AXI4-Lite read address channel
    input  wire [31:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    // AXI4-Lite read data channel
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire         s_axi_rready,

    // FSM permissions; rejected commands return SLVERR without any pulse.
    input  wire         allow_start,        // IDLE only
    input  wire         allow_clear_error,  // only when safe to clear
    input  wire         allow_clear_stats,  // IDLE or END_STATE
    input  wire         cfg_write_lock,     // high while START validation is pending
    input  wire         run_start_pulse,    // validated START from FSM
    output logic        cmd_start,
    output logic        cmd_stop,
    output logic        cmd_clear_error,
    output logic        cmd_clear_stats,
    output logic        int_single_pulse,

    // Configuration shadow (feeds mem_range_guard / AXI-Lite readback)
    output logic [2:0]  cfg_trigger_enable,
    output logic [31:0] cfg_n_frames,
    output logic [31:0] cfg_n_prev_frames,
    output logic [31:0] cfg_n_fragments,
    output logic [31:0] cfg_mem_addr,
    output logic [31:0] cfg_mem_buffer_bytes,
    output logic [31:0] cfg_header_id,
    output wire  [255:0] cfg_aux_data,
    output logic [31:0] cfg_int_trig_period,
    output logic        cfg_int_periodic_enable,

    // Active configuration; sampled atomically on run_start_pulse
    output logic [2:0]  active_trigger_enable,
    output logic [31:0] active_n_frames,
    output logic [31:0] active_n_prev_frames,
    output logic [31:0] active_n_fragments,
    output logic [31:0] active_mem_addr,
    output logic [31:0] active_mem_buffer_bytes,
    output logic [31:0] active_header_id,
    output logic [255:0] active_aux_data,
    output logic [31:0] active_int_trig_period,
    output logic        active_int_periodic_enable,

    // Live status and statistics from datapath / Main FSM
    input  wire [3:0]   fsm_state,
    input  wire         status_busy,
    input  wire         status_stop_pending,
    input  wire         status_trigger_latched,
    input  wire         status_capture_complete,
    input  wire         status_axi_busy,
    input  wire         status_fifo_empty,
    input  wire         status_fifo_full,
    input  wire [31:0]  error_set_mask,  // sticky hardware error set, higher priority than clear
    output logic [31:0] error_flags,
    input  wire [31:0]  last_error_code,
    input  wire [31:0]  last_error_addr,
    input  wire [31:0]  fifo_level,
    input  wire [31:0]  frames_captured,
    input  wire [31:0]  frames_sent,
    input  wire [31:0]  frames_committed,
    input  wire [31:0]  fragments_completed,
    input  wire [63:0]  triggers_accepted_total,
    input  wire [63:0]  triggers_missed_total,
    input  wire [31:0]  fifo_overflow_count,
    input  wire [31:0]  axi_error_count,
    input  wire [31:0]  current_write_addr,
    input  wire [63:0]  last_timestamp,
    input  wire [63:0]  last_trigger_data,
    input  wire [31:0]  last_trigger_source,
    input  wire [31:0]  last_fragment_addr,
    input  wire [31:0]  last_fragment_frames,
    input  wire [31:0]  last_fragment_size,
    input  wire [31:0]  last_fragment_status,
    input  wire [31:0]  run_fragments_completed
);
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    logic [31:0] cfg_aux [0:7];
    genvar g;
    generate
        for (g=0; g<8; g=g+1) begin : gen_aux
            assign cfg_aux_data[g*32 +: 32] = cfg_aux[g];
        end
    endgenerate

    function automatic logic [31:0] merge_bytes(
        input logic [31:0] old_word,
        input logic [31:0] new_word,
        input logic [3:0]  strobes
    );
        logic [31:0] result_word;
        for (int i=0; i<4; i=i+1)
            result_word[i*8 +: 8] = strobes[i] ? new_word[i*8 +: 8] : old_word[i*8 +: 8];
        return result_word;
    endfunction

    function automatic logic mapped_address(input logic [31:0] a);
        case (a)
            32'h000, 32'h004, 32'h008, 32'h00C, 32'h010, 32'h014,
            32'h018, 32'h01C, 32'h020, 32'h024, 32'h028, 32'h02C,
            32'h030, 32'h034, 32'h038, 32'h03C, 32'h040, 32'h044,
            32'h048, 32'h050, 32'h054, 32'h058, 32'h05C, 32'h060,
            32'h064, 32'h068, 32'h06C, 32'h070, 32'h074, 32'h078,
            32'h07C, 32'h080, 32'h084, 32'h088, 32'h08C, 32'h090,
            32'h094, 32'h098, 32'h09C, 32'h0A0, 32'h0A4, 32'h0A8,
            32'h0AC, 32'h0B0, 32'h0B4: mapped_address = 1'b1;
            default: mapped_address = 1'b0;
        endcase
    endfunction

    function automatic logic writable_address(input logic [31:0] a);
        case (a)
            32'h000, 32'h00C, 32'h010, 32'h014, 32'h018, 32'h01C,
            32'h020, 32'h024, 32'h028, 32'h02C, 32'h030, 32'h034,
            32'h038, 32'h03C, 32'h040, 32'h044, 32'h048, 32'h0B4:
                writable_address = 1'b1;
            default: writable_address = 1'b0;
        endcase
    endfunction

    // Prevent TOCTOU: data checked by mem_range_guard must not change before
    // the same configuration is captured as ACTIVE on run_start_pulse.
    function automatic logic config_address(input logic [31:0] a);
        case (a)
            32'h00C, 32'h010, 32'h014, 32'h018, 32'h01C, 32'h020,
            32'h024, 32'h028, 32'h02C, 32'h030, 32'h034, 32'h038,
            32'h03C, 32'h040, 32'h044, 32'h048, 32'h0B4:
                config_address = 1'b1;
            default: config_address = 1'b0;
        endcase
    endfunction

    logic [31:0] held_awaddr, held_wdata;
    logic [3:0] held_wstrb;
    logic aw_held, w_held;
    assign s_axi_awready = !rst && !aw_held && !s_axi_bvalid;
    assign s_axi_wready  = !rst && !w_held  && !s_axi_bvalid;
    assign s_axi_arready = !rst && !s_axi_rvalid;

    wire [31:0] command_bits = held_wdata & {{8{held_wstrb[3]}},
                                                      {8{held_wstrb[2]}},
                                                      {8{held_wstrb[1]}},
                                                      {8{held_wstrb[0]}}};
    wire command_multiple = ((command_bits[3:0] & (command_bits[3:0] - 4'd1)) != 4'd0);

    logic [31:0] accepted_hi_snapshot, missed_hi_snapshot;
    logic accepted_snapshot_valid, missed_snapshot_valid;

    logic [31:0] status_value;
    always_comb begin
        status_value = 32'd0;
        status_value[3:0] = fsm_state;
        status_value[4]  = status_busy;
        status_value[5]  = status_stop_pending;
        status_value[6]  = status_trigger_latched;
        status_value[7]  = status_capture_complete;
        status_value[8]  = status_axi_busy;
        status_value[9]  = status_fifo_empty;
        status_value[10] = status_fifo_full;
        status_value[11] = |{error_flags[11:9], error_flags[7:4]};
        status_value[12] = |{error_flags[8], error_flags[3:0]};
    end

    logic [31:0] read_value;
    always_comb begin
        read_value = 32'd0;
        case (s_axi_araddr)
            32'h000: read_value = 32'd0; // command is write-only, readable as zero
            32'h004: read_value = status_value;
            32'h008: read_value = error_flags;
            32'h00C: read_value = {29'd0, cfg_trigger_enable};
            32'h010: read_value = cfg_n_frames;
            32'h014: read_value = cfg_n_prev_frames;
            32'h018: read_value = cfg_n_fragments;
            32'h01C: read_value = cfg_mem_addr;
            32'h020: read_value = cfg_header_id;
            32'h044: read_value = cfg_int_trig_period;
            32'h048: read_value = {30'd0, cfg_int_periodic_enable, 1'b0};
            32'h050: read_value = last_error_code;
            32'h054: read_value = last_error_addr;
            32'h058: read_value = fifo_level;
            32'h05C: read_value = frames_captured;
            32'h060: read_value = frames_sent;
            32'h064: read_value = frames_committed;
            32'h068: read_value = fragments_completed;
            32'h06C: read_value = triggers_accepted_total[31:0];
            32'h070: read_value = triggers_missed_total[31:0];
            32'h074: read_value = fifo_overflow_count;
            32'h078: read_value = axi_error_count;
            32'h07C: read_value = current_write_addr;
            32'h080: read_value = last_timestamp[31:0];
            32'h084: read_value = last_timestamp[63:32];
            32'h088: read_value = last_trigger_data[31:0];
            32'h08C: read_value = last_trigger_data[63:32];
            32'h090: read_value = last_trigger_source;
            32'h094: read_value = last_fragment_addr;
            32'h098: read_value = last_fragment_frames;
            32'h09C: read_value = last_fragment_size;
            32'h0A0: read_value = last_fragment_status;
            32'h0A4: read_value = run_fragments_completed;
            32'h0A8: read_value = accepted_snapshot_valid ? accepted_hi_snapshot : triggers_accepted_total[63:32];
            32'h0AC: read_value = missed_snapshot_valid ? missed_hi_snapshot : triggers_missed_total[63:32];
            32'h0B0: read_value = IP_VERSION_VALUE;
            32'h0B4: read_value = cfg_mem_buffer_bytes;
            default: begin
                if (s_axi_araddr >= 32'h024 && s_axi_araddr <= 32'h040 &&
                    s_axi_araddr[1:0] == 2'b00)
                    read_value = cfg_aux[(s_axi_araddr - 32'h024) >> 2];
            end
        endcase
    end

    // Reset, configuration, commands, AXI write channel and B response.
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_held <= 1'b0;
            w_held <= 1'b0;
            held_awaddr <= '0;
            held_wdata <= '0;
            held_wstrb <= '0;
            s_axi_bresp <= RESP_OKAY;
            s_axi_bvalid <= 1'b0;
            cmd_start <= 1'b0;
            cmd_stop <= 1'b0;
            cmd_clear_error <= 1'b0;
            cmd_clear_stats <= 1'b0;
            int_single_pulse <= 1'b0;
            cfg_trigger_enable <= '0;
            cfg_n_frames <= 32'd2;
            cfg_n_prev_frames <= 32'd0;
            cfg_n_fragments <= 32'd1;
            cfg_mem_addr <= 32'd0;
            cfg_mem_buffer_bytes <= 32'd0;
            cfg_header_id <= 32'd0;
            cfg_int_trig_period <= 32'd0;
            cfg_int_periodic_enable <= 1'b0;
            active_trigger_enable <= '0;
            active_n_frames <= 32'd2;
            active_n_prev_frames <= 32'd0;
            active_n_fragments <= 32'd1;
            active_mem_addr <= '0;
            active_mem_buffer_bytes <= '0;
            active_header_id <= '0;
            active_aux_data <= '0;
            active_int_trig_period <= '0;
            active_int_periodic_enable <= 1'b0;
            for (int i=0; i<8; i=i+1)
                cfg_aux[i] <= 32'd0;
        end else begin
            cmd_start <= 1'b0;
            cmd_stop <= 1'b0;
            cmd_clear_error <= 1'b0;
            cmd_clear_stats <= 1'b0;
            int_single_pulse <= 1'b0;

            if (run_start_pulse) begin
                active_trigger_enable <= cfg_trigger_enable;
                active_n_frames <= cfg_n_frames;
                active_n_prev_frames <= cfg_n_prev_frames;
                active_n_fragments <= cfg_n_fragments;
                active_mem_addr <= cfg_mem_addr;
                active_mem_buffer_bytes <= cfg_mem_buffer_bytes;
                active_header_id <= cfg_header_id;
                for (int i=0; i<8; i=i+1)
                    active_aux_data[i*32 +: 32] <= cfg_aux[i];
                active_int_trig_period <= cfg_int_trig_period;
                active_int_periodic_enable <= cfg_int_periodic_enable;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                held_awaddr <= s_axi_awaddr;
                aw_held <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                held_wdata <= s_axi_wdata;
                held_wstrb <= s_axi_wstrb;
                w_held <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (aw_held && w_held && !s_axi_bvalid) begin
                aw_held <= 1'b0;
                w_held <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= RESP_OKAY;
                if (!mapped_address(held_awaddr)) begin
                    s_axi_bresp <= RESP_DECERR;
                end else if (!writable_address(held_awaddr) ||
                             (cfg_write_lock && config_address(held_awaddr))) begin
                    s_axi_bresp <= RESP_SLVERR;
                end else begin
                    case (held_awaddr)
                        32'h000: begin
                            if ((command_bits[31:4] != 0) || command_multiple ||
                                (command_bits[0] && !allow_start) ||
                                (command_bits[2] && !allow_clear_error) ||
                                (command_bits[3] && !allow_clear_stats)) begin
                                s_axi_bresp <= RESP_SLVERR;
                            end else begin
                                cmd_start       <= command_bits[0];
                                cmd_stop        <= command_bits[1];
                                cmd_clear_error <= command_bits[2];
                                cmd_clear_stats <= command_bits[3];
                            end
                        end
                        32'h00C: cfg_trigger_enable <= merge_bytes({29'd0, cfg_trigger_enable}, held_wdata, held_wstrb) & 32'h7;
                        32'h010: cfg_n_frames <= merge_bytes(cfg_n_frames, held_wdata, held_wstrb);
                        32'h014: cfg_n_prev_frames <= merge_bytes(cfg_n_prev_frames, held_wdata, held_wstrb);
                        32'h018: cfg_n_fragments <= merge_bytes(cfg_n_fragments, held_wdata, held_wstrb);
                        32'h01C: cfg_mem_addr <= merge_bytes(cfg_mem_addr, held_wdata, held_wstrb);
                        32'h020: cfg_header_id <= merge_bytes(cfg_header_id, held_wdata, held_wstrb);
                        32'h044: cfg_int_trig_period <= merge_bytes(cfg_int_trig_period, held_wdata, held_wstrb);
                        32'h048: begin
                            if (command_bits[31:2] != 0) begin
                                s_axi_bresp <= RESP_SLVERR;
                            end else if (held_wstrb[0]) begin
                                cfg_int_periodic_enable <= held_wdata[1];
                                int_single_pulse <= held_wdata[0];
                            end
                        end
                        32'h0B4: cfg_mem_buffer_bytes <= merge_bytes(cfg_mem_buffer_bytes, held_wdata, held_wstrb);
                        default: begin
                            if (held_awaddr >= 32'h024 && held_awaddr <= 32'h040)
                                cfg_aux[(held_awaddr - 32'h024) >> 2] <=
                                    merge_bytes(cfg_aux[(held_awaddr - 32'h024) >> 2], held_wdata, held_wstrb);
                        end
                    endcase
                end
            end
        end
    end

    // Hardware errors are sticky. New fault set wins over software clear.
    always_ff @(posedge clk) begin
        if (rst)
            error_flags <= 32'd0;
        else if (cmd_clear_error)
            error_flags <= error_set_mask;
        else
            error_flags <= error_flags | error_set_mask;
    end

    // Independent AXI-Lite read path. Data and response remain stable during R stall.
    // Reading a 64-bit counter's LOW part captures the HIGH for a coherent pair.
    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp <= RESP_OKAY;
            s_axi_rdata <= 32'd0;
            accepted_hi_snapshot <= '0;
            missed_hi_snapshot <= '0;
            accepted_snapshot_valid <= 1'b0;
            missed_snapshot_valid <= 1'b0;
        end else begin
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp <= mapped_address(s_axi_araddr) ? RESP_OKAY : RESP_DECERR;
                s_axi_rdata <= read_value;
                if (s_axi_araddr == 32'h06C) begin
                    accepted_hi_snapshot <= triggers_accepted_total[63:32];
                    accepted_snapshot_valid <= 1'b1;
                end
                if (s_axi_araddr == 32'h070) begin
                    missed_hi_snapshot <= triggers_missed_total[63:32];
                    missed_snapshot_valid <= 1'b1;
                end
            end
        end
    end

    // AWPROT/ARPROT are intentionally ignored; PS software controls access.
    wire unused_prot = ^{s_axi_awprot, s_axi_arprot};
endmodule
`default_nettype wire
