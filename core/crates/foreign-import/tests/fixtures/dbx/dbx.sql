-- The tables of t8y2/dbx at 39a77b5 (crates/dbx-core/src/persistence/storage.rs, SCHEMA_STATEMENTS),
-- with rows in the shape DBX writes them: `ConnectionConfig` and `TransportLayerConfig` as serde
-- writes them (crates/dbx-types/src/models/connection.rs), secrets as `dbxenc1` envelopes
-- (persistence/secret_codec.rs) whose bytes are random, and the sidebar layout of ai/mcp_policy.rs.
CREATE TABLE IF NOT EXISTS connections (
    id TEXT PRIMARY KEY,
    config_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS connection_secrets (
    connection_id TEXT NOT NULL,
    key TEXT NOT NULL,
    secret TEXT NOT NULL,
    secret_enc TEXT,
    PRIMARY KEY (connection_id, key)
);
CREATE TABLE IF NOT EXISTS tunnel_profiles (
    id TEXT PRIMARY KEY,
    config_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sidebar_layout (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    layout_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS saved_sql_folders (
    id TEXT PRIMARY KEY,
    connection_id TEXT NOT NULL,
    parent_folder_id TEXT,
    name TEXT NOT NULL DEFAULT '',
    order_index INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS saved_sql_files (
    is_default_query INTEGER NOT NULL DEFAULT 0,
    id TEXT PRIMARY KEY,
    connection_id TEXT NOT NULL,
    folder_id TEXT,
    name TEXT NOT NULL DEFAULT '',
    database_name TEXT NOT NULL DEFAULT '',
    catalog_name TEXT,
    schema_name TEXT,
    sql_text TEXT NOT NULL DEFAULT '',
    order_index INTEGER NOT NULL DEFAULT 0,
    open_count INTEGER NOT NULL DEFAULT 0,
    opened_at TEXT,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT ''
);

INSERT INTO connections VALUES ('c-pg', '{"id":"c-pg","name":"Orders","db_type":"postgres","driver_profile":"postgres",
  "url_params":"sslmode=verify-full&application_name=dbx","host":"db.example.com","port":5433,"username":"ada",
  "password":"","database":"orders","color":"#ef4444",
  "transport_layers":[
    {"type":"ssh","id":"l1","name":"Edge","enabled":true,"host":"edge.example.com","port":22,"user":"jump",
     "password":"","key_path":"id_ed25519","key_passphrase":"","connect_timeout_secs":5,"expose_lan":false,
     "use_ssh_agent":false,"ssh_agent_sock_path":"","ssh_agent_key_fingerprint":"","auth_method":"key"},
    {"type":"ssh","id":"l2","name":"","enabled":true,"host":"","port":22,"user":"","password":"","key_path":"",
     "key_passphrase":"","connect_timeout_secs":5,"expose_lan":false,"use_ssh_agent":false,
     "ssh_agent_sock_path":"","ssh_agent_key_fingerprint":"","auth_method":"","profile_id":"tp1"}],
  "connect_timeout_secs":10,"query_timeout_secs":60,"idle_timeout_secs":60,"manual_transaction_timeout_secs":300,
  "idle_disconnect_secs":0,"keepalive_interval_secs":30,"ssl":true,"ca_cert_path":"/certs/ca.pem",
  "client_cert_path":"/certs/client.pem","client_key_path":"/certs/client.key","sysdba":false,
  "connection_string":null,"external_config":null,"jdbc_driver_class":null,"jdbc_driver_paths":[],"save_password":true}');
INSERT INTO connections VALUES ('c-maria', '{"id":"c-maria","name":"Shop","db_type":"mysql","driver_profile":"mariadb",
  "url_params":null,"host":"","port":0,"username":"root","password":"","database":null,"color":"#3b82f6",
  "transport_layers":[{"type":"proxy","id":"p1","name":"","enabled":true,"proxy_type":"socks5",
    "host":"socks.example.com","port":1080,"username":"","password":""}],
  "ssl":false,"save_password":true}');
INSERT INTO connections VALUES ('c-sqlite', '{"id":"c-sqlite","name":"Local file","db_type":"sqlite",
  "host":"~/data/app.db","port":0,"username":"","password":"","database":null,"color":null,
  "attached_databases":[{"name":"logs","path":"/data/logs.db"}],"ssl":false}');
INSERT INTO connections VALUES ('c-duck', '{"id":"c-duck","name":"Analytics","db_type":"duckdb",
  "host":"/data/warehouse.duckdb","port":0,"username":"","password":"","database":null,
  "init_script":"INSTALL httpfs; LOAD httpfs; SELECT 1;","ssl":false}');
INSERT INTO connections VALUES ('c-legacy', '{"id":"c-legacy","name":"Legacy","db_type":"postgres",
  "host":"legacy.example.com","port":5432,"username":"app","password":"inline-legacy-secret","database":"app",
  "ssh_enabled":true,"ssh_host":"bastion.example.com","ssh_port":2222,"ssh_user":"jump","ssh_key_path":"id_rsa",
  "ssh_password":"inline-ssh-secret","ssl":false}');
INSERT INTO connections VALUES ('c-mongo', '{"id":"c-mongo","name":"Atlas","db_type":"mongodb","host":"","port":27017,
  "username":"","password":"","database":null,"ssl":false}');
INSERT INTO connections VALUES ('c-gone', '{"id":"c-gone","name":"Behind a profile","db_type":"mysql",
  "host":"10.0.0.5","port":3306,"username":"ops","password":"","database":null,
  "transport_layers":[{"type":"ssh","id":"l9","enabled":true,"host":"","port":22,"profile_id":"deleted"}],"ssl":false}');
INSERT INTO connections VALUES ('c-cache', '{"id":"c-cache","name":"Cache","db_type":"redis","host":"cache.internal",
  "port":6379,"username":"","password":"","database":null,"color":"#c026d3",
  "transport_layers":[{"type":"ssh","id":"l3","enabled":true,"host":"bastion.example.com","port":22,"user":"ops",
    "use_ssh_agent":true,"auth_method":"agent","proxy_command":"cloudflared access ssh --hostname %h"}],"ssl":false}');
INSERT INTO connections VALUES ('c-hive', '{"id":"c-hive","name":"Warehouse","db_type":"hive","host":"hive.internal",
  "port":10000,"username":"","password":"","database":null,"ssl":false}');
INSERT INTO connections VALUES ('c-broken', 'this is not json');
INSERT INTO connections VALUES ('c-none', '{"id":"c-none","name":"No type","db_type":"","host":"x","port":1,
  "username":"","password":""}');

INSERT INTO connection_secrets VALUES ('c-pg', 'password', '',
  'dbxenc1.-3FKum-zY14Xff6W.h5ByNWu8dVhyOfARKADbpJk0cgGYUaCLBP_eVw0I');
INSERT INTO connection_secrets VALUES ('c-mongo', 'connection_string', '',
  'dbxenc1.6jf3WfZK-cmIAQlO.lknV_79yjNVuqp1ptK1V8Ho9ezogPpB6dVedneQENQFTSKfAO7sOSNI');

INSERT INTO tunnel_profiles VALUES ('tp1', '{"type":"ssh","id":"tp1","name":"Shared bastion","enabled":true,
  "host":"bastion.internal","port":2200,"user":"ops","password":"","key_path":"","key_passphrase":"",
  "connect_timeout_secs":5,"expose_lan":false,"use_ssh_agent":true,"ssh_agent_sock_path":"",
  "ssh_agent_key_fingerprint":"","auth_method":"agent"}');

INSERT INTO sidebar_layout VALUES (1, '{"groups":[{"id":"g1","name":"Production"},{"id":"g2","name":"EU"},
  {"id":"g3","name":"Caches"}],
  "order":[{"type":"group","id":"g1","children":[{"type":"group","id":"g2","children":[
      {"type":"connection","id":"c-pg"}]},{"type":"connection","id":"c-maria"}]},
    {"type":"group","id":"g3","connectionIds":["c-cache"]},
    {"type":"connection","id":"c-sqlite"}]}');

INSERT INTO saved_sql_folders (id, connection_id, parent_folder_id, name) VALUES
  ('sf1', 'c-pg', NULL, 'Reports'),
  ('sf2', 'c-pg', 'sf1', 'Monthly');
INSERT INTO saved_sql_files (is_default_query, id, connection_id, folder_id, name, database_name, sql_text) VALUES
  (0, 'q1', 'c-pg', 'sf2', 'revenue.sql', 'orders', 'SELECT sum(total) FROM orders'),
  (1, 'q2', 'c-pg', NULL, 'default.sql', 'orders', 'SELECT 1'),
  (0, 'q3', 'c-pg', NULL, 'blank.sql', 'orders', '  ' || char(10)),
  (0, 'q4', 'c-deleted', NULL, 'orphan.sql', '', 'SELECT 2'),
  (0, 'q5', 'c-maria', NULL, 'huge.sql', '', replace(hex(zeroblob(900001)), '00', 'x'));
