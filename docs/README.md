# Camera Data Capture IP — комплект ТЗ и аудит архитектуры

**Цель:** зафиксировать требования к ядру захвата научных данных для Xilinx XC7Z035 и к каждому из 11 RTL-модулей, чтобы отделить обязательные свойства от решений реализации и выявить потенциальную избыточность.

**Дата среза:** 2026-10-30. **Статус:** рабочий проект, все предоставленные пользователем регрессионные симуляции после патча №4 прошли; RTL патча №4 пока не закоммичен. Это **документы для обсуждения**, а не изменение RTL.

## Состав

| Файл | Что внутри |
|---|---|
| [core_spec.md](core_spec.md) | ТЗ на всё ядро: интерфейсы, ограничения, поведение, формат памяти, отказоустойчивость |
| [architecture_review.md](architecture_review.md) | Разделение обязательного/настраиваемого; кандидаты на упрощение и риски |
| [register_map.md](register_map.md) | Карта AXI4-Lite, команды, состояния, ошибки, семантика регистров |
| [verification.md](verification.md) | Требуемые тесты, текущие результаты и порядок проверки изменений |
| [timing_snapshot.md](timing_snapshot.md) | Сравнение Timing и ограничения интерпретации синтеза |
| [original_user_spec.md](original_user_spec.md) | Первоначальное русское ТЗ из комментария top RTL, без смыслового редактирования |
| [modules/camera_capture_top.md](modules/camera_capture_top.md) | Интеграция интерфейсов и требований всего ядра |
| [modules/frame_input_ctrl.md](modules/frame_input_ctrl.md) | Приём 96-словных кадров, TLAST и STOP |
| [modules/capture_fifo.md](modules/capture_fifo.md) | Хранилище FWFT/XPM |
| [modules/capture_fifo_ctrl.md](modules/capture_fifo_ctrl.md) | Sliding PRE и transfer логика |
| [modules/trigger_ctrl.md](modules/trigger_ctrl.md) | Триггеры и статистика |
| [modules/burst_packer.md](modules/burst_packer.md) | Преамбула, кадры и пакетирование |
| [modules/axi3_write_master.md](modules/axi3_write_master.md) | AXI3 burst, адреса, BRESP |
| [modules/mem_range_guard.md](modules/mem_range_guard.md) | Проверка START и памяти |
| [modules/axi_lite_regs.md](modules/axi_lite_regs.md) | Конфигурация и MMIO |
| [modules/capture_main_fsm.md](modules/capture_main_fsm.md) | FSM, STOP, ERROR, END |
| [modules/capture_statistics.md](modules/capture_statistics.md) | Счётчики и диагностика |

## Статус формулировок

- **[REQ]** — согласованное поведение ядра либо прямо отражённое в исходном ТЗ.
- **[CURRENT]** — инженерное решение и/или поведение по доступному RTL и ранее проверенной сборке; можно изменить после согласования.
- **[OPTION]** — вариант для обсуждения, **не** обязательное требование.
- **[VERIFY]** — требуется дополнительная проверка на текущем RTL, интеграции в Zynq PS или в условиях, не покрытых имеющимися тестами.

Описание построено по оригинальному ТЗ в `camera_capture_top.sv`, исходникам архивной интеграционной сборки v0.3, известным последующим исправлениям `mem_range_guard` v1.1, Main FSM (патчи №1/№2), `trigger_ctrl` (патч №4), результатам XSIM и двум последним отчётам синтеза. Текущий Git-репозиторий пользователя не подключён к этой сессии; **документация не подменяет ревизию исходников по текущему commit hash**.

Для использования в Git скопируйте каталог целиком, например в `docs/spec/`.
