-- Saved queries, their folders, favourites and table folders live in `saved_queries.db` from here on, a store of their
-- own (core ADR 0060 as amended), so the history can keep a stronger protection class than what sync reads in the
-- background. `QueryHistory::open` copies their rows there before this runs, under the write lock this runs in. A
-- dropped table takes its indexes and triggers, and no delete trigger fires, so the history's sequence stays.
DROP TABLE saved_queries;
DROP TABLE saved_query_folders;
DROP TABLE favourite_tables;
DROP TABLE favourite_databases;
DROP TABLE table_folders;
DROP TABLE table_folder_items;
DELETE FROM sqlite_sequence WHERE name IN ('saved_queries', 'saved_query_folders');
