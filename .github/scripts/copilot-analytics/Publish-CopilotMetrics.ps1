<#
.SYNOPSIS
    Publishes a Copilot analytics metrics payload to the dashboard's HTTP
    ingest endpoint.

.DESCRIPTION
    POSTs the metrics JSON to <IngestUrl> authenticated with a GitHub Actions
    OIDC token, alongside labelling headers that identify the
    producer, the triggering event and the logical identity of the payload.

    Retries are safe because the consumer upserts a single document per
    (repository, prNumber) and only replaces it when the incoming calculatedAt
    is strictly newer. Re-sending an identical payload therefore converges on
    the same stored state rather than appending a duplicate.

.PARAMETER IngestUrl
    Ingest endpoint URL. Defaults to the COPILOT_ANALYTICS_INGEST_URL
    environment variable. Must be HTTPS unless it targets localhost.

.PARAMETER MetricsPath
    Path to the metrics JSON file produced by Get-CopilotMetrics.ps1.

.PARAMETER PrNumber
    Pull request number, used to build the idempotency key.

.PARAMETER BuildId
    Workflow run identifier, used to build the idempotency key.

.PARAMETER EventName
    Logical trigger that produced this payload: pr-synchronize, pr-merged or
    manual-backfill.

.PARAMETER MaxBytes
    Reject the payload locally if it exceeds this size, rather than having the
    consumer return 413. Must match INGEST_MAX_PAYLOAD_BYTES.

.PARAMETER MaxAttempts
    Total number of send attempts before giving up.

.NOTES
    Credentials: the job needs `id-token: write` and INGEST_OIDC_AUDIENCE. A
    fresh GitHub Actions OIDC token is requested for every attempt and sent as
    `Authorization: Bearer`. There is no shared-secret fallback; the token is
    never logged.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$IngestUrl = $env:COPILOT_ANALYTICS_INGEST_URL,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MetricsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrNumber,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BuildId,

    [Parameter()]
    [ValidateSet('pr-synchronize', 'pr-merged', 'manual-backfill')]
    [string]$EventName = 'pr-synchronize',

    [Parameter()]
    [int]$MaxBytes = 2097152,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')

function Write-Annotation {
    param([ValidateSet('notice', 'warning', 'error')][string]$Level, [string]$Message)
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::${Level}::$Message"
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

if ([string]::IsNullOrWhiteSpace($IngestUrl)) {
    Write-Annotation -Level warning -Message 'No ingest URL configured (COPILOT_ANALYTICS_INGEST_URL); metrics were collected but not published.'
    exit 0
}

$oidcAvailable = -not [string]::IsNullOrWhiteSpace($env:INGEST_OIDC_TOKEN) -or (
    -not [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -and
    -not [string]::IsNullOrWhiteSpace($env:INGEST_OIDC_AUDIENCE))
if (-not $oidcAvailable) {
    Write-Annotation -Level error -Message 'No ingest credential: grant id-token: write on the calling job. Refusing to send analytics unauthenticated.'
    throw 'Missing ingest credential.'
}

# A token id can be used once at the dashboard, so every attempt asks for a new one.
# (Get-OidcToken lives in CopilotMetrics.Helpers.ps1 and is shared with Publish-AiSurvival.ps1.)

if (-not (Test-Path -Path $MetricsPath -PathType Leaf)) {
    Write-Annotation -Level error -Message "Metrics file '$MetricsPath' does not exist. Did the collection step run?"
    throw "Missing metrics file '$MetricsPath'."
}

$uri = [System.Uri]$IngestUrl
$isLoopback = $uri.IsLoopback
if ($uri.Scheme -ne 'https' -and -not $isLoopback) {
    Write-Annotation -Level error -Message "Ingest URL must use HTTPS (got '$($uri.Scheme)'). Analytics may not be sent over plain HTTP."
    throw 'Refusing to send analytics over an unencrypted connection.'
}

$metricsJson = Get-Content -Path $MetricsPath -Raw
$payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($metricsJson)

if ($payloadBytes -gt $MaxBytes) {
    Write-Annotation -Level error -Message "Payload is $payloadBytes bytes, above the $MaxBytes byte limit the ingest endpoint accepts. Add noisy paths to .analyticsignore to reduce it."
    throw 'Payload exceeds the maximum accepted size.'
}

$metrics = $metricsJson | ConvertFrom-Json
$idempotencyKey = "pr-$($PrNumber.Trim())-build-$($BuildId.Trim())"

# ConvertFrom-Json coerces ISO-8601 strings to [datetime], which would render
# in the host's culture and lose the offset. Force it back to round-trip form.
$calculatedAt = if ($metrics.calculatedAt -is [datetime]) {
    $metrics.calculatedAt.ToUniversalTime().ToString('o')
}
else {
    [string]$metrics.calculatedAt
}

$headers = @{
    'x-analytics-label'     = 'copilot-analytics'
    'x-analytics-source'    = 'github-actions'
    'x-analytics-event'     = $EventName
    'x-analytics-repo'      = $metrics.repository
    'x-idempotency-key'     = $idempotencyKey
    'x-analytics-timestamp' = $calculatedAt
}

Write-Host "Publishing to $($uri.GetLeftPart([System.UriPartial]::Path))"
Write-Host "  label      : copilot-analytics"
Write-Host "  event      : $EventName"
Write-Host "  idempotency: $idempotencyKey"
Write-Host "  timestamp  : $calculatedAt"
Write-Host "  size       : $payloadBytes bytes"

$attempt = 0
while ($true) {
    $attempt++

    try {
        $requestHeaders = $headers.Clone()
        $authHeader = Get-IngestAuthHeader -OidcToken (Get-OidcToken)
        foreach ($name in $authHeader.Keys) { $requestHeaders[$name] = $authHeader[$name] }

        $response = Invoke-WebRequest -Uri $IngestUrl -Method Post `
            -Headers $requestHeaders `
            -ContentType 'application/json' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($metricsJson)) `
            -SkipHttpErrorCheck `
            -TimeoutSec 30

        $status = [int]$response.StatusCode

        if ($status -ge 200 -and $status -lt 300) {
            Write-Host "Published successfully (HTTP $status)."
            exit 0
        }

        # 4xx will not resolve by retrying: the payload or token is wrong.
        if ($status -lt 500) {
            $detail = switch ($status) {
                401 { 'the ingest credential was rejected.' }
                403 { 'the repository does not match the token or is not mapped to a project.' }
                413 { 'the endpoint considers the payload too large.' }
                400 { 'the payload failed validation at the consumer.' }
                default { 'the request was rejected.' }
            }
            Write-Annotation -Level error -Message "Ingest returned HTTP $status - $detail"
            Write-Host "Response body: $($response.Content)"
            throw "Ingest rejected the payload with HTTP $status."
        }

        $lastError = "HTTP $status from the ingest endpoint."
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        throw
    }
    catch {
        if ($_.Exception -is [System.Net.Http.HttpRequestException] -or
            $_.Exception -is [System.TimeoutException] -or
            $_.Exception -is [System.Threading.Tasks.TaskCanceledException]) {
            $lastError = $_.Exception.Message
        }
        else {
            throw
        }
    }

    if ($attempt -ge $MaxAttempts) {
        Write-Annotation -Level error -Message "Failed to publish after $attempt attempt(s): $lastError"
        throw "Failed to publish Copilot analytics: $lastError"
    }

    $delay = [math]::Pow(2, $attempt)
    Write-Annotation -Level warning -Message "Attempt $attempt failed ($lastError). Retrying in $delay second(s)."
    Start-Sleep -Seconds $delay
}
