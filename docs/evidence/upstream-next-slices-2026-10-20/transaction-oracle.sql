\echo CASE_1_ABORTED_COMMIT
CREATE TABLE outcome_probe (id integer PRIMARY KEY);
BEGIN;
INSERT INTO outcome_probe VALUES (1);
SELECT 1 / 0;
COMMIT;
SELECT count(*) = 0 AS aborted_commit_kept_no_rows FROM outcome_probe;
\echo CASE_2_SAVEPOINT_RECOVERY
BEGIN;
INSERT INTO outcome_probe VALUES (2);
SAVEPOINT recover;
SELECT 1 / 0;
ROLLBACK TO SAVEPOINT recover;
INSERT INTO outcome_probe VALUES (3);
COMMIT;
SELECT array_agg(id ORDER BY id) AS rows_committed_after_recovery FROM outcome_probe;
