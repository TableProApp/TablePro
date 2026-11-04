-- Beekeeper saves sslRejectUnauthorized and trustServerCertificate as 1 unless the user turns them off.
INSERT INTO saved_connection (id, name, connectionType, host, ssl, sslCaFile, sslCertFile, sslKeyFile,
    sslRejectUnauthorized, trustServerCertificate) VALUES
    (11, 'PG no files', 'postgresql', 'pg', 1, NULL, NULL, NULL, 1, 1),
    (12, 'PG with CA', 'postgresql', 'pg', 1, '/certs/ca.pem', NULL, NULL, 1, 1),
    (13, 'PG unverified', 'postgresql', 'pg', 1, '/certs/ca.pem', NULL, NULL, 0, 1),
    (14, 'MySQL no files', 'mysql', 'my', 1, NULL, NULL, NULL, 1, 1),
    (15, 'SQL Server', 'sqlserver', 'ms', 1, NULL, NULL, NULL, 0, 1),
    (16, 'SQL Server trusted', 'sqlserver', 'ms', 1, '/certs/ca.pem', '/certs/c.pem', '/certs/c.key', 0, 0),
    (17, 'Redis', 'redis', 'cache', 1, NULL, NULL, NULL, 1, 1);
