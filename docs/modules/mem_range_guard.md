# ТЗ модуля `mem_range_guard.sv`

**Роль:** проверить ВСЮ конфигурацию запуска до разрешения сбора/DDR, без выполнения AXI транзакций. Не заменяет per-burst защиту writer.

## Интерфейс

- Запрос `check_req` (однотактный из IDLE), `n_frames[31:0]`, `n_prev_frames[31:0]`, `n_fragments[31:0]`, `mem_addr[31:0]`, `mem_buffer_bytes[31:0]`, `periodic_enable`, `int_trig_period[31:0]`.
- Ответ `check_done` (pulse), `check_ok`, `check_error_flags[31:0]`, `fragment_bytes[31:0]`, `total_required_bytes[63:0]`, `buffer_end_exclusive[63:0]`.

## Условия успеха

```
2 <= n_frames <= 131072
0 <= n_prev_frames <= 64
n_prev_frames < n_frames
n_fragments >= 1
mem_addr % 128 == 0
mem_buffer_bytes > 0
fragment_bytes = 128 + 768*n_frames
required_bytes = fragment_bytes * n_fragments
required_bytes <= mem_buffer_bytes
mem_addr + mem_buffer_bytes <= 2^32
!periodic_enable || (int_trig_period > 0)
```

64-битная арифметика и проверка допустимости `n_frames` должны предотвращать wrap, превращающий недопустимую конфигурацию в кажущийся малым размер. Значение **ровно `2^32`** допустимо только как `buffer_end_exclusive`, не как адрес записи.

## Текущая реализация после оптимизации v1.1

Многотактовый конвейер: snapshot всех входных полей на `check_req` → вычисление размера фрагмента → частичные произведения → cross terms → полный объём → атомарная публикация результата с `check_done`. FSM обязан ждать `check_done` и не использовать устаревший `check_ok`. SHADOW нельзя менять на протяжении проверки (блокировка в AXI-Lite).

## Ошибки

`ERROR_FLAGS[4]` неверные frames; `[5]` неверные prev; `[6]` нулевые fragments; `[7]` неправильное выравнивание; `[9]` нулевой/малый буфер; `[10]` выход за 4 GiB; `[11]` нулевой период включённого internal periodic.

## Верификация

Граничные значения всех параметров, max×max произведение, точно достаточный буфер, нехватка 1 байта, region_end 4GiB, snapshot после изменения внешних входов, многотактовое ожидание, удержание статуса до следующего запроса.

## Возможность сокращения

**[OPTION]** Изменить разрядности под допустимый software protocol, но не возвращать огромный комбинаторный путь размер×количество×сравнение: он ранее ломал 200 МГц.
