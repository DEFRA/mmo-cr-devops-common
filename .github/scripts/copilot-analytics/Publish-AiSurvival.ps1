<#
.SYNOPSIS
    Publishes AI code survival records to the dashboard's survival ingest
    endpoint, one request per record.

.DESCRIPTION
    Reads the JSON array written by Get-AiSurvival.ps1 and POSTs each record,
    authenticated with a fresh GitHub Actions OIDC token per attempt. Retries
    are safe: the backend upserts one record per (repository, prNumber,
    windowDays) and only replaces it with a newer measurement.

    One failed record does not stop the rest. The script throws only when every
    record failed, so a transient problem with one pull request cannot hide
    the others.

.PARAMETER IngestUrl
    Survival endpoint, for example https://<dashboard>/api/ingest/survival.
    Must be HTTPS unless it targets localhost.

.PARAMETER InputPath
    JSON array of survival records.

.PARAMETER MaxAttempts
    Total send attempts per record before giving up on it.

.PARAMETER MaxBytes
    Skip a record locally if it exceeds the size the endpoint accepts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IngestUrl,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,

    [Parameter()]
    [int]$MaxBytes = 262144,

    [Parameter()]
    [ValidateRange(0, 60)]
    [int]$RetryDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# Read by Send-Record through dynamic scope; listed so analyzers see them used.
$null = $MaxAttempts, $MaxBytes, $RetryDelaySeconds

. (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')

function Write-Annotation {
    param([ValidateSet('notice', 'warning', 'error')][string]$Level, [string]$Message)
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::${Level}::$Message" }
    else { Write-Host "[$Level] $Message" }
}

if (-not (Test-Path -Path $InputPath -PathType Leaf)) {
    Write-Annotation -Level error -Message "Survival file '$InputPath' does not exist. Did the measurement step run?"
    throw "Missing survival file '$InputPath'."
}

$uri = [System.Uri]$IngestUrl
if ($uri.Scheme -ne 'https' -and -not $uri.IsLoopback) {
    Write-Annotation -Level error -Message "Ingest URL must use HTTPS (got '$($uri.Scheme)')."
    throw 'Refusing to send survival records over an unencrypted connection.'
}

# Raw JSON text per record, so date strings are sent exactly as measured.
$document = [System.Text.Json.JsonDocument]::Parse((Get-Content -Path $InputPath -Raw))
$records = @(foreach ($element in $document.RootElement.EnumerateArray()) {
        $number = 0
        try { $number = $element.GetProperty('prNumber').GetInt32() } catch { $number = 0 }
        [PSCustomObject]@{ Number = $number; Json = $element.GetRawText() }
    })
if ($records.Count -eq 0) {
    Write-Host 'No survival records to publish.'
    exit 0
}

$oidcAvailable = -not [string]::IsNullOrWhiteSpace($env:INGEST_OIDC_TOKEN) -or (
    -not [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -and
    -not [string]::IsNullOrWhiteSpace($env:INGEST_OIDC_AUDIENCE))
if (-not $oidcAvailable) {
    Write-Annotation -Level error -Message 'No OIDC credential: grant id-token: write and set INGEST_OIDC_AUDIENCE. Survival records are never sent with a shared secret.'
    throw 'Missing OIDC credential.'
}

function Send-Record {
    param([string]$Json, [string]$Label)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    if ($bytes.Length -gt $MaxBytes) {
        Write-Annotation -Level error -Message "${Label}: $($bytes.Length) bytes is above the $MaxBytes byte limit; skipped."
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $failure = $null
        try {
            $authHeader = Get-IngestAuthHeader -OidcToken (Get-OidcToken) -SharedToken $null
            $response = Invoke-WebRequest -Uri $IngestUrl -Method Post -Headers $authHeader `
                -ContentType 'application/json' -Body $bytes -SkipHttpErrorCheck -TimeoutSec 30
            $status = [int]$response.StatusCode

            if ($status -ge 200 -and $status -lt 300) {
                Write-Host "${Label}: published (HTTP $status)."
                return $true
            }
            if ($status -lt 500) {
                Write-Annotation -Level error -Message "${Label}: rejected with HTTP $status. $($response.Content)"
                return $false
            }
            $failure = "HTTP $status"
        }
        catch [System.Net.Http.HttpRequestException] { $failure = $_.Exception.Message }
        catch [System.Threading.Tasks.TaskCanceledException] { $failure = $_.Exception.Message }

        if ($attempt -lt $MaxAttempts) {
            Write-Annotation -Level warning -Message "${Label}: attempt $attempt failed ($failure); retrying."
            Start-Sleep -Seconds ($RetryDelaySeconds * $attempt)
        }
        else {
            Write-Annotation -Level error -Message "${Label}: gave up after $attempt attempt(s) ($failure)."
        }
    }
    return $false
}

$succeeded = 0
foreach ($record in $records) {
    if (Send-Record -Json $record.Json -Label "PR #$($record.Number)") { $succeeded++ }
}

Write-Host "Published $succeeded of $($records.Count) survival record(s)."
if ($succeeded -eq 0) { throw 'Every survival record failed to publish.' }
