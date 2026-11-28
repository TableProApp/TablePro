-- When a pass last ended without an error. Outside the MAC: it decides nothing a pass sends or applies.
CREATE TABLE last_synced (id INTEGER PRIMARY KEY CHECK (id = 0), at_ms INTEGER NOT NULL);
