# ТЗ модуля `frame_input_ctrl.sv`

**Роль:** приём нефильтруемого потока камеры и контроль кадровой структуры. Не управляет AXI3 и не выбирает pretrigger depth.

## Входы / выходы

| Категория | Сигналы |
|---|---|
| Clock/reset | `clk`, `rst` |
| AXIS camera | `s_axis_tdata[63:0]`, `s_axis_tvalid`, `s_axis_tlast`; `s_axis_tready=1` |
| Control | `sync_request`, `capture_enable`, `stop_request` |
| FIFO push | `fifo_wr_data[64:0]={TLAST,DATA}`, `fifo_wr_req`, `fifo_wr_accepted` |
| Events | `frame_start`, `frame_done`, `captured_frame_done`, `capture_stopped`, `frame_format_error`, `fifo_write_error` |
| Diagnostic | `frame_active`, `frame_word_index[6:0]`, `frame_sync_ready`, `frame_sequence[63:0]` |

## Контракт

1. Один полный кадр ровно 96 слов (768 байт); `TLAST` ровно на слове 95 (индексация с 0).
2. Фронт `sync_request` имеет приоритет; на нём данные выбрасываются. До ближайшего **действительного** TLAST данные игнорируются. Следующее valid слово — начало нового кадра.
3. `s_axis_tready=1` **всегда** независимо от заполнения FIFO. Во время запрета capture слова выбрасываются, а не оказывают backpressure.
4. `fifo_wr_req && fifo_wr_accepted` означает запись **на этом же фронте**. Это grant, не ACK на следующем фронте.
5. STOP завершает текущий кадр; когда STOP совпадает с первым словом нового кадра — завершает этот начатый кадр. После STOP запись не возобновляется до нового sync_request. Приоритет RESET > SYNC > STOP.
6. Неправильный TLAST формирует `frame_format_error`. Если часть ошибочного кадра уже попала в FIFO, контроллер системы обязан удалить её при обработке ошибки.
7. События `frame_start/frame_done/captured_frame_done/capture_stopped/...` — **комбинационные однотактные события**, относящиеся к тому же фронту, что и входные слова/команды.

## Текущая реализация

`FRAME_WORDS=96` фиксировано; `frame_sequence` 64-битный счётчик полноценных увиденных кадров, сбрасываемый при `sync_request` и reset.

## Верификация

Пустые TVALID, короткий/длинный кадр, отсутствие TLAST, TLAST при STOP, STOP на первом слове, sync во время кадра, FIFO отказ, отсутствие записи после STOP.

## Кандидат на упрощение

**[OPTION]** Удалить или сузить `frame_sequence` (top его никуда не передаёт); ожидаемый выигрыш после синтеза всего top минимален, если логика уже оптимизирована из-за неиспользуемости.
