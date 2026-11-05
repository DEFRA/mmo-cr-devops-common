# Legacy Analytics Migration

Moves pull request analytics held in the old dashboard's MongoDB (`copilot_analytics.payloads`) into
the current dashboard. The new dashboard runs on the Core Delivery Platform (CDP), where the
database cannot be reached directly, so every record is sent through `POST /api/ingest` as a
`schemaVersion: 2` payload with `source: backfill`.

| Script                     | Purpose                                                                                      |
| :------------------------- | :------------------------------------------------------------------------------------------- |
| `Invoke-LegacyRestore.ps1` | Restores the dump into a local `copilot-v1-db` container, profiles it, exports NDJSON        |
| `Get-LegacyProfile.js`     | Aggregate counts only; run by `Invoke-LegacyRestore.ps1` inside the container                |
| `Publish-LegacyPayloads.ps1` | Converts each pull request to the v2 contract, validates it, and posts it to the ingest URL |

## Data Protection

The dump, the NDJSON export and the container hold contributor identities, which are personal
data. Keep them on an encrypted disk, never commit them (`output/` is git-ignored), and delete them
when the migration is verified. The audit and summary files hold repository names, pull request
numbers and outcomes only.

## Prerequisites

- PowerShell 7.2 or later and Docker.
- MongoDB Database Tools (`mongorestore`, `mongoexport`).
- A GitHub token with read access to pull requests and contents for the repositories. The title
  and changed files of each pull request are read from GitHub because the legacy documents do not
  hold them, and the v2 contract requires them. Without a token GitHub allows 60 requests an hour.
- The ingest token for the target environment, from the platform owner. `INGEST_ALLOW_SHARED_TOKEN`
  must still be `true` there.
- Each repository mapped to a project in the target; unmapped repositories are stored unassigned.

## Set Secrets

Tokens are read from the environment only, never from parameters.

```powershell
$env:GITHUB_TOKEN = Read-Host -AsSecureString 'GitHub token' | ConvertFrom-SecureString -AsPlainText
$env:INGEST_TOKEN = Read-Host -AsSecureString 'Ingest token' | ConvertFrom-SecureString -AsPlainText
```

## Steps

1. Restore and export. Defaults point at the tools and dump folders; the container listens on
   `127.0.0.1:27018` only.

   ```powershell
   ./Invoke-LegacyRestore.ps1 -Recreate
   ```

2. Read `output/payloads.ndjson.profile.json`: duplicate pull requests (older versions are
   skipped), documents missing required fields (reported as `invalid`), and the repository list.

3. Dry run. Reads, enriches, converts and validates everything; sends nothing.

   ```powershell
   ./Publish-LegacyPayloads.ps1 -InputPath ./output/payloads.ndjson -DryRun
   ```

4. Local rehearsal against a local dashboard, run twice. The second run must report only `ignored`.

   ```powershell
   ./Publish-LegacyPayloads.ps1 -InputPath ./output/payloads.ndjson -IngestUrl http://localhost:3000/api/ingest
   ```

5. Migrate in batches of 10, never in one stretch. Each batch is its own run with its own audit
   and summary file, so progress is easy to track and a failed batch is simply re-run. The order of
   pull requests is stable, so `-SkipRecords` picks the batch.

   ```powershell
   $url = 'https://<dashboard-host>/api/ingest'
   $total = 774   # "pull request(s)" from Pass 1 of the dry run
   for ($skip = 0; $skip -lt $total; $skip += 10) {
       $batch = $skip / 10 + 1
       $s = ./Publish-LegacyPayloads.ps1 -InputPath ./output/payloads.ndjson -IngestUrl $url `
           -SkipRecords $skip -MaxRecords 10 -RunId ('batch-{0:d3}' -f $batch)
       "Batch $batch stored=$($s.counts.stored) ignored=$($s.counts.ignored) failed=$($s.counts.failed + $s.counts.rejected)"
       if ($s.counts.failed + $s.counts.rejected -gt 0) { break }
   }
   ```

   Check the first batch in the dashboard before letting the rest run. To resume, start `$skip` at
   the first unfinished batch.

   Add `-JiraProjectKey <KEY>` to keep only the project's Jira keys, `-Repository DEFRA/<name>` to
   limit the run, and `-OnEnrichmentFailure FallbackV1` only if you accept sending a payload with no
   title, Jira keys or file counts (the backend then treats it as `live`, which blocks a later
   official backfill for that merged pull request).

## Re-running

Delivery is idempotent: the backend keeps one record per pull request and replaces it only when
`calculatedAt` is newer. A re-run after a failure converges; `stored` and `ignored` are both
success. HTTP 401 aborts the run immediately. There is no resume file.

## Outcomes

Each line of `output/audit-<RunId>.jsonl` carries one outcome.

| Outcome         | Meaning                                                             |
| :-------------- | :------------------------------------------------------------------ |
| `stored`        | Inserted, or replaced an older record                               |
| `ignored`       | Stored record is the same, newer, or a live merged record           |
| `dry-run-valid` | Would have been sent                                                |
| `skipped`       | GitHub could not describe the pull request (`-OnEnrichmentFailure Skip`) |
| `invalid`       | Failed local validation against the backend contract                |
| `rejected`      | Refused by the ingest endpoint (400, 403, 413)                      |
| `failed`        | Transient failure that exhausted its retries                        |
| `auth-failed`   | HTTP 401; the run aborted                                           |

## Rollback

Take a database snapshot through the platform team before the production run. Migrated records carry
`source: backfill`; removing them needs platform database access.

## Cleanup

```powershell
docker rm -f copilot-v1-db
Remove-Item -Recurse -Force ./output
Remove-Item Env:GITHUB_TOKEN, Env:INGEST_TOKEN
```

Revoke the GitHub token when finished.
