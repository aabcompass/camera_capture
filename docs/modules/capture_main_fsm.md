# ТЗ модуля `capture_main_fsm.sv`

**Роль:** контроллер жизненного цикла захвата/фрагмента, без прямого формирования AXI данных. Согласует START-validation, sync камеры, PRE window, trigger, STOP, AXI drain и recovery.

## Основные интерфейсы

- Управление: `cmd_start/stop/clear_error`, `sticky_error_flags`, ACTIVE параметры `active_n_frames/prev/fragments/mem_addr`.
- Guard handshake: `guard_check_req/done/ok/error_flags/fragment_bytes`, `run_start_pulse`, `cfg_write_lock`.
- Frame/FIFO: `fifo_ready`, `fifo_complete_frames`, `frame_sync_ready`, `frame_stored`, `capture_stopped`, `trigger_accept`, `fatal_error`; выходы `frame_sync_request`, `capture_enable`, `frame_stop_request`, `fifo_flush`, `fifo_drop_enable`, `fifo_transfer_enable`.
- Trigger permissions: `trigger_run_active`, `trigger_accept_enable`, `trigger_count_enable`.
- Packer/writer: `fragment_start_pulse`, `packer_abort`, `writer_halt_new`, `stop_target_valid`, `stop_target_frames[17:0]`, `fragment_n_frames[17:0]`, `fragment_addr/index[31:0]`, `writer_done`, `writer_drain_done`, `writer_frames_committed`, `writer_preamble_committed`.
- STATUS: `fsm_state[3:0]`, busy/stop/trigger/complete, frames_captured, run_fragments_completed, fragment_complete_pulse, last_fragment_*.

## Состояния

| Значение | Имя | Контракт |
|---:|---|---|
| 0 | IDLE | Пустой/сброшенный буфер, принимать только допустимый START; validation до ACTIVE |
| 1 | BUFFER_FILLING | Синхронизация на TLAST и накопление PRE; не принимать trigger |
| 2 | TRIG_WAIT | Поддержание rolling PRE history, разрешение первого valid trigger |
| 3 | DATA_TRANSFER | Запуск packer/writer, получение требуемого числа полных кадров, обновление STOP target |
| 4 | AFTER_TRANSFER | FIFO flush/recovery, возврат к FILL или END/IDLE |
| 5 | ERROR | Ожидание безопасной очистки; возврат через разрешённый CLEAR_ERROR |
| 6 | END_STATE | Нужное число фрагментов выдано, ожидание STOP/выхода в IDLE |

## Инварианты и приоритеты

1. START разрешён из IDLE с нулевыми sticky errors; сначала guard; `run_start_pulse` только на успешном `guard_check_done`.
2. `active_*` меняются NBA в такт `run_start_pulse`; захват `active_mem_addr` начинается **на следующем такте**, не в тот же NBA.
3. При принятом триггере: `frames_captured = n_prev_frames + frame_stored` (если триггер на TLAST, кадр триггера уже засчитан как первый POST). Writer и packer стартуют после фиксации метаданных.
4. В DATA_TRANSFER `frames_captured` считает завершённые кадры, ограничивается `active_n_frames`. При штатном достижении цели дождаться `writer_done` (BRESP).
5. STOP имеет приоритет над триггером в одном такте; завершает текущий кадр, обновляет `stop_target_frames`, допускает только полные кадры. Если до триггера — без DDR.
6. Fatal выше STOP: прекратить выдачу новых burst, дождаться drain уже принятых AXI транзакций при отвечающем slave; ERROR и последующая очистка.
7. Успешные полные фрагменты увеличивают индекс и адрес на `fragment_bytes`; partial STOP фиксирует статус, но не считается полноценным выполнением `n_fragments`.

## [CURRENT] Патчи №1 и №2

- Удалён дублирующий `stop_limit`: в безопасный момент `stop_target_frames = frames_captured[17:0]`.
- Операции next frame count / сравнение обрезаны до 18 бит с сохранением внешнего 32-битного статуса.
- Для корректности на границах обязательны тесты однотактных сочетаний STOP/TLAST/fatal.

## Верификация

Команды из разных состояний, отвергнутый START и delayed check_done, trigger на TLAST, несколько фрагментов и stride, STOP до/в процессе передачи, STOP+trigger, STOP+fatal, ERROR после AW/W/B drain.

## Открытые вопросы

**[OPTION]** Упростить отдельные статусы STOP/trigger_pending только после доказательства эквивалентности всех приоритетных комбинаций: здесь цена ошибки существенно выше потенциального выигрыша FF.
