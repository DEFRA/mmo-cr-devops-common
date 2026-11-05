<#
.SYNOPSIS
    Migrates legacy v1 Copilot analytics documents (a mongoexport NDJSON file) to the current
    ingest contract and publishes them to the dashboard's POST /api/ingest endpoint.

.DESCRIPTION
    The file is read twice as a stream, never loaded whole:
      Pass 1  finds the newest document (calculatedAt, then file order) per repository and pull
              request. The ingest endpoint keeps one record per pull request, so older versions
              are counted as superseded and not sent.
      Pass 2  processes each newest document: it reads the pull request title and changed files
              from the GitHub API (and .analyticsignore / .analyticstests from the target branch),
              builds a schemaVersion 2 payload with source 'backfill', checks it against the
              backend contract, and posts it.

    Delivery is idempotent: the backend upserts on (repository, prNumber), so a re-run converges
    and a 'stored' or 'ignored' answer are both success. Transient failures (408, 429, 5xx, no
    response) are retried with exponential backoff and full jitter, honouring Retry-After. HTTP
    401 aborts the run immediately. Every record gets a line in audit-<RunId>.jsonl and the run
    ends with summary-<RunId>.json; neither holds a title, subject, author or contributor.

    Credentials are read from the environment only:
      INGEST_TOKEN   shared secret sent as x-ingest-token (not needed with -DryRun)
      GITHUB_TOKEN   optional; without it GitHub allows 60 requests an hour. GH_TOKEN also works.

.PARAMETER InputPath
    NDJSON file written by Invoke-LegacyRestore.ps1.

.PARAMETER IngestUrl
    Full ingest URL, ending /api/ingest. Defaults to COPILOT_ANALYTICS_INGEST_URL. HTTPS only,
    except loopback for a local rehearsal. Must not embed credentials.

.PARAMETER GitHubApiUrl
    GitHub REST API base URL. HTTPS only, except loopback.

.PARAMETER OutputDirectory
    Where the audit and summary files are written. Git-ignored by default.

.PARAMETER RunId
    Names the audit and summary files. Defaults to the UTC start time. An existing audit file with
    the same id is never overwritten.

.PARAMETER DryRun
    Do everything except send: read, enrich, transform and validate, then report what would be sent.

.PARAMETER OnEnrichmentFailure
    Skip (default) leaves out a pull request GitHub cannot describe. FallbackV1 sends it as a
    schemaVersion 1 payload instead, which has no title, Jira keys or file counts.

.PARAMETER Repository
    Only migrate these repositories (owner/name). Handy for a rehearsal.

.PARAMETER AllowedOwner
    Repositories owned by anyone else are rejected, so a corrupt value cannot steer a GitHub call.

.PARAMETER JiraProjectKey
    Keep only Jira keys from these projects, as the live producer's jira-project-keys input does.

.PARAMETER SkipRecords
    Leave out this many pull requests from the start of the (stable, file-ordered) selection.
    With -MaxRecords this runs one batch: -SkipRecords 20 -MaxRecords 10 is batch 3 of 10.

.PARAMETER MaxRecords
    Stop after this many pull requests (0 means all).

.PARAMETER DelayMilliseconds
    Pause after each sent payload.

.PARAMETER MaxAttempts
    Send attempts per payload, including the first.

.PARAMETER BackoffBaseSeconds
    Backoff ceiling for the first retry; it doubles each attempt.

.PARAMETER BackoffCapSeconds
    Longest backoff ceiling.

.PARAMETER MaxRateLimitWaitSeconds
    Longest wait for a GitHub rate limit to clear before the run aborts.

.PARAMETER MaxBytes
    Largest payload sent; must not exceed the ingest endpoint's INGEST_MAX_PAYLOAD_BYTES.

.EXAMPLE
    $env:GITHUB_TOKEN = Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText
    ./Publish-LegacyPayloads.ps1 -InputPath ./output/payloads.ndjson -DryRun

