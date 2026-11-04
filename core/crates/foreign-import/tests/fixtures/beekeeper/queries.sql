CREATE TABLE query_folder (id INTEGER PRIMARY KEY, name TEXT, parentId INTEGER);
CREATE TABLE favorite_query (
    id INTEGER PRIMARY KEY, title TEXT, text TEXT, database TEXT, connectionHash TEXT, queryFolderId INTEGER
);
INSERT INTO query_folder (id, name, parentId) VALUES (1, 'Reports', NULL), (2, 'Daily', 1);
INSERT INTO favorite_query (id, title, text, queryFolderId) VALUES
    (1, 'Demo Query', 'select 1;', NULL),
    (2, 'Top customers', 'select * from customers where region = ${region};', NULL),
    (3, 'Daily active users', 'select count(*) from sessions;', 2),
    (4, 'Blank', '   ', NULL),
    (5, 'Huge', replace(hex(zeroblob(900001)), '00', 'x'), 1);
