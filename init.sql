DECLARE @DropAndRecreate BIT = 0;

IF @DropAndRecreate = 1
BEGIN
    IF OBJECT_ID('dbo.vw_DatabaseSessionTotalsByPrincipal', 'V') IS NOT NULL
        DROP VIEW dbo.vw_DatabaseSessionTotalsByPrincipal;

    IF OBJECT_ID('dbo.vw_DatabaseSessionDailyTotalsByPrincipal', 'V') IS NOT NULL
        DROP VIEW dbo.vw_DatabaseSessionDailyTotalsByPrincipal;

    IF OBJECT_ID('dbo.vw_DatabaseSessionTotalsByDatabase', 'V') IS NOT NULL
        DROP VIEW dbo.vw_DatabaseSessionTotalsByDatabase;

    IF OBJECT_ID('dbo.usp_CaptureSessionSnapshots', 'P') IS NOT NULL
        DROP PROCEDURE dbo.usp_CaptureSessionSnapshots;

    IF OBJECT_ID('dbo.CapturedSessions', 'U') IS NOT NULL
        DROP TABLE dbo.CapturedSessions;

    IF OBJECT_ID('dbo.DatabaseSessionHourly', 'U') IS NOT NULL
        DROP TABLE dbo.DatabaseSessionHourly;
END;
GO

