CREATE TABLE favorite_query (id INTEGER PRIMARY KEY, title TEXT, text TEXT, database TEXT, connectionHash TEXT);
INSERT INTO favorite_query (id, title, text) VALUES (1, 'Orders', 'select * from orders;');
