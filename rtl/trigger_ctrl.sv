// Camera Data Capture IP -- trigger_ctrl v1.0
// Target: XC7Z035, single 200 MHz clock domain.
//
// Timing contract:
//   * trigger_event, trigger_accept, trigger_missed_events, trigger_source,
//     trigger_data are SAME-CYCLE combinational events. Sample on the same
//     rising clk edge as the camera word/TLAST corresponding to the trigger.
//   * accept_enable is asserted ONLY when the main FSM can accept a trigger
//     (trig_wait and no higher-priority STOP/error in the same cycle).
//   * count_enable is asserted in active acquisition states, including
//     buffer_filling, trig_wait, data_transfer, after_transfer. It may remain
//     high during STOP/error arbitration so rejected events count as missed.
//   * run_start resets the periodic generator's phase; run_active keeps it
//     running through acquisition and dead time until the run is terminated.
//   * int_single_pulse is ONE CLOCK command event; holding it high counts as
//     one independent event on each cycle (the AXI-Lite bank pulses it).
//   * ext_trig_async is synchronized with two ASYNC_REG flip-flops followed
//     by rising-edge detection. Timestamp is sampled at the DETECTED edge,
//     not at the original asynchronous pin transition.
//   * trigger_enable is the effective configuration latched on START.
//   * clear_stats only clears cumulative statistics (last accepted trigger
//     metadata is preserved). The main FSM must accept clear_stats only in
//     allowed states. Reset clears everything.
//
// All sources can fire at most once per clock. For simultaneous triggers,
// priority is external > algorithmic > internal; all enabled source events
// count toward statistics (up to 3 missed in dead time).
//
// The ORIGINAL complete user technical specification belongs verbatim in
// camera_capture_top.sv when the top-level RTL is implemented.

`default_nettype none
module trigger_ctrl (
    input  wire        clk,
    input  wire        rst,

    input  wire [63:0] s_axis_trg_tdata,
    input  wire        s_axis_trg_tvalid,
    input  wire        ext_trig_async,
    input  wire        int_single_pulse,
    input  wire        int_periodic_enable,
    input  wire [31:0] int_period_cycles,
    input  wire [2:0]  trigger_enable,  // [2]=internal [1]=external [0]=algorithmic
    input  wire [63:0] timestamp,

    input  wire        run_start,
    input  wire        run_active,
    input  wire        accept_enable,
    input  wire        count_enable,
    input  wire        clear_stats,

    output wire        alg_event,
    output wire        ext_event,
    output wire        int_event,
    output wire        trigger_event,
    output wire        trigger_accept,
    output wire [1:0]  trigger_event_count,
    output wire [1:0]  trigger_missed_events,
    output logic [1:0] trigger_source,     // 0=none, 1=alg, 2=ext, 3=int
    output logic [63:0] trigger_data,      // algorithmic data; 0 for ext/internal

    output logic [63:0] latched_timestamp,
    output logic [63:0] latched_trigger_data,
    output logic [1:0]  latched_trigger_source,
    output logic [63:0] triggers_accepted_total,
    output logic [63:0] triggers_missed_total
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic ext_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic ext_sync;
    logic ext_sync_prev;

    // Sample the asynchronous pin. Keep metastability-reduction flops
    // independent of any asynchronous combinational logic in the capture path.
    always_ff @(posedge clk) begin
        if (rst) begin
            ext_meta      <= 1'b0;
            ext_sync      <= 1'b0;
            ext_sync_prev <= 1'b0;
        end else begin
            ext_meta      <= ext_trig_async;
            ext_sync      <= ext_meta;
            ext_sync_prev <= ext_sync;
        end
    end

    logic [31:0] period_counter;
    wire period_valid = (int_period_cycles != 32'd0);
    wire periodic_running = run_active && int_periodic_enable && period_valid;
    wire periodic_tick = periodic_running && !run_start &&
                         (period_counter == (int_period_cycles - 32'd1));

    // First tick is at the Nth active clock following run_start when N>=1.
    // The counter is never gated by the source-enable mask, so the periodic
    // generator maintains its phase when a source is temporarily masked.
    always_ff @(posedge clk) begin
        if (rst || run_start || !periodic_running) begin
            period_counter <= 32'd0;
        end else if (periodic_tick) begin
            period_counter <= 32'd0;
        end else begin
            period_counter <= period_counter + 32'd1;
        end
    end

    assign alg_event = !rst && trigger_enable[0] && s_axis_trg_tvalid &&
                       (s_axis_trg_tdata != 64'd0);
    assign ext_event = !rst && trigger_enable[1] && ext_sync && !ext_sync_prev;
    assign int_event = !rst && trigger_enable[2] &&
                       (int_single_pulse || periodic_tick);

    assign trigger_event = alg_event || ext_event || int_event;
    assign trigger_event_count = {1'b0, alg_event} +
                                 {1'b0, ext_event} +
                                 {1'b0, int_event};

    // Both are inputs from the main FSM; its priority logic deasserts
    // accept_enable when STOP or a fatal error coincides with an event.
    assign trigger_accept = trigger_event && accept_enable && count_enable &&
                            !run_start && !rst;
    assign trigger_missed_events = (count_enable && !rst) ?
                            (trigger_event_count - {1'b0,trigger_accept}) :
                            2'd0;

    always_comb begin
        trigger_source = 2'd0;
        trigger_data   = 64'd0;
        if (ext_event) begin
            trigger_source = 2'd2;
        end else if (alg_event) begin
            trigger_source = 2'd1;
            trigger_data   = s_axis_trg_tdata;
        end else if (int_event) begin
            trigger_source = 2'd3;
        end
    end

    // Capture metadata at the SAME sampling clock edge as trigger_accept.
    // The registered outputs are stable for the rest of the fragment.
    always_ff @(posedge clk) begin
        if (rst) begin
            latched_timestamp      <= 64'd0;
            latched_trigger_data   <= 64'd0;
            latched_trigger_source <= 2'd0;
        end else if (trigger_accept) begin
            latched_timestamp      <= timestamp;
            latched_trigger_data   <= trigger_data;
            latched_trigger_source <= trigger_source;
        end
    end

    // Counters are 64-bit to avoid quick wraparound of 200 MHz event streams.
    // Main-FSM/state-based enable controls whether an event counts as missed.
    always_ff @(posedge clk) begin
        if (rst || clear_stats) begin
            triggers_accepted_total <= 64'd0;
            triggers_missed_total   <= 64'd0;
        end else begin
            if (trigger_accept)
                triggers_accepted_total <= triggers_accepted_total + 64'd1;
            if (trigger_missed_events != 2'd0)
                triggers_missed_total <= triggers_missed_total +
                    {{62{1'b0}}, trigger_missed_events};
        end
    end
endmodule
`default_nettype wire