IF OBJECT_ID('dbo.DatabaseSessionHourly', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DatabaseSessionHourly
    (
        Id INT IDENTITY(1,1) NOT NULL,
        SnapshotDate DATE NOT NULL,
        SnapshotHour TINYINT NOT NULL,
        DatabaseName SYSNAME NOT NULL,
        HostName NVARCHAR(128) NOT NULL,
        LoginName NVARCHAR(128) NOT NULL,
        SessionCount INT NOT NULL,
        CONSTRAINT PK_DatabaseSessionHourly PRIMARY KEY CLUSTERED (Id)
    );

    CREATE UNIQUE NONCLUSTERED INDEX IX_DatabaseSessionHourly_UQ
        ON dbo.DatabaseSessionHourly (SnapshotDate, SnapshotHour, DatabaseName, HostName, LoginName);
END;
GO

IF OBJECT_ID('dbo.CapturedSessions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CapturedSessions
    (
        session_id INT NOT NULL,
        login_time DATETIME2(0) NOT NULL,
        SnapshotHour DATETIME2(0) NOT NULL,
        CONSTRAINT PK_CapturedSessions PRIMARY KEY CLUSTERED (session_id, login_time, SnapshotHour)
    );
END;
GO

IF OBJECT_ID('dbo.usp_CaptureSessionSnapshots', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_CaptureSessionSnapshots;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE PROCEDURE dbo.usp_CaptureSessionSnapshots
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @capture_time DATETIME2(0) = SYSDATETIME();
    DECLARE @snapshot_hour DATETIME2(0) = DATEADD(HOUR, DATEDIFF(HOUR, 0, @capture_time), 0);

    DELETE FROM dbo.CapturedSessions
    WHERE SnapshotHour < @snapshot_hour;

    CREATE TABLE #Sessions
    (
        session_id INT NOT NULL,
        login_time DATETIME2(0) NOT NULL,
        database_id INT NOT NULL,
        database_name SYSNAME NOT NULL,
        host_name NVARCHAR(128) NOT NULL,
        login_name NVARCHAR(128) NOT NULL,
        capture_time DATETIME2(0) NOT NULL
    );

    INSERT INTO #Sessions (session_id, login_time, database_id, database_name, host_name, login_name, capture_time)
    SELECT
        s.session_id,
        s.login_time,
        s.database_id,
        DB_NAME(s.database_id) AS database_name,
        ISNULL(NULLIF(s.host_name, ''), 'UNKNOWN') AS host_name,
        ISNULL(NULLIF(s.login_name, ''), 'UNKNOWN') AS login_name,
        @capture_time
    FROM sys.dm_exec_sessions AS s
    WHERE s.is_user_process = 1
      AND s.database_id > 4
      AND s.database_id IS NOT NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.CapturedSessions AS cs
          WHERE cs.session_id = s.session_id
            AND cs.login_time = s.login_time
            AND cs.SnapshotHour = @snapshot_hour
      );

    INSERT INTO dbo.CapturedSessions (session_id, login_time, SnapshotHour)
    SELECT DISTINCT session_id, login_time, @snapshot_hour
    FROM #Sessions;

    WITH Aggregated AS
    (
        SELECT
            CAST(@capture_time AS DATE) AS SnapshotDate,
            DATEPART(HOUR, @capture_time) AS SnapshotHour,
            database_name,
            host_name,
            login_name,
            COUNT(*) AS SessionCount
        FROM #Sessions
        GROUP BY database_name, host_name, login_name
    )
    MERGE dbo.DatabaseSessionHourly AS target
    USING Aggregated AS source
        ON target.SnapshotDate = source.SnapshotDate
       AND target.SnapshotHour = source.SnapshotHour
       AND target.DatabaseName = source.database_name
       AND target.HostName = source.host_name
       AND target.LoginName = source.login_name
    WHEN MATCHED THEN
        UPDATE SET target.SessionCount = target.SessionCount + source.SessionCount
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (SnapshotDate, SnapshotHour, DatabaseName, HostName, LoginName, SessionCount)
        VALUES (source.SnapshotDate, source.SnapshotHour, source.database_name, source.host_name, source.login_name, source.SessionCount);
END;
GO

IF OBJECT_ID('dbo.vw_DatabaseSessionTotalsByPrincipal', 'V') IS NOT NULL
    DROP VIEW dbo.vw_DatabaseSessionTotalsByPrincipal;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE VIEW dbo.vw_DatabaseSessionTotalsByPrincipal
AS
WITH UserDatabases AS
(
    SELECT name AS DatabaseName
    FROM sys.databases
    WHERE database_id > 4
),
SessionTotals AS
(
    SELECT
        DatabaseName,
        HostName,
        LoginName,
        SUM(SessionCount) AS TotalSessions
    FROM dbo.DatabaseSessionHourly
    GROUP BY DatabaseName, HostName, LoginName
)
SELECT
    u.DatabaseName,
    COALESCE(st.HostName, 'N/A') AS HostName,
    COALESCE(st.LoginName, 'N/A') AS LoginName,
    ISNULL(st.TotalSessions, 0) AS TotalSessions
FROM UserDatabases AS u
LEFT JOIN SessionTotals AS st
    ON st.DatabaseName = u.DatabaseName;
GO

IF OBJECT_ID('dbo.vw_DatabaseSessionDailyTotalsByPrincipal', 'V') IS NOT NULL
    DROP VIEW dbo.vw_DatabaseSessionDailyTotalsByPrincipal;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE VIEW dbo.vw_DatabaseSessionDailyTotalsByPrincipal
AS
WITH UserDatabases AS
(
    SELECT name AS DatabaseName
    FROM sys.databases
    WHERE database_id > 4
),
SessionTotals AS
(
    SELECT
        SnapshotDate,
        DatabaseName,
        HostName,
        LoginName,
        SUM(SessionCount) AS TotalSessions
    FROM dbo.DatabaseSessionHourly
    GROUP BY SnapshotDate, DatabaseName, HostName, LoginName
),
SnapshotDates AS
(
    SELECT DISTINCT SnapshotDate
    FROM dbo.DatabaseSessionHourly
),
ZeroFill AS
(
    SELECT
        d.SnapshotDate,
        u.DatabaseName,
        'N/A' AS HostName,
        'N/A' AS LoginName,
        0 AS TotalSessions
    FROM SnapshotDates AS d
    CROSS JOIN UserDatabases AS u
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM SessionTotals AS st
        WHERE st.SnapshotDate = d.SnapshotDate
          AND st.DatabaseName = u.DatabaseName
    )
)
SELECT
    SnapshotDate,
    DatabaseName,
    HostName,
    LoginName,
    TotalSessions
FROM SessionTotals
UNION ALL
SELECT
    SnapshotDate,
    DatabaseName,
    HostName,
    LoginName,
    TotalSessions
FROM ZeroFill;
GO

IF OBJECT_ID('dbo.vw_DatabaseSessionTotalsByDatabase', 'V') IS NOT NULL
    DROP VIEW dbo.vw_DatabaseSessionTotalsByDatabase;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE VIEW dbo.vw_DatabaseSessionTotalsByDatabase
AS
WITH UserDatabases AS
(
    SELECT name AS DatabaseName
    FROM sys.databases
    WHERE database_id > 4
),
SessionTotals AS
(
    SELECT
        DatabaseName,
        SUM(SessionCount) AS TotalSessions
    FROM dbo.DatabaseSessionHourly
    GROUP BY DatabaseName
)
SELECT
    u.DatabaseName,
    ISNULL(st.TotalSessions, 0) AS TotalSessions
FROM UserDatabases AS u
LEFT JOIN SessionTotals AS st
    ON st.DatabaseName = u.DatabaseName;
GO