.EXAMPLE
    ./Publish-LegacyPayloads.ps1 -InputPath ./output/payloads.ndjson -IngestUrl https://dashboard.example/api/ingest
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter()]
    [string]$IngestUrl = $env:COPILOT_ANALYTICS_INGEST_URL,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$GitHubApiUrl = 'https://api.github.com',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')]
    [string]$RunId = [DateTime]::UtcNow.ToString('yyyyMMdd\THHmmss\Z'),

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [ValidateSet('Skip', 'FallbackV1')]
    [string]$OnEnrichmentFailure = 'Skip',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$')]
    [string[]]$Repository = @(),

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')]
    [string]$AllowedOwner = 'DEFRA',

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{1,49}$')]
    [string[]]$JiraProjectKey = @(),

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$SkipRecords = 0,

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$MaxRecords = 0,

    [Parameter()]
    [ValidateRange(0, 60000)]
    [int]$DelayMilliseconds = 200,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 5,

    [Parameter()]
    [ValidateRange(0, 3600)]
    [double]$BackoffBaseSeconds = 2,

    [Parameter()]
    [ValidateRange(0, 3600)]
    [double]$BackoffCapSeconds = 60,

    [Parameter()]
    [ValidateRange(0, 86400)]
    [int]$MaxRateLimitWaitSeconds = 900,

    [Parameter()]
    [ValidateRange(1024, 104857600)]
    [int]$MaxBytes = 2097152
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'LegacyMigration.Helpers.ps1')

#region Setup

function Exit-Migration {
    param([Parameter(Mandatory)][string]$Message)

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['LegacyAbort'] = $true
    throw $exception
}

function Get-SafeUri {
    param([string]$Url, [string]$Name)

    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Url) -or -not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw "$Name must be an absolute URL."
    }
    if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) {
        throw "$Name must use HTTPS; plain HTTP is allowed only for loopback."
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw "$Name must not carry credentials, a query string or a fragment."
    }
    return $uri
}

$ingestToken = $env:INGEST_TOKEN
$githubToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }

$resolvedInput = $null
try { $resolvedInput = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).ProviderPath }
catch { throw "Input file '$InputPath' does not exist." }
if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) { throw "Input path '$InputPath' is not a file." }

$githubUri = Get-SafeUri -Url $GitHubApiUrl -Name 'GitHubApiUrl'
$githubBase = $githubUri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')

$ingestUri = $null
if (-not $DryRun) {
    $ingestUri = Get-SafeUri -Url $IngestUrl -Name 'IngestUrl (or COPILOT_ANALYTICS_INGEST_URL)'
    if (-not $ingestUri.AbsolutePath.TrimEnd('/').EndsWith('/api/ingest', [StringComparison]::Ordinal)) {
        throw 'IngestUrl must end with /api/ingest.'
    }
    if ([string]::IsNullOrWhiteSpace($ingestToken)) {
        throw 'INGEST_TOKEN is not set. Set it in the environment; it is never accepted as a parameter.'
    }
    if ($ingestToken -notmatch '^[\x21-\x7E]+$') { throw 'INGEST_TOKEN contains characters that are not valid in an HTTP header.' }
}
if ($githubToken -and $githubToken -notmatch '^[\x21-\x7E]+$') { throw 'The GitHub token contains characters that are not valid in an HTTP header.' }

$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$auditPath = Join-Path $OutputDirectory "audit-$RunId.jsonl"
$summaryPath = Join-Path $OutputDirectory "summary-$RunId.json"
if ((Test-Path -LiteralPath $auditPath) -or (Test-Path -LiteralPath $summaryPath)) {
    throw "RunId '$RunId' has already been used in '$OutputDirectory'. Choose another with -RunId."
}

