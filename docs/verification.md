# План верификации и приёмки

## 1. Среда

Vivado 2023.1 и XSIM в Docker (Ubuntu 22.04), Git и скрипты на хосте Ubuntu 25. Целевая частота 200 МГц, `clk` period = 5,000 нс. **Важно:** в GUI и скриптах использовать **одни и те же исходники в Git**, а не импортированные копии `*.srcs/imports`.

## 2. Регрессионные тестбенчи

| Тестбенч | Главное требование |
|---|---|
| `tb_frame_input_ctrl` | 96 слов, TLAST, sync, STOP, no backpressure, malformed frame |
| `tb_capture_fifo_ctrl` | PRE sliding window, drop/transfer, логический предел, flush, XPM и поведенческий режим |
| `tb_trigger_ctrl` | три источника, приоритет, задержка ext sync, timestamp, missed/accepted, переносы/overflow патча №4 |
| `tb_burst_packer` | 128-byte preamble, 16 beats/burst, шесть bursts/frame, полный кадр, STOP target |
| `tb_axi3_write_master` | AW/W/B и backpressure, 4 outstanding, ошибки BRESP, адреса |
| `tb_mem_range_guard` | все значения N, полный размер, 4 GiB boundary, 128 alignment, snapshot, задержанный `check_done` |
| `tb_axi_lite_regs` | доступы к карте, WSTRB, команды, SHADOW/ACTIVE, sticky flags, coherent 64-bit reads |
| `tb_capture_main_fsm` | состояния, STOP, ошибочное завершение, приоритеты и AXI drain |
| `tb_camera_capture_top` | end-to-end AXI-Lite → FIFO → trigger → preamble → AXI3 DDR |
| `tb_camera_capture_stress` | несколько фрагментов, STOP, долгий поток 1000 кадров при 307,2 МБ/с |
| `tb_camera_capture_faults` | SLVERR/DECERR, FIFO overflow, восстановление |

**Сообщение пользователя после патча №4:** `ALL REGRESSION TESTBENCHES PASSED`. Числа локальных проверок, полученные на прежних вариантах RTL, не следует переносить на новую ревизию без повторного лога.

## 3. Обязательные corner cases при упрощениях

- Одновременные STOP, `TLAST`, trigger и error; приоритет и количество полных кадров.
- Повторный START после CLEAR_ERROR, особенно если прошлый AXI slave отвечал с задержкой.
- Trigger при нулевой предыстории, максимальной предыстории, на первом слове и последнем слове кадра.
- Межкадровые паузы и произвольная пауза `TVALID` внутри допустимого протокола.
- Программирование максимально большого размера фрагмента, множества фрагментов, границы `2^32` и размеров буфера «ровно хватает / на 1 байт мало».
- FIFO logical full одновременно с чтением; смещение drop-позиции при совпадении trigger с drop TLAST.
- Медленный `AWREADY`, `WREADY`, `BVALID`, некорректные B responses; **не объявлять успех на одном WLAST**.
- Счётчики статистики при переносах 16/32/48 бит и переполнении; `missed += 1/2/3`.

## 4. Git / Docker цикл

```bash
# На Ubuntu-хосте
cd ~/xil_proj/Lovozero_vitis/ip_repo/CameraDataCaptureIP
git status
git diff --check

# В контейнере, из того же общего каталога
bash scripts/run_regression.sh
bash scripts/run_vivado.sh synth
```

Перед экспериментом сохранить Git commit hash (`git rev-parse HEAD`), изменения незакоммиченного патча (`git diff > build/...patch`) и копию `timing_summary.rpt`. Скриптовый exit code + наличие PASS не заменяют проверку, что актуальные RTL используются проектом.

## 5. Timing acceptance

1. Clock constraint 200 МГц загружен (`get_clocks`).
2. Результат `synth` нужен для предварительной аналитики.
3. Итог — `Implementation`, post-route: Setup WNS≥0, Hold WHS≥0, нет других relevant Timing violations.
4. Проверен реальный путь через PS HP, clocking/reset и ограничения I/O; проверена конфигурация PS HP port.
5. Измерена производительность на реальной DDR/PS под реальными задержками; стресс XSIM не доказывает пропускную способность реального HP.
