// Camera Data Capture IP: single-clock, 65-bit FIFO storage.
// USE_XPM=1: Xilinx XPM_FIFO_SYNC, FWFT, 16384 physical words.
// USE_XPM=0: cycle-level portable behavioral model for unit simulations.
// The logical 9600-word capacity is enforced by capture_fifo_ctrl, NOT here.
// Interface contract: read_valid/read_data expose the current FWFT head;
// a read occurs only on read_en && read_valid at the rising edge.
`default_nettype none
module capture_fifo #(
    parameter integer WIDTH = 65,
    parameter integer PHYSICAL_DEPTH = 16384,
    parameter bit USE_XPM = 1'b1
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             flush,
    input  wire [WIDTH-1:0] write_data,
    input  wire             write_en,
    output wire             can_write,
    input  wire             read_en,
    output wire [WIDTH-1:0] read_data,
    output wire             read_valid,
    output wire             ready
);
    wire fifo_rst = rst | flush;
    wire physical_full;
    wire physical_empty;
    wire wr_rst_busy;
    wire rd_rst_busy;

    assign ready     = !fifo_rst && !wr_rst_busy && !rd_rst_busy;
    assign can_write = ready && !physical_full;
    assign read_valid = ready && !physical_empty;

    generate
        if (USE_XPM) begin : gen_xpm
            // XPM_READ_MODE=fwft requires FIFO_READ_LATENCY=0.
            // No write/read operation is issued during either reset-busy flag.
            xpm_fifo_sync #(
                .DOUT_RESET_VALUE("0"),
                .ECC_MODE("no_ecc"),
                .FIFO_MEMORY_TYPE("block"),
                .FIFO_READ_LATENCY(0),
                .FIFO_WRITE_DEPTH(PHYSICAL_DEPTH),
                .FULL_RESET_VALUE(0),
                .PROG_EMPTY_THRESH(10),
                .PROG_FULL_THRESH(10),
                .RD_DATA_COUNT_WIDTH($clog2(PHYSICAL_DEPTH)+1),
                .READ_DATA_WIDTH(WIDTH),
                .READ_MODE("fwft"),
                .SIM_ASSERT_CHK(1),
                .USE_ADV_FEATURES("0707"),
                .WAKEUP_TIME(0),
                .WRITE_DATA_WIDTH(WIDTH),
                .WR_DATA_COUNT_WIDTH($clog2(PHYSICAL_DEPTH)+1)
            ) u_xpm_fifo (
                .wr_clk(clk),
                .rst(fifo_rst),
                .sleep(1'b0),
                .injectsbiterr(1'b0),
                .injectdbiterr(1'b0),
                .din(write_data),
                .wr_en(write_en && ready),
                .full(physical_full),
                .wr_rst_busy(wr_rst_busy),
                .rd_en(read_en && ready),
                .dout(read_data),
                .empty(physical_empty),
                .rd_rst_busy(rd_rst_busy),
                .overflow(),
                .underflow(),
                .wr_ack(),
                .data_valid(),
                .almost_full(),
                .almost_empty(),
                .prog_full(),
                .prog_empty(),
                .wr_data_count(),
                .rd_data_count(),
                .sbiterr(),
                .dbiterr()
            );
        end else begin : gen_sim
            // Behavioral FWFT queue. A 3-cycle reset busy period detects
            // incorrect access during flush in stand-alone simulations.
            localparam integer PTR_BITS = $clog2(PHYSICAL_DEPTH);
            logic [WIDTH-1:0] storage [0:PHYSICAL_DEPTH-1];
            logic [PTR_BITS-1:0] wr_pointer, rd_pointer;
            logic [PTR_BITS:0] count;
            logic [2:0] reset_busy_cycles;
            wire do_write = write_en && can_write;
            wire do_read  = read_en && read_valid;
            assign wr_rst_busy = (reset_busy_cycles != 3'd0);
            assign rd_rst_busy = (reset_busy_cycles != 3'd0);
            assign physical_full  = (count == PHYSICAL_DEPTH);
            assign physical_empty = (count == 0);
            assign read_data = physical_empty ? {WIDTH{1'b0}} : storage[rd_pointer];

            always_ff @(posedge clk) begin
                if (fifo_rst) begin
                    wr_pointer       <= '0;
                    rd_pointer       <= '0;
                    count            <= '0;
                    reset_busy_cycles <= 3'd3;
                end else begin
                    if (reset_busy_cycles != 3'd0)
                        reset_busy_cycles <= reset_busy_cycles - 3'd1;
                    if (do_write) begin
                        storage[wr_pointer] <= write_data;
                        wr_pointer <= wr_pointer + 1'b1;
                    end
                    if (do_read)
                        rd_pointer <= rd_pointer + 1'b1;
                    case ({do_write, do_read})
                        2'b10: count <= count + 1'b1;
                        2'b01: count <= count - 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    endgenerate
endmodule
`default_nettype wire
