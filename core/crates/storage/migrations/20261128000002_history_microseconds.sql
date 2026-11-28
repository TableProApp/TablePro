-- A run's times in microseconds: whole milliseconds read a run under one millisecond as no time at all, on this device
-- and on every device the `history_entry` wire schema (tablepro-records) carries it to.
ALTER TABLE history RENAME COLUMN duration_ms TO duration_us;
ALTER TABLE history RENAME COLUMN first_row_ms TO first_row_us;
ALTER TABLE history RENAME COLUMN server_ms TO server_us;
-- Only the unit changes, so the store's write sequence (store_identity) stays where it was: a store that read as
-- written to would be taken for newer than the copy sync last saw.
CREATE TEMP TABLE history_sequence AS SELECT sequence FROM store_identity;
UPDATE history
SET duration_us = duration_us * 1000, first_row_us = first_row_us * 1000, server_us = server_us * 1000
WHERE duration_us IS NOT NULL OR first_row_us IS NOT NULL OR server_us IS NOT NULL;
UPDATE store_identity SET sequence = (SELECT sequence FROM history_sequence);
DROP TABLE history_sequence;
