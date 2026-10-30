# ТЗ модуля `capture_fifo.sv`

**Роль:** физическое хранилище FIFO с FWFT интерфейсом; **не** понимает кадры и `n_prev_frames`.

## Параметры и интерфейс

- Параметры `WIDTH=65`, `PHYSICAL_DEPTH=16384`, `USE_XPM=1` для производства / `0` для поведенческой модели.
- Входы: `clk`, `rst`, `flush`, `write_data[WIDTH-1:0]`, `write_en`, `read_en`.
- Выходы: `can_write`, `read_data`, `read_valid`, `ready`.

## Контракт

1. Один общий домен clock, одновременные операции чтения/записи разрешены по фактическому состоянию FIFO.
2. FWFT: при `read_valid` текущее головное слово видно на `read_data` без дополнительного read-request latency; `read_en` подтверждает извлечение.
3. `can_write` обязателен перед write, `read_valid` обязателен перед read.
4. Во время `flush/reset` и `*_rst_busy` не принимать операции; `ready` показывает готовность после сброса.
5. Не меняет порядок слов/значение TLAST; не выполняет drop.

## Текущая реализация

- FPGA: Xilinx `xpm_fifo_sync`, `FIFO_MEMORY_TYPE="block"`, `READ_MODE="fwft"`, `FIFO_READ_LATENCY=0`.
- Simulation: поведенческая массивная очередь с моделированием нескольких тактов reset busy.
- Физическая глубина 16384, логический лимит **9600** реализован в **другом** модуле `capture_fifo_ctrl`.

## Верификация

Сохранение порядка, FWFT, simultaneous read/write, flush, full/empty, запрет записи во время busy, совпадение поведения `USE_XPM=0/1`.

## Упрощение

**[OPTION]** Пересмотреть глубину или реализацию BRAM при уточнении требуемого DDR stall budget. Удалять поведенческую модель не стоит — она не добавляет ресурсов в FPGA при `USE_XPM=1`.
