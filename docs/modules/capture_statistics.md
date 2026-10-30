# ТЗ модуля `capture_statistics.sv`

**Роль:** накопительная диагностика завершённых фрагментов, ошибок FIFO и writer, а также сохранение последнего кода/адреса ошибки.

## Интерфейс

- Reset/control: `clk`, `rst`, `clear_stats`, `clear_error`.
- Events: `fragment_complete_pulse`, `fifo_overflow_pulse`, `writer_range_error`, `writer_bresp_error`, `writer_last_bresp[1:0]`, `writer_protocol_error`, `writer_last_error_addr[31:0]`, `error_set_mask[31:0]`.
- Outputs (32-bit): `fragments_completed_total`, `fifo_overflow_count`, `axi_error_count`, `last_error_code`, `last_error_addr`.

## Контракт

1. `fragments_completed_total` инкрементируется на подтверждённый полный фрагмент.
2. `fifo_overflow_count` инкрементируется на **каждый такт отказа записи** (`overflow_pulse`); если важно считать эпизоды, это отдельное изменение ТЗ.
3. `axi_error_count` инкрементируется при входе в writer fault episode (`writer_error && !writer_error_prev`), а **не** по каждому BRESP.
4. `clear_stats` обнуляет три накопительных счётчика; `clear_error` очищает поля последней ошибки, с приоритетом обработки текущей ошибки, указанным RTL.
5. `last_error_code/addr` сохраняют информацию о последней диагностируемой ошибке; нет прерываний.

## Текущая реализация

Все эти регистры 32 бита. Оригинальное ТЗ требует **статистику ошибок**, но точный состав LAST_* и ширину счётчиков определили при разработке.

## Верификация

Серия отказов FIFO каждое слово, длинный assert writer error (один эпизод), снятие ошибки/повторное появление, CLEAR_STATS во время неактивной системы, CLEAR_ERROR и запись новой ошибки.

## Упрощение

**[OPTION]** Можно объединить некоторые накопительные поля, но лучше сначала определить, какие показатели необходимы для поиска пропусков данных в реальной DDR-системе. Разница между *событием*, *тактом* и *эпизодом* должна быть явно согласована.
