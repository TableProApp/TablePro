IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'tablepro')
BEGIN
    CREATE LOGIN tablepro WITH PASSWORD = 'tablepro', CHECK_POLICY = OFF;
END;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'tablepro')
BEGIN
    CREATE DATABASE tablepro;
END;

ALTER SERVER ROLE sysadmin ADD MEMBER tablepro;
