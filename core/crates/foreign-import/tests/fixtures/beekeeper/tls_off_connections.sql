-- SSL off. The SQL Server form still saves its own "Trust Server Certificate?" box, and certificate files
-- left from an earlier SSL setup stay in the row.
INSERT INTO saved_connection (id, name, connectionType, host, ssl, sslCaFile, sslCertFile, sslKeyFile,
    sslRejectUnauthorized, trustServerCertificate) VALUES
    (21, 'SQL Server trusting', 'sqlserver', 'ms', 0, NULL, NULL, NULL, 1, 1),
    (22, 'SQL Server checking', 'sqlserver', 'ms', 0, '/certs/ca.pem', '/certs/c.pem', '/certs/c.key', 1, 0),
    (23, 'PG plain', 'postgresql', 'pg', 0, NULL, NULL, NULL, 1, 1),
    (24, 'MySQL plain', 'mysql', 'my', 0, NULL, NULL, NULL, 1, 1);