$script:GitHubBase = $githubBase
$script:GitHubToken = $githubToken
$script:Settings = [pscustomobject]@{
    OnEnrichmentFailure     = $OnEnrichmentFailure
    AllowedOwner            = $AllowedOwner
    JiraProjectKey          = $JiraProjectKey
    MaxAttempts             = $MaxAttempts
    BackoffBaseSeconds      = $BackoffBaseSeconds
    BackoffCapSeconds       = $BackoffCapSeconds
    MaxRateLimitWaitSeconds = $MaxRateLimitWaitSeconds
    MaxBytes                = $MaxBytes
}
$script:RuleCache = @{}
$script:Audit = [System.IO.StreamWriter]::new($auditPath, $false, [System.Text.UTF8Encoding]::new($false))
$script:Audit.AutoFlush = $true
$script:Counts = [ordered]@{
    inputLines = 0; invalid = 0; filteredOut = 0; superseded = 0; uniquePullRequests = 0; selected = 0
    processed = 0; stored = 0; ignored = 0; accepted = 0; dryRunValid = 0; skipped = 0
    fallbackV1 = 0; rejected = 0; failed = 0; retries = 0
}

#endregion

#region GitHub

function Test-TransportError {
    param([System.Exception]$Exception)

    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.Net.Http.HttpRequestException] -or $current -is [System.TimeoutException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException]) { return $true }
    }
    return $false
}

function Get-ResponseHeader {
    param($Response, [string]$Name)

    if ($null -eq $Response) { return $null }
    try {
        if ($Response.Headers.ContainsKey($Name)) { return [string]@($Response.Headers[$Name])[0] }
    }
    catch { return $null }
    return $null
}

