# ТЗ модуля `trigger_ctrl.sv`

**Роль:** формировать синхронные события из трёх источников, разрешать только первый допустимый триггер, фиксировать метаданные и вести счётчики принятых/пропущенных событий.

## Интерфейс

- Источники: `s_axis_trg_tdata[63:0]`, `s_axis_trg_tvalid`, `ext_trig_async`, `int_single_pulse`, `int_periodic_enable`, `int_period_cycles[31:0]`.
- Конфигурация: `trigger_enable[2:0]`, `timestamp[63:0]`.
- Разрешения FSM: `run_start`, `run_active`, `accept_enable`, `count_enable`, `clear_stats`.
- События: `alg_event`, `ext_event`, `int_event`, `trigger_event`, `trigger_accept`, `trigger_event_count[1:0]`, `trigger_missed_events[1:0]`.
- Метаданные: `trigger_source[1:0]`, `trigger_data[63:0]`, `latched_timestamp`, `latched_trigger_data`, `latched_trigger_source`.
- Статистика: `triggers_accepted_total[63:0]`, `triggers_missed_total[63:0]` (программный контракт, физическая разрядность после патча №4 — 48).

## Контракт

1. Алгоритмическое событие только при TVALID и ненулевом TDATA; ext — фронт после двух `ASYNC_REG` синхронизаторов; internal — одиночная команда или периодический импульс.
2. Маска `trigger_enable`: bit0 alg, bit1 ext, bit2 internal.
3. События и принятие — комбинационные same-cycle. `trigger_accept` только при `accept_enable && count_enable`, не на START; FSM снимает accept_enable при STOP/fatal.
4. Совпадающие источники: приоритет metadata **external > algorithmic > internal**. Алгоритмические данные в заголовок только при выбранном algorithmic source; иначе 0.
5. Счётчики: accepted += 1 при успешном принятии, missed += (`event_count - accept`) на активном участке счёта; до 3 пропущенных за один такт; во время inactive считать не нужно.
6. `run_start` обнуляет фазу периодического генератора. Первый periodic tick на N-м активном такте при периоде N>=1. Нулевой период при разрешённом periodic отвергает startup guard.
7. Защёлкнутые timestamp/trigger_data/source меняются только при принятии и сохраняются до следующего принятия/reset; `clear_stats` не стирает metadata.

## [CURRENT] Патч №4

Два счётчика 48 бит modulo `2^48`, реализованные **3×16-битными секциями** и выдаваемые в регистровую карту как нулерасширенные 64 бита; принятие до одного и пропуски 0–3 за такт. Это реализация, не исходное требование. Патч №3 с заменой сравнения периода был отозван из-за ухудшения Timing.

## Проверки

Экстремальные period=1/2/максимальное, совпадения 2/3 sources, внешняя синхронизация, STOP+trigger, timestamp latch, статусы accepted/missed в disabled states, `clear_stats`; перенос через 16/32 бита, wrap на 48 бит и `missed += 2/3`.

## Открытые решения

**[OPTION]** Сократить статистику ещё сильнее либо считать события с объединением совпадений, но это изменит наблюдаемую семантику. Отдельно решить, нужна ли 64-битная **программная** карта readback.
