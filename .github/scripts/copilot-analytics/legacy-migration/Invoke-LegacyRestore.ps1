<#
.SYNOPSIS
    Restores the legacy v1 Copilot analytics MongoDB dump into a throwaway local container,
    profiles it, and exports the payloads collection to NDJSON for Publish-LegacyPayloads.ps1.

.DESCRIPTION
    1. Verifies mongorestore and mongoexport exist in -ToolsPath, and that Docker is running.
    2. Starts (or reuses) container copilot-v1-db from mongo:7.0.28, published on 127.0.0.1 only.
    3. Restores <DumpPath>/copilot_analytics/payloads.bson.gz into copilot_analytics.payloads with
       --drop, so a re-run starts clean.
    4. Runs Get-LegacyProfile.js inside the container and writes payloads.ndjson.profile.json.
    5. Exports the collection as relaxed Extended JSON, one document per line, to payloads.ndjson.

    The container has no authentication and listens on loopback only. It holds contributor
    identities (personal data): remove it, and the files in -OutputDirectory, when the migration is
    finished. Nothing in this script logs a value from a document.

.PARAMETER ToolsPath
    Folder containing mongorestore and mongoexport (MongoDB Database Tools).

.PARAMETER DumpPath
    The mongodump output folder; it must contain copilot_analytics/payloads.bson.gz.

.PARAMETER OutputDirectory
    Where payloads.ndjson and payloads.ndjson.profile.json are written. Git-ignored by default.

.PARAMETER ContainerName
    Name of the local MongoDB container.

.PARAMETER HostPort
    Loopback port published for the container (27018 by default, so it never clashes with a
    development MongoDB on 27017).

.PARAMETER Image
    MongoDB image to run.

.PARAMETER Recreate
    Remove an existing container of the same name first. Without it an existing container is
    reused, and the restore replaces the collection inside it.

.EXAMPLE
    ./Invoke-LegacyRestore.ps1

.EXAMPLE
    ./Invoke-LegacyRestore.ps1 -Recreate -OutputDirectory D:\migration\output
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ToolsPath = 'C:\Users\jkuduvar\Downloads\mongodb-tools\bin',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DumpPath = 'C:\workspace\temp\mongodump\copilo_analytics_dump',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')]
    [string]$ContainerName = 'copilot-v1-db',

    [Parameter()]
    [ValidateRange(1024, 65535)]
    [int]$HostPort = 27018,

    [Parameter()]
    [ValidatePattern('^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?$')]
    [string]$Image = 'mongo:7.0.28',

    [Parameter()]
    [switch]$Recreate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$database = 'copilot_analytics'
$collection = 'payloads'
$namespace = "$database.$collection"
$mongoUri = "mongodb://127.0.0.1:$HostPort"
$profileScript = Join-Path $PSScriptRoot 'Get-LegacyProfile.js'
$exportPath = Join-Path $OutputDirectory 'payloads.ndjson'
$profilePath = Join-Path $OutputDirectory 'payloads.ndjson.profile.json'

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message"
}

# Runs a native command; stderr is captured and shown only (truncated) when it fails.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure
    )

    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & $FilePath @ArgumentList 2>$errorFile
        $exitCode = $LASTEXITCODE
        $errorText = (Get-Content -Path $errorFile -Raw -ErrorAction SilentlyContinue)
    }
    finally {
        Remove-Item -Path $errorFile -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = if ($errorText) { $errorText.Trim() } else { '' }
        if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + '...' }
        throw "'$([System.IO.Path]::GetFileName($FilePath))' failed with exit code $exitCode. $detail"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output); Error = [string]$errorText }
}

function Test-PortFree {
    param([int]$Port)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); return $true }
    catch [System.Net.Sockets.SocketException] { return $false }
    finally { $listener.Stop() }
}

function Invoke-Mongosh {
    param([string[]]$Argument, [switch]$AllowFailure)

    $arguments = @('exec', $ContainerName, 'mongosh', '--quiet', '--norc') + $Argument
    return Invoke-Native -FilePath 'docker' -ArgumentList $arguments -AllowFailure:$AllowFailure
}

Write-Step 'Checking prerequisites'

$suffix = if ($IsWindows) { '.exe' } else { '' }
$mongorestore = Join-Path $ToolsPath "mongorestore$suffix"
$mongoexport = Join-Path $ToolsPath "mongoexport$suffix"
foreach ($tool in @($mongorestore, $mongoexport)) {
    if (-not (Test-Path -Path $tool -PathType Leaf)) {
        throw "Required tool '$tool' was not found. Set -ToolsPath to the MongoDB Database Tools bin folder."
    }
    $version = (Invoke-Native -FilePath $tool -ArgumentList @('--version')).Output | Select-Object -First 1
    Write-Host "  $([System.IO.Path]::GetFileName($tool)): $version"
}