# GET against the GitHub API with transient-failure retries and rate-limit waits. Returns Status and Content.
function Invoke-GitHubGet {
    param([Parameter(Mandatory)][string]$Path)

    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($script:GitHubToken) { $headers['Authorization'] = "Bearer $($script:GitHubToken)" }

    $attempt = 0
    $rateLimitWaits = 0
    while ($true) {
        $attempt++
        $status = 0
        $content = ''
        $response = $null
        try {
            $response = Invoke-WebRequest -Uri "$($script:GitHubBase)$Path" -Headers $headers -Method Get `
                -UserAgent 'mmo-cr-legacy-migration' -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
            $status = [int]$response.StatusCode
            $content = [string]$response.Content
        }
        catch { if (-not (Test-TransportError -Exception $_.Exception)) { throw } }

        if ($status -eq 401) { Exit-Migration 'GitHub rejected the credential (HTTP 401). Check GITHUB_TOKEN.' }

        if ($status -eq 403 -or $status -eq 429) {
            $wait = Get-GitHubRateLimitWaitSecond -RetryAfter (Get-ResponseHeader $response 'Retry-After') `
                -RateLimitRemaining (Get-ResponseHeader $response 'X-RateLimit-Remaining') `
                -RateLimitReset (Get-ResponseHeader $response 'X-RateLimit-Reset')
            if ($null -ne $wait -and $rateLimitWaits -lt 5) {
                if ($wait -gt $script:Settings.MaxRateLimitWaitSeconds) {
                    Exit-Migration "GitHub rate limit is exhausted and clears in $([int]$wait) seconds, beyond -MaxRateLimitWaitSeconds."
                }
                $rateLimitWaits++
                Write-Host "  GitHub rate limit reached; waiting $([int][math]::Ceiling($wait)) second(s)."
                Start-Sleep -Milliseconds ([int]([math]::Ceiling($wait) * 1000))
                continue
            }
        }

        if (($status -eq 0 -or $status -ge 500) -and $attempt -lt 3) {
            Start-Sleep -Milliseconds ([int](1000 * (Get-RetryDelaySecond -Attempt $attempt -BaseSeconds $script:Settings.BackoffBaseSeconds -CapSeconds $script:Settings.BackoffCapSeconds)))
            continue
        }
        return [pscustomobject]@{ Status = $status; Content = $content }
    }
}

# The .analyticsignore and .analyticstests globs at the target branch; $null when GitHub cannot say.
function Get-RepositoryRule {
    param([string]$RepositoryName, [AllowNull()][string]$TargetBranch)

    $ref = ([string]$TargetBranch) -replace '^refs/heads/', ''
    $cacheKey = "$RepositoryName@$ref"
    if ($script:RuleCache.ContainsKey($cacheKey)) { return $script:RuleCache[$cacheKey] }

    $query = if ($ref.Trim()) { "?ref=$([System.Uri]::EscapeDataString($ref))" } else { '' }
    $texts = @{}
    foreach ($name in @('.analyticsignore', '.analyticstests')) {
        $response = Invoke-GitHubGet -Path "/repos/$RepositoryName/contents/$name$query"
        if ($response.Status -eq 404) { $texts[$name] = ''; continue }
        if ($response.Status -ne 200) { return $null }
        try {
            $document = ConvertFrom-JsonLine -Line $response.Content
            if ((Get-LegacyField $document 'encoding') -ne 'base64') { return $null }
            $texts[$name] = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string](Get-LegacyField $document 'content')))
        }
        catch { return $null }
    }

    $rule = [pscustomobject]@{
        Ignore = @(ConvertFrom-AnalyticsRuleText -Text $texts['.analyticsignore'])
        Test   = @(ConvertFrom-AnalyticsRuleText -Text $texts['.analyticstests'])
    }
    $script:RuleCache[$cacheKey] = $rule
    return $rule
}

function Get-PullEnrichment {
    param([string]$RepositoryName, [int64]$PrNumber, [AllowNull()][string]$TargetBranch)

    $fail = { param($reason) [pscustomobject]@{ Ok = $false; Reason = $reason; Title = $null; Files = $null } }

    $pull = Invoke-GitHubGet -Path "/repos/$RepositoryName/pulls/$PrNumber"
    if ($pull.Status -ne 200) { return & $fail "pull-http-$($pull.Status)" }
    try { $title = [string](Get-LegacyField (ConvertFrom-JsonLine -Line $pull.Content) 'title') }
    catch { return & $fail 'pull-unreadable' }
    if ([string]::IsNullOrWhiteSpace($title)) { return & $fail 'pull-no-title' }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($page in 1..30) {
        $response = Invoke-GitHubGet -Path "/repos/$RepositoryName/pulls/$PrNumber/files?per_page=100&page=$page"
        if ($response.Status -ne 200) { return & $fail "files-http-$($response.Status)" }
        try { $batch = ConvertFrom-JsonLine -Line $response.Content }
        catch { return & $fail 'files-unreadable' }
        if ($batch -isnot [array]) { return & $fail 'files-unreadable' }
        $entries.AddRange([object[]]$batch)
        if ($batch.Count -lt 100) { break }
    }

    $rule = Get-RepositoryRule -RepositoryName $RepositoryName -TargetBranch $TargetBranch
    if ($null -eq $rule) { return & $fail 'rules-unavailable' }

    $files = ConvertTo-FilesBlockFromPullFile -File $entries.ToArray() -IgnoreGlob $rule.Ignore -TestGlob $rule.Test
    return [pscustomobject]@{ Ok = $true; Reason = $null; Title = $title; Files = $files }
}

#endregion

#region Ingest

function Send-IngestPayload {
    param([byte[]]$Body, [System.Collections.IDictionary]$Payload)

    $buildId = ([string]$Payload['buildId']) -replace '[^A-Za-z0-9._-]', '_'
    $headers = @{
        'x-analytics-label'     = 'copilot-analytics'
        'x-analytics-source'    = 'legacy-migration'
        'x-analytics-event'     = 'manual-backfill'
        'x-analytics-repo'      = [string]$Payload['repository']
        'x-idempotency-key'     = "legacy-pr-$($Payload['prNumber'])-build-$($buildId.Substring(0, [math]::Min(100, $buildId.Length)))"
        'x-analytics-timestamp' = [string]$Payload['calculatedAt']
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $status = 0
        $content = ''
        $retryAfter = $null
        $requestHeaders = $headers.Clone()
        $auth = Get-IngestAuthHeader -SharedToken $ingestToken
        foreach ($name in $auth.Keys) { $requestHeaders[$name] = $auth[$name] }

        try {
            $response = Invoke-WebRequest -Uri $ingestUri -Method Post -Headers $requestHeaders -ContentType 'application/json' `
                -Body $Body -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60
            $status = [int]$response.StatusCode
            $content = [string]$response.Content
            $retryAfter = ConvertFrom-RetryAfter -Value (Get-ResponseHeader $response 'Retry-After')
        }
        catch { if (-not (Test-TransportError -Exception $_.Exception)) { throw } }

        $outcome = Resolve-IngestOutcome -StatusCode $status -Body $content
        if (-not $outcome.Retryable -or $attempt -ge $script:Settings.MaxAttempts) {
            return [pscustomobject]@{ Outcome = $outcome; Status = $status; Attempts = $attempt }
        }

        $delay = Get-RetryDelaySecond -Attempt $attempt -BaseSeconds $script:Settings.BackoffBaseSeconds -CapSeconds $script:Settings.BackoffCapSeconds -RetryAfterSeconds $retryAfter
        Write-Host "  attempt $attempt got $($outcome.Reason); retrying in $delay second(s)."
        Start-Sleep -Milliseconds ([int]($delay * 1000))
    }
}

