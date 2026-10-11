CREATE ROLE tablepro_rw LOGIN PASSWORD 'tablepro_rw_password';
CREATE ROLE tablepro_ro LOGIN PASSWORD 'tablepro_ro_password';
CREATE DATABASE tablepro_extra OWNER tablepro_rw;

CREATE TABLE people (
    id BIGINT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE,
    active BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO people (id, name, email, active) VALUES
    (1, 'Ada Lovelace', 'ada@example.test', true),
    (2, 'Grace Hopper', 'grace@example.test', false);

GRANT CONNECT ON DATABASE tablepro_lab TO tablepro_rw, tablepro_ro;
GRANT USAGE ON SCHEMA public TO tablepro_rw, tablepro_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO tablepro_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO tablepro_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO tablepro_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO tablepro_ro;
