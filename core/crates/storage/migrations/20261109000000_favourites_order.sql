WITH positions AS (
    SELECT id, ROW_NUMBER() OVER (
        PARTITION BY connection_id, folder_id
        ORDER BY sort_order, name COLLATE NOCASE, id
    ) - 1 AS position
    FROM saved_queries
)
UPDATE saved_queries SET sort_order = positions.position
FROM positions WHERE saved_queries.id = positions.id;

WITH positions AS (
    SELECT id, ROW_NUMBER() OVER (
        PARTITION BY connection_id, parent_id
        ORDER BY sort_order, name COLLATE NOCASE, id
    ) - 1 AS position
    FROM saved_query_folders
)
UPDATE saved_query_folders SET sort_order = positions.position
FROM positions WHERE saved_query_folders.id = positions.id;

CREATE INDEX saved_queries_folder_order_idx ON saved_queries (connection_id, folder_id, sort_order, id);
CREATE INDEX saved_query_folders_parent_idx ON saved_query_folders (parent_id);
CREATE INDEX saved_query_folders_order_idx ON saved_query_folders (connection_id, parent_id, sort_order, id);
