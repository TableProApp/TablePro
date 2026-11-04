CREATE TABLE saved_connection (
    id INTEGER PRIMARY KEY, name TEXT, connectionType TEXT, host TEXT, port INTEGER, username TEXT,
    defaultDatabase TEXT, password TEXT, ssl INTEGER DEFAULT 0, sslCaFile TEXT, sslCertFile TEXT,
    sslKeyFile TEXT, sslRejectUnauthorized INTEGER DEFAULT 0, trustServerCertificate INTEGER DEFAULT 0,
    sshEnabled INTEGER DEFAULT 0, sshHost TEXT, sshPort INTEGER, sshUsername TEXT, sshMode TEXT,
    sshKeyfile TEXT, sshKeyfilePassword TEXT, sshPassword TEXT, sshBastionHost TEXT,
    sshBastionHostPort INTEGER, sshBastionUsername TEXT, sshBastionMode TEXT, sshBastionKeyfile TEXT,
    labelColor TEXT, connectionFolderId INTEGER, workspaceId INTEGER DEFAULT -1
);
CREATE TABLE connection_folder (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO connection_folder (id, name) VALUES (1, 'Production');
INSERT INTO saved_connection (id, name, connectionType, host, port, username, defaultDatabase, connectionFolderId)
    VALUES (1, 'Shop', 'postgresql', 'db.example.com', 5432, 'app', 'shop', 1);
INSERT INTO saved_connection (id, name, connectionType, host, port, workspaceId)
    VALUES (2, 'Cloud only', 'mysql', 'cloud.example.com', 3306, 7);