#endregion

#region Records

function Write-AuditRecord {
    param([System.Collections.IDictionary]$Fields)

    $record = [ordered]@{ at = [DateTime]::UtcNow.ToString('o'); runId = $RunId }
    foreach ($name in $Fields.Keys) { $record[$name] = $Fields[$name] }
    $script:Audit.WriteLine((ConvertTo-Json -InputObject $record -Compress -Depth 4))
}

# Reads one line and returns the identity of its pull request, or a Reason it cannot be used.
function Get-LegacyIdentity {
    param([string]$Line)

    $rejected = { param($reason) [pscustomobject]@{ Reason = $reason; Document = $null; Repository = $null; PrNumber = 0; CalculatedAt = $null } }

    try { $document = ConvertFrom-ExtendedJsonValue -Value (ConvertFrom-JsonLine -Line $Line) }
    catch { return & $rejected 'unreadable-json' }
    if ($document -isnot [System.Collections.IDictionary]) { return & $rejected 'not-an-object' }

    $name = Get-LegacyField $document 'repository'
    if ($name -isnot [string] -or $name -cnotmatch $script:RepositoryPattern -or @($name -split '/') -contains '.' -or @($name -split '/') -contains '..') {
        return & $rejected 'invalid-repository'
    }
    if (-not $name.StartsWith("$($script:Settings.AllowedOwner)/", [StringComparison]::OrdinalIgnoreCase)) { return & $rejected 'repository-owner-not-allowed' }

    $number = ConvertTo-IntegerValue -Value (Get-LegacyField $document 'prNumber')
    if ($number -isnot [int64] -or $number -lt 1) { return & $rejected 'invalid-prNumber' }

    try { $calculatedAt = ConvertFrom-LegacyDate -Value (Get-LegacyField $document 'calculatedAt') }
    catch { return & $rejected 'invalid-calculatedAt' }
    if (-not $calculatedAt) { return & $rejected 'missing-calculatedAt' }

    return [pscustomobject]@{ Reason = $null; Document = $document; Repository = $name; PrNumber = $number; CalculatedAt = $calculatedAt }
}

