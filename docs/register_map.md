# AXI4-Lite: карта регистров и программный контракт

**Адреса:** смещения относительно base address IP. Все доступы по 32 бита, выравнивание 4 байта. **Режим:** AXI4-Lite, самостоятельное принятие AW и W, `WSTRB[3:0]`; регистры SHADOW доступны для чтения; ACTIVE — внутренний снимок при разрешённом START. Неизвестные адреса: `DECERR`; запись в RO/недопустимая команда: `SLVERR`.

| Offset | Имя | Доступ | Значение |
|---|---|---|---|
| `0x000` | COMMAND | WO (RO=0) | bit0 START, bit1 STOP, bit2 CLEAR_ERROR, bit3 CLEAR_STATS; команды одиночные, одновременно несколько команд не допускается |
| `0x004` | STATUS | RO | state[3:0], busy[4], stop_pending[5], trigger_latched[6], capture_complete[7], axi_busy[8], fifo_empty[9], fifo_full[10], config_error[11], runtime_error[12] |
| `0x008` | ERROR_FLAGS | RO sticky | ошибки, см. ниже |
| `0x00C` | TRIGGER_ENABLE | RW | bit0 algorithmic, bit1 external, bit2 internal |
| `0x010` | N_FRAMES | RW | 2…131072 |
| `0x014` | N_PREV_FRAMES | RW | 0…64, строго меньше N_FRAMES |
| `0x018` | N_FRAGMENTS | RW | ≥1; размер пробега обязан помещаться в буфер DDR |
| `0x01C` | MEM_ADDR | RW | первый адрес DDR, выровнен по 128 |
| `0x020` | HEADER_ID | RW | 32-битный идентификатор заголовка |
| `0x024`…`0x040` | AUX_0…AUX_7 | RW | восемь последовательных 32-битных слов, всего 256 бит |
| `0x044` | INT_TRIG_PERIOD | RW | период в тактах `clk`, >0 когда периодический режим разрешён |
| `0x048` | INT_TRIG_CTRL | RW/command | bit0 одиночный импульс (команда), bit1 periodic_enable (состояние) |
| `0x04C` | RESERVED | **не отображён** | в RTL нет адреса 0x04C; доступ выдаёт `DECERR` |
| `0x050` | LAST_ERROR_CODE | RO | последняя ошибка/код (событийное поле статистики) |
| `0x054` | LAST_ERROR_ADDR | RO | адрес последней ошибки AXI |
| `0x058` | FIFO_LEVEL | RO | число 65-битных слов в логическом FIFO |
| `0x05C` | FRAMES_CAPTURED | RO | число кадров, принятых по данным камеры в текущем фрагменте |
| `0x060` | FRAMES_SENT | RO | полные кадры, все W beats которых приняты AXI W каналом |
| `0x064` | FRAMES_COMMITTED | RO | полные кадры, подтверждённые успешными BRESP |
| `0x068` | FRAGMENTS_COMPLETED_TOTAL | RO | накопительное число завершённых фрагментов |
| `0x06C` | TRIGGERS_ACCEPTED_LO | RO | младшие 32 бита accepted; чтение фиксирует HI-снимок |
| `0x070` | TRIGGERS_MISSED_LO | RO | младшие 32 бита missed; чтение фиксирует HI-снимок |
| `0x074` | FIFO_OVERFLOW_COUNT | RO | число отвергнутых FIFO-записей (слов), не эпизодов |
| `0x078` | AXI_ERROR_COUNT | RO | число эпизодов ошибок writer |
| `0x07C` | CURRENT_WRITE_ADDR | RO | текущий адрес writer (младшие 32 бита) |
| `0x080` | LAST_TIMESTAMP_LO | RO | последние принятые триггерные метаданные |
| `0x084` | LAST_TIMESTAMP_HI | RO | старшие 32 бита timestamp |
| `0x088` | LAST_TRIGGER_DATA_LO | RO | последние данные триггера |
| `0x08C` | LAST_TRIGGER_DATA_HI | RO | старшие 32 бита trigger data |
| `0x090` | LAST_TRIGGER_SOURCE | RO | 0 none / 1 alg / 2 ext / 3 internal |
| `0x094` | LAST_FRAGMENT_ADDR | RO | начальный адрес последнего завершённого/прерванного фрагмента |
| `0x098` | LAST_FRAGMENT_FRAMES | RO | реально подтверждённые кадры |
| `0x09C` | LAST_FRAGMENT_SIZE | RO | 128 + 768×committed frames после успеха, 0 при аварии |
| `0x0A0` | LAST_FRAGMENT_STATUS | RO | 1 COMPLETE, 2 STOPPED/PARTIAL, 3 ERROR; 0 после reset |
| `0x0A4` | RUN_FRAGMENTS_COMPLETED | RO | успешно завершённые фрагменты текущего запуска |
| `0x0A8` | TRIGGERS_ACCEPTED_HI | RO | снимок старшей части, ранее захваченный чтением LO |
| `0x0AC` | TRIGGERS_MISSED_HI | RO | аналогично missed |
| `0x0B0` | IP_VERSION | RO | текущий параметр по умолчанию `0x00010000` |
| `0x0B4` | MEM_BUFFER_BYTES | RW | размер DDR-области в байтах |

### ERROR_FLAGS

| Бит | Смысл |
|---:|---|
| 0 | Переполнение FIFO / отклонённая запись камеры |
| 1 | Ошибка AXI BRESP, отличная от DECERR (в частности SLVERR) |
| 2 | AXI BRESP DECERR |
| 3 | Ошибка формата кадра (TLAST) / ошибка формата packer |
| 4 | Недопустимое N_FRAMES |
| 5 | Недопустимое N_PREV_FRAMES |
| 6 | N_FRAGMENTS = 0 |
| 7 | MEM_ADDR не кратен 128 |
| 8 | Зарезервирован в рассматриваемой реализации |
| 9 | MEM_BUFFER_BYTES=0 либо run не помещается в него |
| 10 | Ошибка адресного диапазона (переполнение или выход burst за границу) |
| 11 | Включён периодический триггер с периодом 0 |
| 12 | AXI-протокольная ошибка writer |
| 13 | Неверный STOP target от packer |
| 14…31 | В рассматриваемой реализации не назначены |

**Сведения:** биты 4–11 ставятся startup guard; 0–3, 10, 12, 13 — datapath/top. Hardware set имеет приоритет над software clear. Биты статусной агрегированной ошибки в `STATUS` — **производные** от ERROR_FLAGS, не самостоятельные latch.

### Ограничения на команды

- START разрешён только в IDLE, когда нет неснятых ошибок и нет активной проверки конфигурации.
- STOP допустим как команда завершения/выхода из END_STATE; обработка зависит от текущего состояния FSM.
- CLEAR_ERROR разрешён в безопасном IDLE либо в ERROR после завершения очистки.
- CLEAR_STATS разрешён в IDLE либо END_STATE.
- Во время многотактовой START-validation записи в SHADOW конфигурации возвращают SLVERR.
- 64-битные статистические значения читаются парами **сначала LO, затем HI**. После патча №4 физический счётчик 48 бит, его 64-битный readback дополнен нулями до 64 бит.

### Вопросы, требующие решения

1. Нужна ли вся текущая карта диагностики и все LAST_* регистры?
2. Нужно ли сохранять 64-битный программный ABI для статистики при внутреннем 48-битном счётчике?
3. Что должно означать «ошибка переполнения»: число отклонённых слов или число эпизодов?
4. Должна ли конфигурация быть доступна к изменению во время захвата (SHADOW/ACTIVE) или проще разрешать запись только в IDLE?
