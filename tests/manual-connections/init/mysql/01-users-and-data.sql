CREATE DATABASE IF NOT EXISTS tablepro_extra;
CREATE USER IF NOT EXISTS 'tablepro_ro'@'%' IDENTIFIED BY 'tablepro_ro_password';
GRANT SELECT ON tablepro_lab.* TO 'tablepro_ro'@'%';
GRANT ALL PRIVILEGES ON tablepro_extra.* TO 'tablepro_rw'@'%';

CREATE TABLE people (
    id BIGINT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE,
    active BOOLEAN NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO people (id, name, email, active) VALUES
    (1, 'Ada Lovelace', 'ada@example.test', true),
    (2, 'Grace Hopper', 'grace@example.test', false);

GRANT SELECT, INSERT, UPDATE, DELETE ON tablepro_lab.* TO 'tablepro_rw'@'%';
FLUSH PRIVILEGES;
