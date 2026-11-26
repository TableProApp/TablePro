-- A move between providers this device started, its target and how far it went, so a restart resumes it.
CREATE TABLE moves (key BLOB PRIMARY KEY NOT NULL, columns BLOB NOT NULL) WITHOUT ROWID;