function Invoke-LegacyRecord {
    param($Identity)

    $outcome = [ordered]@{ outcome = ''; reason = ''; http = $null; attempts = 0; schemaVersion = $null; bytes = $null; errors = @() }
    $document = $Identity.Document

    $version = 2
    $title = ''
    $files = $null
    $enrichment = Get-PullEnrichment -RepositoryName $Identity.Repository -PrNumber $Identity.PrNumber -TargetBranch (Get-LegacyField $document 'targetBranch')
    if ($enrichment.Ok) {
        $title = $enrichment.Title
        $files = $enrichment.Files
    }
    elseif ($script:Settings.OnEnrichmentFailure -eq 'Skip') {
        $outcome['outcome'] = 'skipped'
        $outcome['reason'] = "enrichment-$($enrichment.Reason)"
        return $outcome
    }
    else {
        $version = 1
    }
    $outcome['schemaVersion'] = $version

    try { $payload = ConvertTo-MigratedPayload -Legacy $document -PrTitle $title -Files $files -Version $version -JiraProjectKey $script:Settings.JiraProjectKey }
    catch [System.FormatException] {
        $outcome['outcome'] = 'invalid'
        $outcome['reason'] = $_.Exception.Message
        return $outcome
    }

    $errors = @(Test-MigratedPayload -Payload $payload)
    if ($errors.Count -gt 0) {
        $outcome['outcome'] = 'invalid'
        $outcome['reason'] = 'contract-validation'
        $outcome['errors'] = @($errors | Select-Object -First 10)
        return $outcome
    }

    $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 20 -Compress))
    $outcome['bytes'] = $body.Length
    if ($body.Length -gt $script:Settings.MaxBytes) {
        $outcome['outcome'] = 'invalid'
        $outcome['reason'] = 'payload-too-large'
        return $outcome
    }

    if ($DryRun) {
        $outcome['outcome'] = 'dry-run-valid'
        return $outcome
    }

    $sent = Send-IngestPayload -Body $body -Payload $payload
    $outcome['http'] = $sent.Status
    $outcome['attempts'] = $sent.Attempts
    $script:Counts['retries'] += $sent.Attempts - 1
    $result = $sent.Outcome
    $outcome['reason'] = $result.Reason

    if ($result.Abort) {
        $outcome['outcome'] = 'auth-failed'
    }
    elseif ($result.Success) {
        $outcome['outcome'] = $result.Outcome
        $outcome['reason'] = ''
    }
    elseif ($result.Retryable) {
        $outcome['outcome'] = 'failed'
    }
    else {
        $outcome['outcome'] = 'rejected'
    }
    if ($version -eq 1 -and $result.Success) { $script:Counts['fallbackV1']++ }
    return $outcome
}

function Add-OutcomeCount {
    param([string]$Outcome)

    $key = switch ($Outcome) {
        'stored' { 'stored' }
        'ignored' { 'ignored' }
        'accepted' { 'accepted' }
        'dry-run-valid' { 'dryRunValid' }
        'skipped' { 'skipped' }
        'invalid' { 'invalid' }
        'rejected' { 'rejected' }
        default { 'failed' }
    }
    $script:Counts[$key]++
}

#endregion

#region Run

$startedAt = [DateTime]::UtcNow
$abortReason = $null
$mode = if ($DryRun) { 'dry-run' } else { 'live' }

