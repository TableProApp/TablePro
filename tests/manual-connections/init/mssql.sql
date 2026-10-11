IF DB_ID(N'tablepro_lab') IS NULL CREATE DATABASE tablepro_lab;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'tablepro_rw')
    CREATE LOGIN tablepro_rw WITH PASSWORD = 'TableProRw!123';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'tablepro_ro')
    CREATE LOGIN tablepro_ro WITH PASSWORD = 'TableProRo!123';
GO
USE tablepro_lab;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'tablepro_rw')
    CREATE USER tablepro_rw FOR LOGIN tablepro_rw;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'tablepro_ro')
    CREATE USER tablepro_ro FOR LOGIN tablepro_ro;
IF OBJECT_ID(N'dbo.people', N'U') IS NULL
BEGIN
    CREATE TABLE people (
        id BIGINT NOT NULL PRIMARY KEY,
        name NVARCHAR(255) NOT NULL,
        email NVARCHAR(255) UNIQUE,
        active BIT NOT NULL,
        created_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
    INSERT INTO people (id, name, email, active) VALUES
        (1, 'Ada Lovelace', 'ada@example.test', 1),
        (2, 'Grace Hopper', 'grace@example.test', 0);
END;
GRANT SELECT, INSERT, UPDATE, DELETE TO tablepro_rw;
GRANT SELECT TO tablepro_ro;
GO
