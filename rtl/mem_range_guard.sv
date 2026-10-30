// Camera Data Capture IP - timing-optimized startup guard v1.1
// Target: Zynq-7000 XC7Z035, 200 MHz clock.
// Change from v1.0: multi-cycle, registered validation at START. No
// combinational n_frames -> multiplication -> range comparison path.
// No external port changes. Main FSM waits for check_done already.
`default_nettype none
module mem_range_guard (
    input  wire        clk,
    input  wire        rst,
    input  wire        check_req,
    input  wire [31:0] n_frames,
    input  wire [31:0] n_prev_frames,
    input  wire [31:0] n_fragments,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_buffer_bytes,
    input  wire        periodic_enable,
    input  wire [31:0] int_trig_period,

    output logic        check_done,       // pulse when calculation finishes
    output logic        check_ok,         // held until next completed check
    output logic [31:0] check_error_flags,
    output logic [31:0] fragment_bytes,
    output logic [63:0] total_required_bytes,
    output logic [63:0] buffer_end_exclusive
);
    localparam integer ERR_N_FRAMES        = 4;
    localparam integer ERR_N_PREV          = 5;
    localparam integer ERR_N_FRAGMENTS     = 6;
    localparam integer ERR_MEM_ADDR_ALIGN  = 7;
    localparam integer ERR_MEM_TOO_SMALL   = 9;
    localparam integer ERR_MEM_ADDR_OVF    = 10;
    localparam integer ERR_INT_TRIG_PERIOD = 11;

    typedef enum logic [2:0] {
        ST_IDLE, ST_SIZE, ST_PARTIAL, ST_CROSS, ST_TOTAL, ST_REPORT
    } stage_t;
    stage_t stage;

    // Stage 0 (ST_IDLE request edge): capture ALL external inputs needed by
    // a check. The CPU can modify shadows after this edge without affecting
    // the in-flight calculation (even though AXI-Lite locks writes normally).
    logic [31:0] n_frames_q, n_fragments_q, buffer_bytes_q;
    logic [31:0] precheck_errors_q;
    logic [63:0] region_end_q;
    logic        frames_valid_q, fragments_valid_q;

    wire frames_valid_in = (n_frames >= 32'd2) && (n_frames <= 32'd131072);
    wire prev_valid_in = (n_prev_frames <= 32'd64) &&
                         (n_prev_frames < n_frames);
    wire fragments_valid_in = (n_fragments != 32'd0);
    wire [63:0] region_end_in = {32'd0,mem_addr} +
                                {32'd0,mem_buffer_bytes};
    logic [31:0] precheck_errors_in;
    always_comb begin
        precheck_errors_in = 32'd0;
        if (!frames_valid_in)
            precheck_errors_in[ERR_N_FRAMES] = 1'b1;
        if (!prev_valid_in)
            precheck_errors_in[ERR_N_PREV] = 1'b1;
        if (!fragments_valid_in)
            precheck_errors_in[ERR_N_FRAGMENTS] = 1'b1;
        if (mem_addr[6:0] != 7'd0)
            precheck_errors_in[ERR_MEM_ADDR_ALIGN] = 1'b1;
        if (mem_buffer_bytes == 32'd0)
            precheck_errors_in[ERR_MEM_TOO_SMALL] = 1'b1;
        if (region_end_in > 64'h00000001_00000000)
            precheck_errors_in[ERR_MEM_ADDR_OVF] = 1'b1;
        if (periodic_enable && int_trig_period == 32'd0)
            precheck_errors_in[ERR_INT_TRIG_PERIOD] = 1'b1;
    end

    // ST_SIZE: max n_frames=131072 needs 18 input bits, max size fits 27.
    logic [26:0] size_q;
    wire [26:0] nframes_27 = {9'd0,n_frames_q[17:0]};
    wire [26:0] calculated_size = 27'd128 + (nframes_27 << 9) +
                                   (nframes_27 << 8);

    // ST_PARTIAL: four separate 16x16-or-smaller multipliers. Vivado can
    // infer pipelined DSP48E1s for these narrower registered operations.
    logic [31:0] p00_q, p01_q, p10_q, p11_q;

    // ST_CROSS / ST_TOTAL: split 64-bit recombination over two cycles:
    // product = (p00.low16) +
    //        ((p00.high16 + p01 + p10 + (p11 << 16)) << 16).
    logic [33:0] cross_q;
    wire [47:0] upper_calc = {14'd0,cross_q} + {p11_q,16'd0};
    logic [63:0] total_q;

    // ST_REPORT: produce the result atomically after the multiplication.
    logic [31:0] errors_final;
    always_comb begin
        errors_final = precheck_errors_q;
        if (frames_valid_q && fragments_valid_q &&
            (total_q > {32'd0,buffer_bytes_q}))
            errors_final[ERR_MEM_TOO_SMALL] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            stage <= ST_IDLE;
            n_frames_q <= 32'd0;
            n_fragments_q <= 32'd0;
            buffer_bytes_q <= 32'd0;
            precheck_errors_q <= 32'd0;
            region_end_q <= 64'd0;
            frames_valid_q <= 1'b0;
            fragments_valid_q <= 1'b0;
            size_q <= 27'd0;
            p00_q <= 32'd0;
            p01_q <= 32'd0;
            p10_q <= 32'd0;
            p11_q <= 32'd0;
            cross_q <= 34'd0;
            total_q <= 64'd0;
            check_done <= 1'b0;
            check_ok <= 1'b0;
            check_error_flags <= 32'd0;
            fragment_bytes <= 32'd0;
            total_required_bytes <= 64'd0;
            buffer_end_exclusive <= 64'd0;
        end else begin
            check_done <= 1'b0;
            case (stage)
                ST_IDLE: begin
                    if (check_req) begin
                        n_frames_q <= n_frames;
                        n_fragments_q <= n_fragments;
                        buffer_bytes_q <= mem_buffer_bytes;
                        precheck_errors_q <= precheck_errors_in;
                        region_end_q <= region_end_in;
                        frames_valid_q <= frames_valid_in;
                        fragments_valid_q <= fragments_valid_in;
                        stage <= ST_SIZE;
                    end
                end
                ST_SIZE: begin
                    size_q <= frames_valid_q ? calculated_size : 27'd0;
                    stage <= ST_PARTIAL;
                end
                ST_PARTIAL: begin
                    p00_q <= size_q[15:0] * n_fragments_q[15:0];
                    p01_q <= size_q[15:0] * n_fragments_q[31:16];
                    p10_q <= size_q[26:16] * n_fragments_q[15:0];
                    p11_q <= size_q[26:16] * n_fragments_q[31:16];
                    stage <= ST_CROSS;
                end
                ST_CROSS: begin
                    cross_q <= {2'd0,p01_q} + {2'd0,p10_q} +
                               {18'd0,p00_q[31:16]};
                    stage <= ST_TOTAL;
                end
                ST_TOTAL: begin
                    total_q <= {upper_calc, p00_q[15:0]};
                    stage <= ST_REPORT;
                end
                ST_REPORT: begin
                    check_done <= 1'b1;
                    check_ok <= (errors_final == 32'd0);
                    check_error_flags <= errors_final;
                    fragment_bytes <= {5'd0,size_q};
                    total_required_bytes <= total_q;
                    buffer_end_exclusive <= region_end_q;
                    stage <= ST_IDLE;
                end
                default: stage <= ST_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
