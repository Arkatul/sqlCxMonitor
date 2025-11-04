DECLARE @databaseName SYSNAME = N'YourDatabaseName';
DECLARE @jobName SYSNAME = N'Capture Session Snapshots';
DECLARE @scheduleName SYSNAME = N'Capture Session Snapshots Every 5 Minutes';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @jobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @jobName;
END;

EXEC msdb.dbo.sp_add_job
    @job_name = @jobName,
    @enabled = 1,
    @description = N'Runs dbo.usp_CaptureSessionSnapshots every five minutes.',
    @category_name = N'[Uncategorized (Local)]';

EXEC msdb.dbo.sp_add_jobstep
    @job_name = @jobName,
    @step_name = N'Execute dbo.usp_CaptureSessionSnapshots',
    @subsystem = N'TSQL',
    @database_name = @databaseName,
    @command = N'EXEC dbo.usp_CaptureSessionSnapshots;';

EXEC msdb.dbo.sp_add_schedule
    @schedule_name = @scheduleName,
    @enabled = 1,
    @freq_type = 4,              -- Daily
    @freq_interval = 1,
    @freq_subday_type = 4,       -- Minutes
    @freq_subday_interval = 5,   -- Every 5 minutes
    @active_start_time = 0;

EXEC msdb.dbo.sp_attach_schedule
    @job_name = @jobName,
    @schedule_name = @scheduleName;

EXEC msdb.dbo.sp_add_jobserver
    @job_name = @jobName,
    @server_name = @@SERVERNAME;
