SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CaptureSessionSnapshots
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @capture_time DATETIME2(0) = SYSDATETIME();

    CREATE TABLE #Sessions
    (
        session_id INT NOT NULL,
        database_id INT NOT NULL,
        database_name SYSNAME NOT NULL,
        host_name NVARCHAR(128) NOT NULL,
        login_name NVARCHAR(128) NOT NULL,
        capture_time DATETIME2(0) NOT NULL
    );

    INSERT INTO #Sessions (session_id, database_id, database_name, host_name, login_name, capture_time)
    SELECT
        s.session_id,
        s.database_id,
        DB_NAME(s.database_id) AS database_name,
        ISNULL(NULLIF(s.host_name, ''), 'UNKNOWN') AS host_name,
        ISNULL(NULLIF(s.login_name, ''), 'UNKNOWN') AS login_name,
        @capture_time
    FROM sys.dm_exec_sessions AS s
    WHERE s.is_user_process = 1
      AND s.database_id > 4
      AND s.database_id IS NOT NULL;

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

IF OBJECT_ID('dbo.DatabaseSessionHourly', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DatabaseSessionHourly
    (
        SnapshotDate DATE NOT NULL,
        SnapshotHour TINYINT NOT NULL,
        DatabaseName SYSNAME NOT NULL,
        HostName NVARCHAR(128) NOT NULL,
        LoginName NVARCHAR(128) NOT NULL,
        SessionCount INT NOT NULL,
        CONSTRAINT PK_DatabaseSessionHourly PRIMARY KEY CLUSTERED
            (SnapshotDate, SnapshotHour, DatabaseName, HostName, LoginName)
    );
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER VIEW dbo.vw_DatabaseSessionTotalsByPrincipal
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

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER VIEW dbo.vw_DatabaseSessionDailyTotalsByPrincipal
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

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER VIEW dbo.vw_DatabaseSessionTotalsByDatabase
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
