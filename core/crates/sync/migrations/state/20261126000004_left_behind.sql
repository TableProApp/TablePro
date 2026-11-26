-- The settings records Start empty left on the device, with the digest of the copy each held then.
CREATE TABLE left_behind (key BLOB PRIMARY KEY NOT NULL, columns BLOB NOT NULL) WITHOUT ROWID;
