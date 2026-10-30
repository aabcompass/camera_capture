# ТЗ модуля `burst_packer.sv`

**Роль:** формировать DDR-поток как преамбулу 128 байт и последовательность полных 768-байтных кадров, разбитую на 128-байтные AXI burst. Модуль не занимается AXI-адресами/BRESP.

## Интерфейс

- Управление: `start`, `abort`, `n_frames[17:0]`, `stop_target_valid`, `stop_target_frames[17:0]`.
- Поля преамбулы: `header_id[31:0]`, `fragment_index[31:0]`, `timestamp[63:0]`, `trigger_data[63:0]`, `aux_data[255:0]`.
- Источник FIFO (FWFT): `in_data[64:0]={TLAST,DATA}`, `in_valid`, `in_ready`.
- Выход descriptor: `burst_valid/ready`, `burst_is_preamble`, `burst_ends_frame`, `burst_word_count_minus_one` (**всегда 15**).
- Выход данных: `w_data[63:0]`, `w_valid`, `w_ready`, `w_last`.
- Диагностика: `active`, `packer_done`, `format_error`, `target_error`, `frames_packed[17:0]`, `frames_sent[17:0]`, `bursts_sent[31:0]`.

## Контракт

1. Каждый burst **ровно 16 слов × 64 бита**, WLAST только на последнем слове. Дескриптор burst принимается writer **до** передачи его W-слов.
2. Структура: burst #0 — 128-байтная преамбула; далее **ровно 6 bursts на каждый 96-словный кадр**.
3. Преамбула: `word0={fragment_index,header_id}`, word1 timestamp, word2 trigger data, words3–6 AUX (по 64 бита), words7–15 повторяют `0x1234567812345678`.
4. Уровни VALID и WDATA сохраняются при отсутствии READY; слово FIFO читается только при реальном handshake и наличии свободного банка.
5. По TLAST контролировать, что кадр завершается именно на 96-м слове; нарушение — `format_error`.
6. `stop_target_valid` уменьшает целевой объём **после определения границы STOP** и только в пределах `[frames_packed, initial n_frames]`; целое число полных кадров, никаких частичных burst/кадров.
7. `frames_sent` считается по W handshake полного кадра, **не** по BRESP. `packer_done` не означает успешную фиксацию в DDR.

## Текущая реализация

Два локальных банка по `16×64` бит, логика fill/send и метаданные burst. Формат константен — никакого variable burst length.

## Проверки

Побайтовое сравнение header + frame data, FAST/STALL, два банка одновременно (one fill, one send), TLAST ошибок, STOP target, запрет дальнейшего извлечения FIFO, неизменность WDATA при stall.

## Варианты

**[OPTION]** Одна burst-банка может сэкономить регистры, но снизит способность поглощать паузы AXI. Количество банков следует выбирать по требованию к throughput, а не только по FF.
