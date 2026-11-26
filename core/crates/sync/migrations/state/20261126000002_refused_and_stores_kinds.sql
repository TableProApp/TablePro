-- 0066: the changes the server refused, and the refills each kind of a store still owes, in the same encoding.
CREATE TABLE stores_kinds (key BLOB PRIMARY KEY NOT NULL, columns BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE refused (key BLOB PRIMARY KEY NOT NULL, columns BLOB NOT NULL) WITHOUT ROWID;