try {
    Write-Host "Run $RunId ($mode): reading $resolvedInput"
    if (-not $githubToken) { Write-Host 'No GitHub token set: GitHub allows 60 unauthenticated requests an hour.' }

    $newest = @{}
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($resolvedInput)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $script:Counts['inputLines']++

        $identity = Get-LegacyIdentity -Line $line
        if ($identity.Reason) {
            $script:Counts['invalid']++
            Write-AuditRecord ([ordered]@{ line = $lineNumber; outcome = 'invalid'; reason = $identity.Reason })
            continue
        }
        if ($Repository.Count -gt 0 -and $Repository -notcontains $identity.Repository) {
            $script:Counts['filteredOut']++
            continue
        }

        $key = "$($identity.Repository)#$($identity.PrNumber)"
        if ($newest.ContainsKey($key)) {
            $script:Counts['superseded']++
            if ([string]::CompareOrdinal($identity.CalculatedAt, $newest[$key].CalculatedAt) -lt 0) { continue }
        }
        $newest[$key] = [pscustomobject]@{ Line = $lineNumber; CalculatedAt = $identity.CalculatedAt }
    }

    $selected = @($newest.Values | Sort-Object -Property Line)
    $script:Counts['uniquePullRequests'] = $selected.Count
    $selected = @($selected | Select-Object -Skip $SkipRecords)
    if ($MaxRecords -gt 0 -and $selected.Count -gt $MaxRecords) { $selected = @($selected | Select-Object -First $MaxRecords) }
    $script:Counts['selected'] = $selected.Count
    $wanted = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($item in $selected) { [void]$wanted.Add([int]$item.Line) }

    Write-Host "Pass 1: $($script:Counts['inputLines']) line(s), $($script:Counts['uniquePullRequests']) pull request(s), $($script:Counts['superseded']) superseded, $($script:Counts['invalid']) invalid."
    Write-Host "Processing pull requests $($SkipRecords + 1) to $($SkipRecords + $selected.Count) of $($script:Counts['uniquePullRequests'])."

    $lineNumber = 0
    $position = $SkipRecords
    foreach ($line in [System.IO.File]::ReadLines($resolvedInput)) {
        $lineNumber++
        if (-not $wanted.Contains($lineNumber)) { continue }
        $position++
        $timer = [System.Diagnostics.Stopwatch]::StartNew()

        $identity = Get-LegacyIdentity -Line $line
        $outcome = $null
        try {
            if ($identity.Reason) { throw 'The line changed between passes.' }
            $outcome = Invoke-LegacyRecord -Identity $identity
        }
        catch {
            if ($_.Exception.Data['LegacyAbort']) { throw }
            $outcome = [ordered]@{ outcome = 'failed'; reason = "unexpected-error-$($_.Exception.GetType().Name)"; http = $null; attempts = 0; schemaVersion = $null; bytes = $null; errors = @() }
        }
        $script:Counts['processed']++
        Add-OutcomeCount -Outcome $outcome['outcome']

        $auditFields = [ordered]@{
            line = $lineNumber; repository = $identity.Repository; prNumber = $identity.PrNumber
            outcome = $outcome['outcome']; reason = $outcome['reason']; http = $outcome['http']; attempts = $outcome['attempts']
            schemaVersion = $outcome['schemaVersion']; bytes = $outcome['bytes']; durationMs = $timer.ElapsedMilliseconds
        }
        if ($outcome['errors'].Count -gt 0) { $auditFields['errors'] = $outcome['errors'] }
        Write-AuditRecord $auditFields
        Write-Host "[$position/$($script:Counts['uniquePullRequests'])] $($identity.Repository)#$($identity.PrNumber) -> $($outcome['outcome'])$(if ($outcome['reason']) { " ($($outcome['reason']))" })"

        if ($outcome['outcome'] -eq 'auth-failed') {
            Exit-Migration 'The ingest endpoint rejected the credential (HTTP 401). Aborting: check INGEST_TOKEN and that INGEST_ALLOW_SHARED_TOKEN is not false.'
        }
        if (-not $DryRun -and $DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }
}
catch {
    if ($_.Exception.Data['LegacyAbort']) { $abortReason = $_.Exception.Message } else { throw }
}
finally {
    $summary = [ordered]@{
        runId      = $RunId
        mode       = $mode
        startedAt  = $startedAt.ToString('o')
        finishedAt = [DateTime]::UtcNow.ToString('o')
        ingestHost = if ($ingestUri) { $ingestUri.Authority } else { $null }
        skipRecords = $SkipRecords
        maxRecords = $MaxRecords
        aborted    = [bool]$abortReason
        abortReason = $abortReason
        counts     = $script:Counts
    }
    $script:Audit.Dispose()
    Set-Content -Path $summaryPath -Value (ConvertTo-Json -InputObject $summary -Depth 4) -Encoding utf8NoBOM
}

Write-Host ''
Write-Host "Summary: $(($script:Counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
Write-Host "Audit: $auditPath"
Write-Host "Summary file: $summaryPath"

if ($abortReason) { throw $abortReason }
if (-not $DryRun -and ($script:Counts['failed'] + $script:Counts['rejected']) -gt 0) {
    Write-Warning 'Some pull requests were not published. Review the audit file, fix the cause and re-run; delivery is idempotent.'
}
return [pscustomobject]$summary

#endregion
