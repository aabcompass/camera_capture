# ТЗ модуля `axi_lite_regs.sv`

**Роль:** 32-битный AXI4-Lite slave, команда/конфигурация ядра, статусы, sticky ошибки, чтение 64-битной статистики. Не выполняет саму валидацию DDR и не управляет FIFO напрямую.

## Интерфейсы

- Slave AXI4-Lite: AWADDR/AWPROT/AWVALID/AWREADY, WDATA/WSTRB/WVALID/WREADY, BRESP/BVALID/BREADY, ARADDR/ARPROT/ARVALID/ARREADY, RDATA/RRESP/RVALID/RREADY.
- Команды: `cmd_start`, `cmd_stop`, `cmd_clear_error`, `cmd_clear_stats`, `int_single_pulse` — однотактные импульсы.
- Разрешения: `allow_start`, `allow_clear_error`, `allow_clear_stats`, `cfg_write_lock`, `run_start_pulse`.
- SHADOW поля: `cfg_*`, ACTIVE поля: `active_*`, статусы FSM и тракта данных.

## Основной контракт

1. Раздельно захватывать AW и W, поддерживать произвольный порядок их handshake. Удерживать B/R до READY; уважать `WSTRB` на каждой конфигурационной записи.
2. Команды выдавать **один раз на одну принятую запись**. Запрещать несовместимые комбинации команд, неверные биты, запись RO и неизвестные адреса корректными AXI BRESP.
3. В момент успешного START (`run_start_pulse`) атомарно фиксировать все SHADOW значения в ACTIVE, даже если ПО ранее подготовило будущую конфигурацию в процессе текущего run.
4. На период `cfg_write_lock` блокировать изменения SHADOW, чтобы избежать изменения между startup validation и ACTIVE snapshot (TOCTOU).
5. `error_flags` sticky, аппаратное установление имеет приоритет над CLEAR_ERROR в тот же такт.
6. Чтение 64-битных accepted/missed: сначала LO, оно запоминает HI; отдельный HI read возвращает захваченное значение, а не «рваную» пару.

## Карта регистров

Полная карта, доступы, биты и исключения — **[../register_map.md](../register_map.md)**. Адреса до `0x0B4`; `0x04C` **не отображён** в текущем RTL. Версия `IP_VERSION_VALUE=0x00010000` по умолчанию.

## Проверки

AW/W в разном порядке, одиночный и пакетный R, stalls, write byte strobes, invalid addresses, invalid commands, read only, разрешения FSM, snapshots и два последовательных запуска, статистика на границе 32 бит, reserved read.

## Обсуждение упрощения

**[OPTION]** Сократить список STATUS/LAST_* регистров и убрать SHADOW/ACTIVE только после определения потребностей программного обеспечения PS и версионирования ABI; снижение ресурсов может оказаться небольшим относительно выигрыша в удобстве.
