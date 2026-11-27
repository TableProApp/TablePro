-- A run's times in microseconds: whole milliseconds read a run under one millisecond as no time at all, on this device
-- and on every device the `history_entry` wire schema (tablepro-records) carries it to.
ALTER TABLE history RENAME COLUMN duration_ms TO duration_us;
ALTER TABLE history RENAME COLUMN first_row_ms TO first_row_us;
ALTER TABLE history RENAME COLUMN server_ms TO server_us;
UPDATE history
SET duration_us = duration_us * 1000, first_row_us = first_row_us * 1000, server_us = server_us * 1000;
