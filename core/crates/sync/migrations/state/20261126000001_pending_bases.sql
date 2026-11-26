-- 0064: the bases a pull will apply, written before the store, in the same encoding as `bases`.
CREATE TABLE pending_bases (key BLOB PRIMARY KEY NOT NULL, columns BLOB NOT NULL) WITHOUT ROWID;
