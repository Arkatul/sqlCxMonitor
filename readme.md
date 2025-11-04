# sqlCxMonitor

Scripts for capturing interactive session activity across SQL Server databases so you can identify databases, hosts, and logins that are still in use. The resulting data supports technological-debt efforts such as deciding which databases can be taken offline, mapping which application servers connect to which databases, and confirming which principals remain active.

## Contents

- `1-init.sql` – Creates the tables, stored procedure, and views used to capture and report session activity.
- `2-job.sql` – Creates a SQL Server Agent job that executes the capture procedure every five minutes.

## How It Works

1. `1-init.sql` creates two tables:
   - `dbo.CapturedSessions`: Tracks which sessions have already been processed for a given hour to prevent double counting.
   - `dbo.DatabaseSessionHourly`: Stores aggregated counts of active user sessions grouped by database, host, and login per hour.
2. The stored procedure `dbo.usp_CaptureSessionSnapshots` collects new user sessions from `sys.dm_exec_sessions`, records them in `CapturedSessions`, and aggregates counts into `DatabaseSessionHourly`.
3. Three views expose the captured data (see [Views](#views)).
4. `2-job.sql` provisions a SQL Server Agent job that runs `dbo.usp_CaptureSessionSnapshots` every five minutes so activity is gathered continuously.

## Deployment

1. **Select a database**
   - Choose or create a utility database (for example, `sqlCxMonitor`) where the monitoring objects will reside.
   - Ensure the account running the scripts has rights to create objects in that database and manage SQL Agent jobs (`SQLAgentOperatorRole` or higher).

2. **Deploy database objects**
   - Update the connection in SSMS, Azure Data Studio, or `sqlcmd` to the target database.
   - Run `1-init.sql`.
     - Optional: set `@DropAndRecreate = 1` near the top of the script if you want to drop and rebuild existing objects.

3. **Configure the capture job**
   - Open `2-job.sql` and set `@databaseName` to the database that now hosts `dbo.usp_CaptureSessionSnapshots`.
   - Execute the script in a context that can manage SQL Agent jobs (master or msdb is fine).
   - The script removes any existing job with the same name, creates a new job that calls the procedure, schedules it every five minutes, and targets the local server.

4. **Verify**
   - Check SQL Agent for the new job named `Capture Session Snapshots` and confirm it is enabled.
   - Execute `EXEC dbo.usp_CaptureSessionSnapshots;` once manually to seed data.
   - Query the views described below to see captured activity.

## Views

- `dbo.vw_DatabaseSessionTotalsByPrincipal`
  - `DatabaseName`: Database where sessions were observed.
  - `HostName`: Client host captured for the session (defaults to `N/A` when no sessions are present yet for the database).
  - `LoginName`: Login associated with the session (defaults to `N/A` when no sessions are present yet).
  - `TotalSessions`: Lifetime total sessions counted for the `(DatabaseName, HostName, LoginName)` combination.

- `dbo.vw_DatabaseSessionDailyTotalsByPrincipal`
  - `SnapshotDate`: Date of the aggregated snapshot.
  - `DatabaseName`: Database name.
  - `HostName`: Client host; `N/A` rows are generated to highlight days without activity per database.
  - `LoginName`: Login; `N/A` rows indicate no activity for that database on that date.
  - `TotalSessions`: Number of sessions captured on that day for the combination.

- `dbo.vw_DatabaseSessionTotalsByDatabase`
  - `DatabaseName`: Database name.
  - `TotalSessions`: Cumulative sessions observed for the database; zero-filled for databases without activity.

These views provide the insight necessary to determine which databases are still accessed, by which servers, and under which logins, enabling informed decisions about retiring or consolidating databases.

## Maintenance Notes

- The capture job retains per-session identifiers for a single snapshot hour; rows older than the current hour are removed each run.
- Adjust the SQL Agent schedule in `2-job.sql` if you need a different frequency.
- Include the scripts in source control alongside release automation so deployments remain consistent across environments.