$dumpFile = Join-Path (Join-Path $DumpPath $database) "$collection.bson.gz"
if (-not (Test-Path -Path $dumpFile -PathType Leaf)) {
    throw "Dump file '$dumpFile' was not found. -DumpPath must hold a gzip mongodump of the $database database."
}
if (-not (Test-Path -Path $profileScript -PathType Leaf)) {
    throw "Profile script '$profileScript' was not found next to this script."
}
if (-not (Get-Command -Name docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found on the PATH.'
}
$null = Invoke-Native -FilePath 'docker' -ArgumentList @('info', '--format', '{{.ServerVersion}}')
Write-Host '  docker: running'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

Write-Step "Preparing container '$ContainerName' ($Image) on 127.0.0.1:$HostPort"

$existing = @((Invoke-Native -FilePath 'docker' -ArgumentList @('ps', '-a', '--filter', "name=^/$ContainerName`$", '--format', '{{.Names}}')).Output)
if ($existing -contains $ContainerName -and $Recreate) {
    Write-Host '  removing the existing container (-Recreate)'
    $null = Invoke-Native -FilePath 'docker' -ArgumentList @('rm', '-f', $ContainerName)
    $existing = @()
}

if ($existing -contains $ContainerName) {
    $ports = @((Invoke-Native -FilePath 'docker' -ArgumentList @('port', $ContainerName, '27017/tcp') -AllowFailure).Output)
    $running = (Invoke-Native -FilePath 'docker' -ArgumentList @('inspect', '--format', '{{.State.Running}}', $ContainerName)).Output | Select-Object -First 1
    if ($running -ne 'true') {
        $null = Invoke-Native -FilePath 'docker' -ArgumentList @('start', $ContainerName)
        $ports = @((Invoke-Native -FilePath 'docker' -ArgumentList @('port', $ContainerName, '27017/tcp')).Output)
    }
    if ($ports -notcontains "127.0.0.1:$HostPort") {
        throw "Container '$ContainerName' exists but is not published on 127.0.0.1:$HostPort. Re-run with -Recreate."
    }
    Write-Host '  reusing the existing container'
}
else {
    if (-not (Test-PortFree -Port $HostPort)) {
        throw "Port $HostPort on 127.0.0.1 is already in use. Choose another with -HostPort."
    }
    $null = Invoke-Native -FilePath 'docker' -ArgumentList @('run', '-d', '--name', $ContainerName, '-p', "127.0.0.1:${HostPort}:27017", $Image)
    Write-Host '  container started'
}

$ready = $false
foreach ($attempt in 1..60) {
    $ping = Invoke-Mongosh -Argument @('--eval', 'db.adminCommand({ ping: 1 }).ok') -AllowFailure
    if ($ping.ExitCode -eq 0 -and ($ping.Output | Select-Object -First 1) -eq '1') { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) { throw "MongoDB in '$ContainerName' did not become ready within 60 seconds." }
Write-Host '  MongoDB is ready'

Write-Step "Restoring $namespace from $DumpPath"

$restore = Invoke-Native -FilePath $mongorestore -ArgumentList @(
    "--uri=$mongoUri", '--gzip', "--nsInclude=$namespace", '--drop', '--stopOnError', $DumpPath
)
$restore.Error -split '\r?\n' | Where-Object { $_ -match 'restored successfully|failed to restore' } | ForEach-Object { Write-Host "  $_" }

$countResult = Invoke-Mongosh -Argument @($database, '--eval', "db.getCollection('$collection').countDocuments({})")
$documentCount = 0
if (-not [int]::TryParse(($countResult.Output | Select-Object -First 1), [ref]$documentCount) -or $documentCount -lt 1) {
    throw "Restore finished but $namespace holds no documents."
}
Write-Host "  $namespace holds $documentCount document(s)"

Write-Step 'Profiling the collection (counts, dates, types and repository names only)'

$null = Invoke-Native -FilePath 'docker' -ArgumentList @('cp', $profileScript, "${ContainerName}:/tmp/Get-LegacyProfile.js")
$profileResult = Invoke-Mongosh -Argument @($database, '--file', '/tmp/Get-LegacyProfile.js')
$profileJson = ($profileResult.Output -join "`n")
try { $profileData = $profileJson | ConvertFrom-Json -ErrorAction Stop }
catch { throw 'The profile script did not return valid JSON.' }
Set-Content -Path $profilePath -Value $profileJson -Encoding utf8NoBOM

Write-Host "  documents          : $($profileData.documents)"
Write-Host "  unique pull requests: $($profileData.uniquePullRequests)"
Write-Host "  distinct repositories: $($profileData.repositories.distinct) ($($profileData.repositories.malformedNames) malformed name(s))"
Write-Host "  documents over the ingest size limit: $($profileData.limits.documentsOverIngestLimit)"
Write-Host "  profile written to $profilePath"

Write-Step "Exporting $namespace to $exportPath"

$null = Invoke-Native -FilePath $mongoexport -ArgumentList @(
    "--uri=$mongoUri/$database", "--collection=$collection", '--jsonFormat=relaxed', '--type=json', "--out=$exportPath"
)
$lines = 0
foreach ($line in [System.IO.File]::ReadLines($exportPath)) { if ($line.Trim()) { $lines++ } }
if ($lines -ne $documentCount) {
    throw "The export holds $lines line(s) but the collection holds $documentCount document(s)."
}
Write-Host "  exported $lines document(s)"

Write-Host ''
Write-Host 'Done. The export contains personal data: keep it out of source control and delete it, and'
Write-Host "container '$ContainerName' (docker rm -f $ContainerName), once the migration is finished."
