CREATE USER IF NOT EXISTS tablepro_ro IDENTIFIED WITH plaintext_password BY 'tablepro_ro_password';
GRANT SELECT ON tablepro_lab.* TO tablepro_ro;

CREATE TABLE IF NOT EXISTS tablepro_lab.people (
    id UInt64,
    name String,
    email Nullable(String),
    active Bool,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO tablepro_lab.people (id, name, email, active) VALUES
    (1, 'Ada Lovelace', 'ada@example.test', true),
    (2, 'Grace Hopper', 'grace@example.test', false);
