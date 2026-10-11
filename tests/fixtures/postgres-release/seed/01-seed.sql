CREATE TABLE release_items (
    id integer PRIMARY KEY,
    name text NOT NULL,
    amount integer NOT NULL
);

INSERT INTO release_items (id, name, amount) VALUES
    (1, 'alpha', 10),
    (2, 'beta', 20),
    (3, 'gamma', 30);

CREATE TABLE lock_targets (
    id integer PRIMARY KEY,
    note text NOT NULL
);

INSERT INTO lock_targets (id, note) VALUES (1, 'contended row');

CREATE ROLE tablepro_mtls LOGIN PASSWORD 'tablepro';
GRANT CONNECT ON DATABASE tablepro TO tablepro_mtls;
GRANT USAGE ON SCHEMA public TO tablepro_mtls;
GRANT SELECT ON release_items TO tablepro_mtls;
