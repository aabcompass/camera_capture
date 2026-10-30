/*
ORIGINAL USER TECHNICAL SPECIFICATION (verbatim, in Russian):

Привет. Давай обсудим (пока без разработки кода) создание IP-ядра для Xilinx
xc7z035 для отбора данных с высокоскоростной камеры. Основная функция ядра -
принимать на вход поток научных данных по шине S_AXIS и выдавать их фрагменты
через порт M_AXI (Basic Write Master, ширина 64 бита) в ZYNQ_PS через порт
S_AXI_HP AXI3 без interconnect. S_AXIS: Ширина - 64bit with TLAST. Скорость
поступления 307200000 байт/с кадрами размером 16*48 байт. TLAST указывает на
окончание кадра. Фрагмент, передаваемый в PS, состоит из n_frames кадров. Выдача
фрагментов происходит по триггеру.

ТРИГГЕР. Порт с отдельного ядра триггера. Ядро имеет вход S_AXIS_TRG с данными
шириной [63:0], с TVALID. Если на этот вход поступило ненулевое значение, значит
сработал алгоритмический триггер. Внешний триггер. Ядро должно иметь функцию
старта по сигналу с внешнего логического входа ext_trig. Внутренний триггер.
Ядро должно иметь функцию генерации внутренних триггерных сигналов - однократных
и периодических.

БУФЕР. FIFO. работает как сдвиговый буфер. Как только в FIFO накопилось
n_prev_frames кадров, каждое входящее слово параллельно вычитывается и
выбрасывается. В состав ядра входит буфер, который должен хранить последние
n_prev_frames кадра + дополнительное пространство для научных данных, которые
поступают во время вычитывания кадров, записанных до триггера. По триггеру нужно
отправить n_frames в zynq_ps, включая n_prev_frames из буфера. В память
отправляются только полные кадры. Если произошло переполнение буфера ( Во время
вычитывания данных при длительном посте-триггере шина AXI затормозила, и
входящий поток начал затирать кадры, которые мы еще не успели отправить в PS),
инкрементируем счетчик ошибок переполнения буфера. При переполнении ядро
переходит в состоянии ошибки. Передача в память останавливается. Максимальное
значение n_frames = 131072. Минимальное = 2. Максимальное значение n_prev_frames
= 64. Буфер реализуется с помощью fifo на 100 кадров.

ПРЕАМБУЛА. Размер преамбулы 128 байт (размер burst) В начало перед каждым
фрагментом отправляем преамбулу: 4 байт - id - заголовок-идентификатор
(конфигурируется через AXI_LITE) 4 байт - счетчик-инкремент на 1, начиная с 0. 8
байт - timestamp - метка времени - значение с дополнительного входного порта
timestamp[63:0]. Защелкивается в такт прихода триггера. 8 байт - S_AXIS_TRG.data
32 байт - aux_data. Берем из регистров AXI_LITE Остальные байты паддим
значением 0x12345678 Endianness - little endian. Выравнивание - по границам 32
бит.

КОНФИГУРИРОВАНИЕ. Должен быть конфигурационный порт AXI_LITE.
Параметры/команды 32-битные, передаваемые через AXI_LITE: старт,
стоп переключение триггерных входов. n_prev_frames n_frames n_fragments - число
фрагментов, после выдачи которых ядро переходит в end_state. mem_addr Еще
должны быть статусные регистры

ВОЗМОЖНЫЕ СОСТОЯНИЯ ЯДРА

1.  idle: Ожидание входных данных (буфер пуст). Триггер игнорируется. Перед из
    этого состояния в состояние buffer_filling - по команде start.
2.  buffer_filling: Заполнение буфера. Данные начали поступать, но буфер еще не
    заполнен. Триггер игнорируется.
3.  trig_wait: Ожидание триггера. Данные с детектора поступают на вход FIFO,
    буфер FIFO непрерывно обновляется, проходя через FIFO. Логика (drop logic)
    удерживает триггер заполненным на n_prev_frames через управления его
    m_axis_tready. Выход FIFO отключен от выходного порта ядра. Допускается
    неточность соблюдения n_prev_frames плюс/минус 1.
4.  data_transfer: Данные с выхода FIFO начинают передаваться в PS. Выход FIFO
    соединяется с портом на PS. Данные с детектора поступают на вход FIFO.
    Триггер игнорируется.
5.  after_transfer: Сброс буфера. Далее переход в состояние buffer_filling. i++.
    Если i=n_records, переходим в end_state. Триггер игнорируется. Под сбросом
    буфера понимается полная очистка FIFO (Flush/Reset), после чего мы снова
    ждем наполнения до n_prev_frames.
6.  error_state: Состояние, в которое попадает ядро в случае, если буфер
    переполнился. Выход из данного состояния только по команде из PS. Триггер
    игнорируется.
7.  end_state: Ожидание команды из PS на переход в idle. Триггер игнорируется.

АДРЕСАЦИЯ: Данные последовательно пишутся по адресу mem_addr. для каждого
следующего фрагмента ядро должно самостоятельно сдвигать адрес на размер
фрагмента (128 байт + n_frames×768 байт)

МЕРТВОЕ ВРЕМЯ: Во время отправки данных сигналы триггеров игнорируем.

СТАСТИСТИКА: Ведем посчет обработанных и пропущенных триггеров Ведем подсчет
ошибок отправки в PS.

ТАКТОВЫЕ ДОМЕНЫ: Единый тактовый домен 200 МГц

ДЕЙСТВИЕ ПО КОМАНДЕ STOP По команде stop дописывается последний frame,
сбрасывается буфер, после чего ядро переходит в idle

ПРЕРЫВАНИЯ: без прерываний

Текст ТЗ нужно включить комментарием в топовый блок

END OF ORIGINAL USER SPECIFICATION.
Later agreed amendments (implemented/validated incrementally):
- The camera cannot backpressure; S_AXIS_TREADY is always 1.
- n_fragments = 0 is forbidden.
- The frame containing the trigger, including a trigger coincident with
  TLAST, is the first post-trigger frame.
- STOP finishes the current input frame, not the whole fragment.
- MEM_BUFFER_BYTES guards the run and each 128-byte burst.
- Max pretrigger is min(64, n_frames-1); physical XPM depth 16384,
  logical usable capacity 9600 words.
*/
`default_nettype none
module camera_capture_top #(
    parameter bit USE_XPM = 1'b1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [63:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire [63:0]  s_axis_trg_tdata,
    input  wire         s_axis_trg_tvalid,
    input  wire         ext_trig,
    input  wire [63:0]  timestamp,
    // AXI4-Lite slave (32-bit)
    input  wire [31:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [31:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,
    // AXI3 basic write master to Zynq S_AXI_HP, 64-bit
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
    output wire [5:0]   m_axi_wid,
    output wire [63:0]  m_axi_wdata,
    output wire [7:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [5:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready
);
    wire cmd_start, cmd_stop, cmd_clear_error, cmd_clear_stats;
    wire int_single_pulse;
    wire [2:0] cfg_trigger_enable, active_trigger_enable;
    wire [31:0] cfg_n_frames, cfg_n_prev_frames, cfg_n_fragments;
    wire [31:0] cfg_mem_addr, cfg_mem_buffer_bytes, cfg_header_id;
    wire [255:0] cfg_aux_data;
    wire [31:0] cfg_int_trig_period;
    wire cfg_int_periodic_enable;
    wire [31:0] active_n_frames, active_n_prev_frames, active_n_fragments;
    wire [31:0] active_mem_addr, active_mem_buffer_bytes, active_header_id;
    wire [255:0] active_aux_data;
    wire [31:0] active_int_trig_period;
    wire active_int_periodic_enable;
    wire [31:0] sticky_error_flags, error_set_mask;

    wire [3:0] fsm_state;
    wire allow_start, allow_clear_error, allow_clear_stats, cfg_write_lock;
    wire guard_check_req, run_start_pulse;
    wire [31:0] guard_error_set_mask;
    wire guard_check_done, guard_check_ok;
    wire [31:0] guard_check_error_flags, guard_fragment_bytes;
    wire [63:0] guard_total_required_bytes, guard_buffer_end_exclusive;
    wire frame_sync_request, capture_enable, frame_stop_request;
    wire fifo_flush, fifo_drop_enable, fifo_transfer_enable;
    wire trigger_run_active, trigger_accept_enable, trigger_count_enable;
    wire fragment_start_pulse, packer_abort, writer_halt_new;
    wire stop_target_valid;
    wire [17:0] stop_target_frames, fragment_n_frames;
    wire [31:0] fragment_addr, fragment_index;
    wire status_busy, status_stop_pending, status_trigger_latched;
    wire status_capture_complete, fragment_complete_pulse;
    wire [31:0] frames_captured, run_fragments_completed;
    wire [31:0] last_fragment_addr, last_fragment_frames;
    wire [31:0] last_fragment_size, last_fragment_status;

    wire [64:0] fifo_wr_data, fifo_rd_data;
    wire fifo_wr_req, fifo_wr_accepted;
    wire frame_start, frame_done, captured_frame_done, frame_active;
    wire [6:0] frame_word_index;
    wire frame_sync_ready, capture_stopped, frame_format_error, fifo_write_error;
    wire [63:0] frame_sequence;
    wire fifo_ready, fifo_rd_valid, fifo_rd_ready;
    wire [13:0] fifo_level_words;
    wire [7:0] fifo_complete_frames, drops_remaining;
    wire fifo_logical_full, fifo_overflow_pulse, fifo_overflow_sticky;
    wire drop_active, drop_frame_done, fifo_triggered, fifo_transfer_ready;
    wire popped_frame_done;

    wire alg_event, ext_event, int_event, trigger_event, trigger_accept;
    wire [1:0] trigger_event_count, trigger_missed_events, trigger_source;
    wire [63:0] trigger_data, latched_timestamp, latched_trigger_data;
    wire [1:0] latched_trigger_source;
    wire [63:0] triggers_accepted_total, triggers_missed_total;

    wire burst_valid, burst_ready, burst_is_preamble, burst_ends_frame;
    wire [3:0] burst_word_count_minus_one;
    wire [63:0] p_wdata;
    wire p_wvalid, p_wready, p_wlast;
    wire packer_active, packer_done, packer_format_error, packer_target_error;
    wire [17:0] frames_packed, frames_sent;
    wire [31:0] bursts_sent;
    wire writer_active, writer_drain_done, writer_done;
    wire writer_range_error, writer_bresp_error, writer_protocol_error;
    wire [31:0] writer_last_error_addr, current_write_addr;
    wire [1:0] writer_last_bresp;
    wire [2:0] writer_outstanding;
    wire [31:0] bursts_issued, bursts_w_sent, bursts_committed;
    wire [17:0] writer_frames_committed;
    wire writer_preamble_committed;
    wire [31:0] fragments_completed_total, fifo_overflow_count;
    wire [31:0] axi_error_count, last_error_code, last_error_addr;

    // The writer and packer retain sticky faults after a failed fragment.
    // Ignore their previous-run state until the new fragment's start pulse
    // has actually reset them on a clock edge.
    logic writer_live_for_fragment;
    always_ff @(posedge clk) begin
        if (rst) writer_live_for_fragment <= 1'b0;
        else if (fragment_start_pulse) writer_live_for_fragment <= 1'b1;
        else if (fsm_state != 4'd3) writer_live_for_fragment <= 1'b0;
    end

    wire live_writer_fault = writer_live_for_fragment &&
                (writer_range_error || writer_bresp_error || writer_protocol_error);
    wire live_packer_fault = writer_live_for_fragment &&
                (packer_format_error || packer_target_error);
    // Do not feed input faults combinationally back into capture_enable:
    // capture_enable -> FIFO request -> overflow -> fatal_error would form
    // an unstable combinational loop. Record the fault at the same edge as
    // the rejected camera beat, then let the FSM perform error handling.
    logic input_fault_latched;
    wire raw_input_fault = frame_format_error || fifo_write_error ||
                           fifo_overflow_pulse;
    always_ff @(posedge clk) begin
        if (rst || run_start_pulse || cmd_clear_error)
            input_fault_latched <= 1'b0;
        else if (status_busy && raw_input_fault)
            input_fault_latched <= 1'b1;
    end
    wire fatal_error = live_writer_fault || live_packer_fault ||
                       input_fault_latched;

    logic [31:0] data_error_mask;
    always_comb begin
        data_error_mask = 32'd0;
        // Bit positions from the agreed AXI-Lite register specification.
        data_error_mask[0]  = capture_enable &&
                          (fifo_overflow_pulse || fifo_write_error);
        data_error_mask[1]  = writer_live_for_fragment && writer_bresp_error &&
                          (writer_last_bresp != 2'b11);
        data_error_mask[2]  = writer_live_for_fragment && writer_bresp_error &&
                          (writer_last_bresp == 2'b11);
        data_error_mask[3]  = (capture_enable && frame_format_error) ||
                          (writer_live_for_fragment && packer_format_error);
        data_error_mask[10] = writer_live_for_fragment && writer_range_error;
        data_error_mask[12] = writer_live_for_fragment && writer_protocol_error;
        data_error_mask[13] = writer_live_for_fragment && packer_target_error;
    end
    assign error_set_mask = guard_error_set_mask | data_error_mask;

    axi_lite_regs u_regs (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .allow_start(allow_start), .allow_clear_error(allow_clear_error),
        .allow_clear_stats(allow_clear_stats), .cfg_write_lock(cfg_write_lock),
        .run_start_pulse(run_start_pulse), .cmd_start(cmd_start), .cmd_stop(cmd_stop),
        .cmd_clear_error(cmd_clear_error), .cmd_clear_stats(cmd_clear_stats),
        .int_single_pulse(int_single_pulse),
        .cfg_trigger_enable(cfg_trigger_enable), .cfg_n_frames(cfg_n_frames),
        .cfg_n_prev_frames(cfg_n_prev_frames), .cfg_n_fragments(cfg_n_fragments),
        .cfg_mem_addr(cfg_mem_addr), .cfg_mem_buffer_bytes(cfg_mem_buffer_bytes),
        .cfg_header_id(cfg_header_id), .cfg_aux_data(cfg_aux_data),
        .cfg_int_trig_period(cfg_int_trig_period),
        .cfg_int_periodic_enable(cfg_int_periodic_enable),
        .active_trigger_enable(active_trigger_enable),
        .active_n_frames(active_n_frames), .active_n_prev_frames(active_n_prev_frames),
        .active_n_fragments(active_n_fragments), .active_mem_addr(active_mem_addr),
        .active_mem_buffer_bytes(active_mem_buffer_bytes),
        .active_header_id(active_header_id), .active_aux_data(active_aux_data),
        .active_int_trig_period(active_int_trig_period),
        .active_int_periodic_enable(active_int_periodic_enable),
        .fsm_state(fsm_state), .status_busy(status_busy),
        .status_stop_pending(status_stop_pending),
        .status_trigger_latched(status_trigger_latched),
        .status_capture_complete(status_capture_complete),
        .status_axi_busy(writer_active && !writer_drain_done),
        .status_fifo_empty(fifo_level_words == 14'd0),
        .status_fifo_full(fifo_logical_full),
        .error_set_mask(error_set_mask), .error_flags(sticky_error_flags),
        .last_error_code(last_error_code), .last_error_addr(last_error_addr),
        .fifo_level({18'd0, fifo_level_words}), .frames_captured(frames_captured),
        .frames_sent({14'd0, frames_sent}),
        .frames_committed({14'd0, writer_frames_committed}),
        .fragments_completed(fragments_completed_total),
        .triggers_accepted_total(triggers_accepted_total),
        .triggers_missed_total(triggers_missed_total),
        .fifo_overflow_count(fifo_overflow_count),
        .axi_error_count(axi_error_count),
        .current_write_addr(current_write_addr),
        .last_timestamp(latched_timestamp),
        .last_trigger_data(latched_trigger_data),
        .last_trigger_source({30'd0,latched_trigger_source}),
        .last_fragment_addr(last_fragment_addr),
        .last_fragment_frames(last_fragment_frames),
        .last_fragment_size(last_fragment_size),
        .last_fragment_status(last_fragment_status),
        .run_fragments_completed(run_fragments_completed)
    );

    mem_range_guard u_guard (
        .clk(clk), .rst(rst), .check_req(guard_check_req),
        .n_frames(cfg_n_frames), .n_prev_frames(cfg_n_prev_frames),
        .n_fragments(cfg_n_fragments), .mem_addr(cfg_mem_addr),
        .mem_buffer_bytes(cfg_mem_buffer_bytes),
        .periodic_enable(cfg_int_periodic_enable),
        .int_trig_period(cfg_int_trig_period),
        .check_done(guard_check_done), .check_ok(guard_check_ok),
        .check_error_flags(guard_check_error_flags),
        .fragment_bytes(guard_fragment_bytes),
        .total_required_bytes(guard_total_required_bytes),
        .buffer_end_exclusive(guard_buffer_end_exclusive)
    );

    capture_main_fsm u_fsm (
        .clk(clk), .rst(rst),
        .cmd_start(cmd_start), .cmd_stop(cmd_stop),
        .cmd_clear_error(cmd_clear_error),
        .sticky_error_flags(sticky_error_flags),
        .active_n_frames(active_n_frames),
        .active_n_prev_frames(active_n_prev_frames),
        .active_n_fragments(active_n_fragments),
        .active_mem_addr(active_mem_addr),
        .allow_start(allow_start), .allow_clear_error(allow_clear_error),
        .allow_clear_stats(allow_clear_stats),
        .cfg_write_lock(cfg_write_lock), .guard_check_req(guard_check_req),
        .run_start_pulse(run_start_pulse),
        .guard_error_set_mask(guard_error_set_mask),
        .guard_check_done(guard_check_done), .guard_check_ok(guard_check_ok),
        .guard_check_error_flags(guard_check_error_flags),
        .guard_fragment_bytes(guard_fragment_bytes),
        .fifo_ready(fifo_ready), .fifo_complete_frames(fifo_complete_frames),
        .frame_sync_ready(frame_sync_ready), .frame_stored(captured_frame_done),
        .capture_stopped(capture_stopped),
        .trigger_accept(trigger_accept), .fatal_error(fatal_error),
        .frame_sync_request(frame_sync_request),
        .capture_enable(capture_enable),
        .frame_stop_request(frame_stop_request), .fifo_flush(fifo_flush),
        .fifo_drop_enable(fifo_drop_enable),
        .fifo_transfer_enable(fifo_transfer_enable),
        .trigger_run_active(trigger_run_active),
        .trigger_accept_enable(trigger_accept_enable),
        .trigger_count_enable(trigger_count_enable),
        .fragment_start_pulse(fragment_start_pulse),
        .packer_abort(packer_abort), .writer_halt_new(writer_halt_new),
        .stop_target_valid(stop_target_valid),
        .stop_target_frames(stop_target_frames),
        .fragment_n_frames(fragment_n_frames),
        .fragment_addr(fragment_addr),
        .fragment_index(fragment_index),
        .writer_done(writer_done), .writer_drain_done(writer_drain_done),
        .writer_frames_committed(writer_frames_committed),
        .writer_preamble_committed(writer_preamble_committed),
        .fsm_state(fsm_state), .status_busy(status_busy),
        .status_stop_pending(status_stop_pending),
        .status_trigger_latched(status_trigger_latched),
        .status_capture_complete(status_capture_complete),
        .frames_captured(frames_captured),
        .run_fragments_completed(run_fragments_completed),
        .fragment_complete_pulse(fragment_complete_pulse),
        .last_fragment_addr(last_fragment_addr),
        .last_fragment_frames(last_fragment_frames),
        .last_fragment_size(last_fragment_size),
        .last_fragment_status(last_fragment_status)
    );

    frame_input_ctrl u_input (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .sync_request(frame_sync_request), .capture_enable(capture_enable),
        .stop_request(frame_stop_request),
        .fifo_wr_data(fifo_wr_data), .fifo_wr_req(fifo_wr_req),
        .fifo_wr_accepted(fifo_wr_accepted),
        .frame_start(frame_start), .frame_done(frame_done),
        .captured_frame_done(captured_frame_done), .frame_active(frame_active),
        .frame_word_index(frame_word_index),
        .frame_sync_ready(frame_sync_ready), .capture_stopped(capture_stopped),
        .frame_format_error(frame_format_error),
        .fifo_write_error(fifo_write_error),
        .frame_sequence(frame_sequence)
    );

    capture_fifo_ctrl #(.USE_XPM(USE_XPM)) u_fifo_ctrl (
        .clk(clk), .rst(rst), .fifo_flush(fifo_flush),
        .fifo_ready(fifo_ready), .write_data(fifo_wr_data),
        .write_req(fifo_wr_req), .write_accepted(fifo_wr_accepted),
        .frame_stored(captured_frame_done),
        .n_prev_frames(active_n_prev_frames[6:0]),
        .drop_enable(fifo_drop_enable), .trigger_accept(trigger_accept),
        .transfer_enable(fifo_transfer_enable),
        .read_data(fifo_rd_data), .read_valid(fifo_rd_valid),
        .read_ready(fifo_rd_ready),
        .fifo_level_words(fifo_level_words),
        .complete_frames(fifo_complete_frames),
        .logical_full(fifo_logical_full),
        .overflow_pulse(fifo_overflow_pulse),
        .overflow_sticky(fifo_overflow_sticky),
        .drop_active(drop_active), .drop_frame_done(drop_frame_done),
        .triggered(fifo_triggered),
        .drops_remaining(drops_remaining),
        .transfer_ready(fifo_transfer_ready),
        .popped_frame_done(popped_frame_done)
    );

    trigger_ctrl u_trigger (
        .clk(clk), .rst(rst),
        .s_axis_trg_tdata(s_axis_trg_tdata),
        .s_axis_trg_tvalid(s_axis_trg_tvalid),
        .ext_trig_async(ext_trig),
        .int_single_pulse(int_single_pulse),
        .int_periodic_enable(active_int_periodic_enable),
        .int_period_cycles(active_int_trig_period),
        .trigger_enable(active_trigger_enable),
        .timestamp(timestamp),
        .run_start(run_start_pulse),
        .run_active(trigger_run_active),
        .accept_enable(trigger_accept_enable),
        .count_enable(trigger_count_enable),
        .clear_stats(cmd_clear_stats),
        .alg_event(alg_event), .ext_event(ext_event),
        .int_event(int_event), .trigger_event(trigger_event),
        .trigger_accept(trigger_accept),
        .trigger_event_count(trigger_event_count),
        .trigger_missed_events(trigger_missed_events),
        .trigger_source(trigger_source),
        .trigger_data(trigger_data),
        .latched_timestamp(latched_timestamp),
        .latched_trigger_data(latched_trigger_data),
        .latched_trigger_source(latched_trigger_source),
        .triggers_accepted_total(triggers_accepted_total),
        .triggers_missed_total(triggers_missed_total)
    );

    burst_packer u_packer (
        .clk(clk), .rst(rst), .start(fragment_start_pulse),
        .abort(packer_abort), .n_frames(fragment_n_frames),
        .header_id(active_header_id), .fragment_index(fragment_index),
        .timestamp(latched_timestamp),
        .trigger_data(latched_trigger_data),
        .aux_data(active_aux_data),
        .stop_target_valid(stop_target_valid),
        .stop_target_frames(stop_target_frames),
        .in_data(fifo_rd_data), .in_valid(fifo_rd_valid),
        .in_ready(fifo_rd_ready),
        .burst_valid(burst_valid), .burst_ready(burst_ready),
        .burst_is_preamble(burst_is_preamble),
        .burst_ends_frame(burst_ends_frame),
        .burst_word_count_minus_one(burst_word_count_minus_one),
        .w_data(p_wdata), .w_valid(p_wvalid),
        .w_ready(p_wready), .w_last(p_wlast),
        .active(packer_active), .packer_done(packer_done),
        .format_error(packer_format_error),
        .target_error(packer_target_error),
        .frames_packed(frames_packed), .frames_sent(frames_sent),
        .bursts_sent(bursts_sent)
    );

    axi3_write_master u_writer (
        .clk(clk), .rst(rst), .start(fragment_start_pulse),
        .halt_new(writer_halt_new), .start_addr(fragment_addr),
        .mem_base_addr(active_mem_addr),
        .mem_buffer_bytes(active_mem_buffer_bytes),
        .packer_done(packer_done),
        .burst_valid(burst_valid), .burst_ready(burst_ready),
        .burst_is_preamble(burst_is_preamble),
        .burst_ends_frame(burst_ends_frame),
        .burst_word_count_minus_one(burst_word_count_minus_one),
        .p_wdata(p_wdata), .p_wvalid(p_wvalid),
        .p_wready(p_wready), .p_wlast(p_wlast),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wid(m_axi_wid), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .active(writer_active), .drain_done(writer_drain_done),
        .writer_done(writer_done), .range_error(writer_range_error),
        .bresp_error(writer_bresp_error),
        .protocol_error(writer_protocol_error),
        .last_error_addr(writer_last_error_addr),
        .last_bresp(writer_last_bresp),
        .outstanding(writer_outstanding),
        .bursts_issued(bursts_issued),
        .bursts_w_sent(bursts_w_sent),
        .bursts_committed(bursts_committed),
        .frames_committed(writer_frames_committed),
        .preamble_committed(writer_preamble_committed),
        .current_write_addr(current_write_addr)
    );

    capture_statistics u_stats (
        .clk(clk), .rst(rst), .clear_stats(cmd_clear_stats),
        .clear_error(cmd_clear_error),
        .fragment_complete_pulse(fragment_complete_pulse),
        .fifo_overflow_pulse(fifo_overflow_pulse),
        .writer_range_error(writer_live_for_fragment && writer_range_error),
        .writer_bresp_error(writer_live_for_fragment && writer_bresp_error),
        .writer_last_bresp(writer_last_bresp),
        .writer_protocol_error(writer_live_for_fragment && writer_protocol_error),
        .writer_last_error_addr(writer_last_error_addr),
        .error_set_mask(error_set_mask),
        .fragments_completed_total(fragments_completed_total),
        .fifo_overflow_count(fifo_overflow_count),
        .axi_error_count(axi_error_count),
        .last_error_code(last_error_code),
        .last_error_addr(last_error_addr)
    );

`ifndef SYNTHESIS
    always @(posedge clk) if (!rst) begin
        if (s_axis_tready !== 1'b1)
            $fatal(1,"The camera must never be backpressured");
        if (fragment_start_pulse && !fifo_triggered)
            $fatal(1,"Fragment started without FIFO trigger latched");
    end
`endif
endmodule
`default_nettype wire
