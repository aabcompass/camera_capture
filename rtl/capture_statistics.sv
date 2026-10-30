// Camera Data Capture IP: cumulative counters and last-error status.
// This is integration glue; unlike verified leaf modules, it requires
// full-system XSIM verification before claiming functional correctness.
`default_nettype none
module capture_statistics (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear_stats,
    input  wire        clear_error,
    input  wire        fragment_complete_pulse,
    input  wire        fifo_overflow_pulse,
    input  wire        writer_range_error,
    input  wire        writer_bresp_error,
    input  wire [1:0]  writer_last_bresp,
    input  wire        writer_protocol_error,
    input  wire [31:0] writer_last_error_addr,
    input  wire [31:0] error_set_mask,
    output logic [31:0] fragments_completed_total,
    output logic [31:0] fifo_overflow_count,
    output logic [31:0] axi_error_count,
    output logic [31:0] last_error_code,
    output logic [31:0] last_error_addr
);
    wire writer_error = writer_range_error | writer_bresp_error | writer_protocol_error;
    logic writer_error_prev;
    always_ff @(posedge clk) begin
        if (rst) begin
            fragments_completed_total <= 32'd0;
            fifo_overflow_count <= 32'd0;
            axi_error_count <= 32'd0;
            last_error_code <= 32'd0;
            last_error_addr <= 32'd0;
            writer_error_prev <= 1'b0;
        end else begin
            writer_error_prev <= writer_error;
            if (clear_stats) begin
                fragments_completed_total <= 32'd0;
                fifo_overflow_count <= 32'd0;
                axi_error_count <= 32'd0;
            end else begin
                if (fragment_complete_pulse)
                    fragments_completed_total <= fragments_completed_total + 32'd1;
                if (fifo_overflow_pulse)
                    fifo_overflow_count <= fifo_overflow_count + 32'd1;
                // One increment per writer fault episode, not per BRESP.
                if (writer_error && !writer_error_prev)
                    axi_error_count <= axi_error_count + 32'd1;
            end
            if (clear_error) begin
                last_error_code <= 32'd0;
                last_error_addr <= 32'd0;
            end else if (error_set_mask != 32'd0) begin
                if (error_set_mask[0])         last_error_code <= 32'd1; // FIFO
                else if (error_set_mask[1])    last_error_code <= 32'd2; // SLVERR
                else if (error_set_mask[2])    last_error_code <= 32'd3; // DECERR
                else if (error_set_mask[3])    last_error_code <= 32'd4; // FORMAT
                else if (error_set_mask[10])   last_error_code <= 32'd5; // RANGE
                else if (error_set_mask[12])   last_error_code <= 32'd6; // PROTOCOL
                else if (error_set_mask[13])   last_error_code <= 32'd7; // PACKER TARGET
                else                            last_error_code <= 32'd8; // CONFIG
                if (writer_error)
                    last_error_addr <= writer_last_error_addr;
            end
        end
    end
endmodule
`default_nettype wire
