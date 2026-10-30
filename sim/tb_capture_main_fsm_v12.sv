`timescale 1ns/1ps
`default_nettype none
module tb_capture_main_fsm;
    logic clk=0;
    always #2.5 clk=~clk;
    logic rst=1;
    logic cmd_start=0,cmd_stop=0,cmd_clear_error=0;
    logic [31:0] sticky_error_flags=0;
    always @(posedge clk) begin
        if (rst || cmd_clear_error) sticky_error_flags <= 32'd0;
        else sticky_error_flags <= sticky_error_flags | guard_error_set_mask;
    end
    logic [31:0] cfg_nf=4,cfg_np=2,cfg_nr=2,cfg_base=32'h20000000;
    logic [31:0] cfg_buf=32'h00100000,cfg_period=0;
    logic cfg_periodic=0;
    logic [31:0] active_n_frames,active_n_prev_frames,active_n_fragments,active_mem_addr;
    wire allow_start,allow_clear_error,allow_clear_stats,cfg_write_lock;
    wire guard_check_req,run_start_pulse;
    wire [31:0] guard_error_set_mask;
    wire guard_check_done,guard_check_ok;
    wire [31:0] guard_check_error_flags,guard_fragment_bytes;
    wire [63:0] total_bytes,buffer_end;

    logic fifo_ready=0;
    integer fifo_reset_count=0;
    logic [7:0] fifo_complete_frames=0;
    logic frame_sync_ready=0,frame_stored=0,capture_stopped=0;
    logic trigger_accept=0, fatal_error=0;
    wire frame_sync_request,capture_enable,frame_stop_request;
    wire fifo_flush,fifo_drop_enable,fifo_transfer_enable;
    wire trigger_run_active,trigger_accept_enable,trigger_count_enable;
    wire fragment_start_pulse,packer_abort,writer_halt_new;
    wire stop_target_valid;
    wire [17:0] stop_target_frames,fragment_n_frames;
    wire [31:0] fragment_addr,fragment_index;
    logic writer_done=0,writer_drain_done=1;
    logic [17:0] writer_frames_committed=0;
    logic writer_preamble_committed=0;
    wire [3:0] fsm_state;
    wire status_busy,status_stop_pending,status_trigger_latched,status_capture_complete;
    wire [31:0] frames_captured,run_fragments_completed;
    wire fragment_complete_pulse;
    wire [31:0] last_fragment_addr,last_fragment_frames,last_fragment_size,last_fragment_status;
    integer checks=0,groups=0;

    mem_range_guard u_guard (
        .clk(clk),.rst(rst),.check_req(guard_check_req),
        .n_frames(cfg_nf),.n_prev_frames(cfg_np),.n_fragments(cfg_nr),
        .mem_addr(cfg_base),.mem_buffer_bytes(cfg_buf),
        .periodic_enable(cfg_periodic),.int_trig_period(cfg_period),
        .check_done(guard_check_done),.check_ok(guard_check_ok),
        .check_error_flags(guard_check_error_flags),.fragment_bytes(guard_fragment_bytes),
        .total_required_bytes(total_bytes),.buffer_end_exclusive(buffer_end)
    );
    capture_main_fsm dut (.*);

    // Model the already verified AXI-Lite register bank's ACTIVE snapshot.
    always @(posedge clk) begin
        if (rst) begin
            active_n_frames<=2; active_n_prev_frames<=0;active_n_fragments<=1;active_mem_addr<=0;
        end else if(run_start_pulse) begin
            active_n_frames<=cfg_nf;active_n_prev_frames<=cfg_np;
            active_n_fragments<=cfg_nr;active_mem_addr<=cfg_base;
        end
    end
    // Simple FIFO readiness model; the real FIFO has reset-busy signals.
    always @(posedge clk) begin
        if (rst) begin
            fifo_ready <= 1'b0;
            fifo_reset_count <= 3;
        end else if(fifo_flush) begin
            fifo_ready<=1'b0;
            fifo_reset_count<=3;
        end else if(fifo_reset_count>0) begin
            fifo_reset_count <= fifo_reset_count-1;
            fifo_ready<=1'b0;
        end else
            fifo_ready<=1'b1;
    end

    task automatic chk(input bit good,input string what);
        checks++;
        if(!good) $fatal(1,"CHECK FAILED: %s t=%0t state=%0d",what,$time,fsm_state);
    endtask
    task automatic tick;
        @(posedge clk); #0.1;
    endtask
    task automatic advance_to(input logic [3:0] wanted,input integer max_cycles);
        integer i;
        begin
            for(i=0;i<max_cycles && fsm_state!==wanted;i=i+1) tick();
            chk(fsm_state===wanted,$sformatf("state %0d within %0d cycles",wanted,max_cycles));
        end
    endtask
    task automatic start_run;
        begin
            @(negedge clk);cmd_start=1;
            #0.1;chk(guard_check_req,"guard request accompanies START");
            chk(cfg_write_lock,"configuration is locked on START request");
            tick();
            @(negedge clk);cmd_start=0;
            advance_to(4'd1,12);
            chk(active_n_frames==cfg_nf && active_n_prev_frames==cfg_np && active_n_fragments==cfg_nr,"ACTIVE registers captured");
            chk(run_fragments_completed==0,"new run counter cleared");
            chk(!cfg_write_lock,"configuration unlocked after validation");
        end
    endtask
    task automatic enter_wait;
        begin
            advance_to(4'd1,20);
            advance_to(4'd2,20);
            chk(trigger_accept_enable,"accept enabled in WAIT");
            chk(fifo_drop_enable,"DROP enabled in WAIT");
        end
    endtask
    task automatic accept_trigger(input bit same_edge_frame_done);
        begin
            @(negedge clk);trigger_accept=1;frame_stored=same_edge_frame_done;
            #0.1;chk(trigger_accept_enable,"trigger acceptance permitted");
            tick();
            chk(fsm_state==4'd3,"entered transfer on trigger");
            chk(frames_captured==active_n_prev_frames+{31'd0,same_edge_frame_done},"trigger edge frame accounting");
            chk(status_trigger_latched,"trigger latch held");
            chk(fragment_start_pulse,"packer and writer start next cycle");
            @(negedge clk);trigger_accept=0;frame_stored=0;
            tick();
            chk(!fragment_start_pulse,"fragment start is one clock pulse");
            chk(fifo_transfer_enable,"transfer is enabled after start");
        end
    endtask
    task automatic send_post_frame;
        begin
            @(negedge clk);frame_stored=1;
            tick();
            @(negedge clk);frame_stored=0;
        end
    endtask
    task automatic finish_writer(input logic [17:0] committed,input logic [31:0] expect_status);
        begin
            @(negedge clk);
            writer_frames_committed=committed;writer_preamble_committed=1;writer_done=1;
            #0.1;
            if(expect_status==1) chk(fragment_complete_pulse,"complete pulse on success only");
            else chk(!fragment_complete_pulse,"partial STOP does not count complete");
            tick();
            chk(fsm_state==4'd4,"enter cleanup after writer_done");
            chk(last_fragment_status==expect_status,"last fragment completion status");
            chk(last_fragment_frames==committed,"committed frame total saved");
            chk(last_fragment_size==128+committed*768,"last byte size includes preamble");
            @(negedge clk);writer_done=0;writer_preamble_committed=0;writer_frames_committed=0;
        end
    endtask
    task automatic stop_without_fragment;
        begin
            @(negedge clk);cmd_stop=1;capture_stopped=1;
            #0.1;chk(!trigger_accept_enable,"STOP masks trigger");
            tick();
            chk(fsm_state==4'd4,"STOP before trigger initiates flush");
            @(negedge clk);cmd_stop=0;capture_stopped=0;
            advance_to(4'd0,20);
            chk(!status_busy,"idle after STOP");
        end
    endtask
    task automatic soft_reset;
        begin
            @(negedge clk);rst=1;cmd_stop=0;cmd_start=0;trigger_accept=0;
            frame_stored=0;capture_stopped=0;fatal_error=0;cmd_clear_error=0;
            repeat(3)tick();
            @(negedge clk);rst=0;
            repeat(5)tick();
            chk(fsm_state==4'd0,"reset -> IDLE");
        end
    endtask

    initial begin
        $display("[TEST] reset and command permissions");groups++;
        soft_reset();
        chk(allow_start&&allow_clear_error&&allow_clear_stats,"idle permissions");
        chk(!status_busy&&!trigger_accept_enable,"idle disables trigger");

        $display("[TEST] START guard approval, shadow/ACTIVE snapshot, FIFO sync");groups++;
        cfg_nf=4;cfg_np=2;cfg_nr=2;
        start_run();
        #0.1;chk(!capture_enable,"capture disabled until sync request");
        advance_to(4'd1,4);
        @(negedge clk);frame_sync_ready=1;fifo_complete_frames=2;
        enter_wait();
        chk(fragment_addr==cfg_base,"initial address captured from ACTIVE after START edge");

        $display("[TEST] trigger on TLAST counted as first POST; start delayed 1 cycle");groups++;
        accept_trigger(1'b1);
        chk(frames_captured==3,"2 PRE + coincident POST TLAST");
        chk(fragment_index==0&&fragment_addr==cfg_base,
            $sformatf("first fragment address: got %08h, expected %08h",fragment_addr,cfg_base));
        send_post_frame();
        chk(frames_captured==4,"reaches requested 4 frames");
        chk(!capture_enable&&status_capture_complete,"no extra camera frames stored");
        finish_writer(4,1);
        chk(run_fragments_completed==1,"one completed fragment");
        advance_to(4'd1,20);

        $display("[TEST] second fragment address stride; run target -> END_STATE");groups++;
        fifo_complete_frames=2;frame_sync_ready=1;
        enter_wait();
        accept_trigger(1'b0);
        chk(fragment_index==1,"next fragment counter");
        chk(fragment_addr==cfg_base+(128+4*768),
            $sformatf("next fragment address: got %08h, expected %08h",
                      fragment_addr,cfg_base+(128+4*768)));
        send_post_frame();send_post_frame();
        chk(frames_captured==4,"reached second target");
        finish_writer(4,1);
        advance_to(4'd6,20);
        chk(!allow_start&&allow_clear_stats,"END state permissions");
        chk(run_fragments_completed==2,"two completed fragments");
        @(negedge clk);cmd_stop=1;tick();
        chk(fsm_state==4'd0,"END STOP -> IDLE");
        @(negedge clk);cmd_stop=0;

        $display("[TEST] guard rejects invalid n_fragments and holds IDLE");groups++;
        cfg_nr=0;
        @(negedge clk);cmd_start=1;tick();
        @(negedge clk);cmd_start=0;
        begin : await_rejected_start
            integer wait_cycles;
            wait_cycles = 0;
        
            while (cfg_write_lock && wait_cycles < 32) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
        end
        chk(fsm_state==4'd0,"invalid run remains idle");
        chk(guard_error_set_mask==0,"error mask pulse has ended");
        chk(!cfg_write_lock,"invalid check unlocks config");
        chk(sticky_error_flags[6],"invalid n_fragments produces sticky error bit");
        chk(!allow_start,"pending error blocks another START");
        @(negedge clk);cmd_clear_error=1;
        #0.1;chk(allow_clear_error,"CLEAR_ERROR allowed in IDLE");
        tick();
        @(negedge clk);cmd_clear_error=0;
        tick();
        chk(sticky_error_flags==0 && allow_start,"clearing error re-enables START");
        cfg_nr=2;

        $display("[TEST] STOP while waiting for trigger flushes without DDR write");groups++;
        fifo_complete_frames=0;frame_sync_ready=1;
        start_run();
        @(negedge clk);fifo_complete_frames=2;
        enter_wait();
        stop_without_fragment();

        $display("[TEST] STOP during transfer sends precise partial target");groups++;
        cfg_nf=7;cfg_np=2;cfg_nr=1;cfg_base=32'h24000000;
        fifo_complete_frames=0;
        start_run();
        @(negedge clk);fifo_complete_frames=2;
        enter_wait();
        chk(fragment_addr==cfg_base,"new run uses new base, not previous run address");
        accept_trigger(1'b0);
        send_post_frame(); // 2 PRE + 1 POST = 3
        @(negedge clk);cmd_stop=1;capture_stopped=1;frame_stored=1;
        #0.1;chk(frame_stop_request,"STOP forwarded to frame input");
        tick();
        chk(frames_captured==4,"final frame accounted on STOP edge");
        chk(!capture_enable,"capture disabled after STOP boundary");
        @(negedge clk);cmd_stop=0;capture_stopped=0;frame_stored=0;
        #0.1;chk(stop_target_valid&&stop_target_frames==4,"exact packer stop target");
        tick();
        chk(!stop_target_valid,"STOP target emitted once");
        finish_writer(4,2);
        chk(last_fragment_addr==cfg_base,"STOP partial record keeps new base");
        chk(run_fragments_completed==0,"partial fragment not counted");
        advance_to(4'd0,20);
        chk(last_fragment_status==2,"STOP status retained in IDLE");

        $display("[TEST] STOP and trigger same edge: STOP takes priority");groups++;
        cfg_nf=4;cfg_np=2;cfg_nr=1;fifo_complete_frames=0;
        start_run();
        @(negedge clk);fifo_complete_frames=2;
        enter_wait();
        @(negedge clk);cmd_stop=1;capture_stopped=1;
        #0.1;chk(!trigger_accept_enable,"trigger masked by STOP");
        tick();
        chk(fsm_state==4'd4,"STOP led to cleanup instead of transfer");
        @(negedge clk);cmd_stop=0;capture_stopped=0;
        advance_to(4'd0,20);

        $display("[TEST] fatal error waits for W/AW/B drain before ERROR");groups++;
        fifo_complete_frames=0;
        start_run();
        @(negedge clk);fifo_complete_frames=2;
        enter_wait();
        accept_trigger(1'b0);
        @(negedge clk);writer_drain_done=0;fatal_error=1;
        #0.1;chk(packer_abort&&writer_halt_new,"fault halts new descriptors");
        tick();
        chk(fsm_state==4'd3,"not in ERROR while AXI not drained");
        @(negedge clk);fatal_error=0;
        repeat(3)tick();
        chk(fsm_state==4'd3&&writer_halt_new,"keep abort during draining");
        @(negedge clk);writer_drain_done=1;
        tick();
        chk(fsm_state==4'd5,"drain -> ERROR");
        chk(last_fragment_status==3&&last_fragment_size==0,"errored data not verified");
        chk(!allow_clear_error,"clear blocked until FIFO flush");
        advance_to(4'd5,10);
        repeat(8)tick();
        chk(allow_clear_error,"clear allowed after FIFO flush");
        @(negedge clk);cmd_clear_error=1;tick();
        chk(fsm_state==4'd0,"clear error -> IDLE");
        @(negedge clk);cmd_clear_error=0;

        $display("[TEST] STOP boundary and fatal fault on same edge: ERROR wins");groups++;
        cfg_nf=7; cfg_np=2; cfg_nr=1; fifo_complete_frames=0;
        start_run();
        @(negedge clk);fifo_complete_frames=2;
        enter_wait();
        accept_trigger(1'b0);
        @(negedge clk);
        cmd_stop=1; capture_stopped=1; frame_stored=1;
        writer_drain_done=0; fatal_error=1;
        #0.1;
        chk(writer_halt_new && packer_abort,"fatal fault immediately stops new AXI requests");
        chk(!stop_target_valid,"no STOP target is issued on fatal fault edge");
        tick();
        chk(fsm_state==4'd3,"must wait for AXI drain on simultaneous STOP/fault");
        @(negedge clk);
        cmd_stop=0; capture_stopped=0; frame_stored=0; fatal_error=0;
        repeat(2)tick();
        chk(writer_halt_new && !stop_target_valid,"abort persists; STOP target suppressed");
        @(negedge clk);writer_drain_done=1;
        tick();
        chk(fsm_state==4'd5,"ERROR reached after AXI drain");
        chk(last_fragment_status==3,"fatal error wins over STOP status");
        repeat(8)tick();
        chk(allow_clear_error,"clear allowed after error cleanup");
        @(negedge clk);cmd_clear_error=1;
        tick();
        chk(fsm_state==4'd0,"clear after coincident STOP/error -> IDLE");
        @(negedge clk);cmd_clear_error=0;

        $display("[TEST] fatal error during BUFFER_FILLING needs no AXI drain");groups++;
        fifo_complete_frames=0;start_run();
        @(negedge clk);fatal_error=1;writer_drain_done=0;
        tick();
        chk(fsm_state==4'd5,"pre-transfer fault enters ERROR immediately");
        @(negedge clk);fatal_error=0;writer_drain_done=1;
        repeat(10)tick();
        chk(allow_clear_error,"pre-transfer error recovery available");

        $display("PASS: %0d groups, %0d checks",groups,checks);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"TIMEOUT: testbench did not finish");
    end
endmodule
`default_nettype wire
