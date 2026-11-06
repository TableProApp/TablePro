PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE parent (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  mood TEXT CHECK (mood IN ('sad', 'ok', 'happy'))
);
INSERT INTO parent VALUES(1,'a','ok');
INSERT INTO parent VALUES(2,'b','sad');
INSERT INTO parent VALUES(3,'c','happy');
CREATE TABLE child (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id INTEGER NOT NULL REFERENCES parent(id) ON DELETE CASCADE,
  manager_id INTEGER REFERENCES child(id),
  note TEXT,
  payload BLOB
);
INSERT INTO child VALUES(1,1,3,'it''s; a "quote" \ back;',X'00ff27');
INSERT INTO child VALUES(2,1,NULL,replace('line1\nline2;','\n',char(10)),NULL);
INSERT INTO child VALUES(3,2,1,'ünïcødé ;; END;;',NULL);
INSERT INTO child VALUES(4,3,NULL,';',NULL);
CREATE TABLE plain_rowid (k TEXT, v REAL);
INSERT INTO plain_rowid VALUES('x',1.5);
INSERT INTO plain_rowid VALUES('y',NULL);
DELETE FROM sqlite_sequence;
INSERT INTO sqlite_sequence VALUES('parent',5);
INSERT INTO sqlite_sequence VALUES('child',5);
CREATE VIEW v1 AS SELECT p.id, p.name, count(c.id) AS n FROM parent p LEFT JOIN child c ON c.parent_id = p.id GROUP BY p.id, p.name;
CREATE VIEW v2 AS SELECT * FROM v1 WHERE n > 0;
CREATE TRIGGER child_touch BEFORE INSERT ON child BEGIN SELECT 1; END;
CREATE TRIGGER child_touch_after AFTER INSERT ON child BEGIN UPDATE child SET note = coalesce(note, '') || ';' WHERE id = NEW.id; END;
CREATE INDEX child_parent_idx ON child (parent_id);
COMMIT;
