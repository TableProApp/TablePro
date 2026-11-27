-- What the app knew of a run beyond its outcome, for the History pane and the `history_entry` wire schema
-- (tablepro-records): the database and schema it ran in, what started it, the statement's type, the times to the
-- first row and on the server in milliseconds, and the fingerprint the app read the statement's shape as, which never
-- leaves the device. NULL where the app did not say, as for every entry an older build recorded.
ALTER TABLE history ADD COLUMN database TEXT;
ALTER TABLE history ADD COLUMN schema TEXT;
ALTER TABLE history ADD COLUMN source TEXT;
ALTER TABLE history ADD COLUMN statement_type TEXT;
ALTER TABLE history ADD COLUMN first_row_ms INTEGER;
ALTER TABLE history ADD COLUMN server_ms INTEGER;
ALTER TABLE history ADD COLUMN fingerprint INTEGER;
