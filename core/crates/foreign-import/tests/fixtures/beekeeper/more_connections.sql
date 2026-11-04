-- Passwords are simple-encryptor values under the key that .key holds.
INSERT INTO connection_folder (id, name) VALUES (2, '');
UPDATE saved_connection SET password = '68d600e7fdde9494299f2919765dee8a00f045edfb8b29df18e302ce97f5709d7df6652278ff5ffba98125b9a15ab670YpZN18cOKT8hHqngs6DlTQ==' WHERE id = 1;
INSERT INTO saved_connection (
    id, name, connectionType, host, port, username, password, ssl, sslCaFile, sslCertFile, sslKeyFile,
    sslRejectUnauthorized, sshEnabled, sshHost, sshPort, sshUsername, sshMode, sshKeyfile, sshKeyfilePassword,
    sshPassword, sshBastionHost, sshBastionHostPort, sshBastionUsername, sshBastionMode, labelColor,
    connectionFolderId
) VALUES (
    3, 'Tunnelled', 'MySQL', 'db.internal', 3307, 'root',
    '828d9d527b455f35508be018f996b52194fdb77b58f11aedbcf82ba5586d86a88fbe105f2d0a460fbe3ec3521697e158bqAob2K0D5qYls/Vpu2TpQ==',
    1, '/certs/ca.pem', '/certs/client.pem', '/certs/client.key', 1, 1, 'bastion.example.com', 2222, 'deploy',
    'keyfile', 'id_ed25519',
    '6a24aac78583f2909bc457f7998b95bd183e72c5dcb1aa245d3688a560a70225da69addd820dfacc584e4b4d0f965ecaXefMUQ2vYJrrPc9Eo2hlHA==',
    '92bd7a8e4d36592cdb87a9d6a85ac64bfc52127d1f05163170f66004e94a6fcd10ac9ed22202f668b8a9b3e455b5cc44ZHFMLWVbSJvB3S0fwTburQ==',
    'jump.example.com', 22, 'hop', 'agent', 'grey', 2
);
INSERT INTO saved_connection (
    id, name, connectionType, host, port, password, ssl, sslRejectUnauthorized, trustServerCertificate, sshEnabled,
    sshHost, sshMode, sshBastionHost, labelColor
) VALUES (4, '', 'sqlserver', '', NULL, '', 1, 1, 1, 1, 'gateway', 'userpass', '', 'Teal');
INSERT INTO saved_connection (id, name, connectionType, host, port, ssl) VALUES (5, 'Lake', 'acmedb', 'lake', 8000, 1);
INSERT INTO saved_connection (id, name, connectionType, host) VALUES (6, 'No type', NULL, 'nowhere');
INSERT INTO saved_connection (id, name, connectionType, host) VALUES (7, 'Empty type', '', 'nowhere');
ALTER TABLE favorite_query ADD COLUMN workspaceId INTEGER DEFAULT -1;
INSERT INTO favorite_query (id, title, text, workspaceId) VALUES (6, 'Cloud report', 'select 2;', 7);
