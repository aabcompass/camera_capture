# ТЗ модуля `axi3_write_master.sv`

**Роль:** защищённая передача 128-байтных burst в PS `S_AXI_HP` (AXI3 64-bit), учёт outstanding AW и подтверждение целых кадров только по BRESP.

## Интерфейс

- Control: `start`, `halt_new` (**fatal only**), `start_addr[31:0]`, `mem_base_addr[31:0]`, `mem_buffer_bytes[31:0]`, `packer_done`.
- Packer: `burst_valid/ready`, `burst_is_preamble`, `burst_ends_frame`, `burst_word_count_minus_one`, `p_wdata[63:0]`, `p_wvalid`, `p_wready`, `p_wlast`.
- AXI3 master: AW (`AWID[5:0]`, `AWADDR[31:0]`, `AWLEN[3:0]`, `AWSIZE[2:0]`, `AWBURST`, `AWLOCK`, `AWCACHE`, `AWPROT`, `AWVALID/READY`), W (`WID[5:0]`, `WDATA[63:0]`, `WSTRB[7:0]`, `WLAST`, `WVALID/READY`), B (`BID[5:0]`, `BRESP`, `BVALID/READY`).
- Status: `active`, `drain_done`, `writer_done`, `range_error`, `bresp_error`, `protocol_error`, `last_error_addr`, `last_bresp`, `outstanding[2:0]`, `bursts_issued/w_sent/committed`, `frames_committed[17:0]`, `preamble_committed`, `current_write_addr[31:0]`.

## Контракт

1. Фиксированные **16 beats**, `AWLEN=15`, `AWSIZE=3`, INCR, `WSTRB=0xFF`; адрес каждого burst кратен 128.
2. Не принимать descriptor при отсутствии свободного budget outstanding, ошибке или нарушении границ памяти. Writer самостоятельно проверяет каждый burst `[next_addr,next_addr+128)` на принадлежность `[mem_base,mem_base+mem_buffer_bytes)` и отсутствие перехода за 4 GiB.
3. AW и W — независимые handshake: W может быть принят до AW; уже выставленный AWVALID/WVALID удерживается до READY даже при появлении STOP/fatal.
4. `MAX_OUTSTANDING=4` — максимум **AW, ожидающих B**. В текущем RTL только **один descriptor одновременно находится на стадиях AW/W**, что следует отличать от четырёх параллельных потоков данных.
5. `BID` сейчас константный 0, BRESP сопоставляются по порядку AW. Ошибка `SLVERR/DECERR` фиксируется; `frames_committed` увеличивается только по `OKAY` BRESP, помеченному окончанием кадра.
6. `halt_new` не отменяет принятый descriptor; завершить (drain) уже выданные AW/W/B. `writer_done` требует packer_done, no pending transactions, no fault и подтверждённую преамбулу.
7. Обычный STOP не использует `halt_new`: пока packer отдаёт полные кадры, writer должен дописать их и дождаться BRESP.

## Текущая реализация

Внутренняя `next_addr`/границы — 64 бит для точной проверки интервала и границы 4 GiB; `next_addr += 128`. Кольцевая очередь metadata для максимум 4 BRESP, `AWID/WID=0`.

## Проверки

Stalls на AW/W/B, BRESP tail error, неправильный BID, WLAST protocol error, диапазон ровно до 4 GiB, overflow одного burst, 4 outstanding, `halt_new` во время AW/W/B.

## Открытые вопросы / Timing

**[CURRENT]** После патча №4 худший **положительный** Setup-путь идёт через `next_addr` → range guard → packer reset/enable. **[OPTION]** Снизить ширину адресной арифметики или зарегистрировать разрешение burst, сохранив защиту 4 GiB. Пока не менять без Place & Route: WNS уже положительный.
