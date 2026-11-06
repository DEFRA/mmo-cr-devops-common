<#
.SYNOPSIS
    Measures how much of the AI-written code in merged pull requests survives
    a number of days after the merge, and writes one record per pull request.

.DESCRIPTION
    For each pull request merged WindowDays ago (within LookbackDays), finds the
    commits it put on the default branch, rebuilds the fingerprints of the AI
    lines recorded in their .analytics metadata, then uses `git blame -w -M` at
    the merge and at the measurement commit to count how many of those lines
    are still present. Lines are matched by fingerprint per file, so it works
    for merge, squash and rebase merges and for metadata format v1 and v2.

    Pull requests whose commits carry no metadata are human-only and skipped.
    Lines moved to another file after the merge count as not surviving.

.PARAMETER Repository
    owner/name of the repository being measured.

.PARAMETER WindowDays
    Days after the merge at which survival is measured.

.PARAMETER LookbackDays
    How many days of merges to consider each run, so a missed run catches up.

.PARAMETER PrNumber
    Measure one pull request (manual run) instead of listing merged ones.

.PARAMETER PullRequestsPath
    JSON array of { number, mergeCommit: { oid }, mergedAt } used instead of
    asking GitHub. For tests and offline runs.

.PARAMETER OutputPath
    Where the JSON array of survival records is written.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Repository,

    [Parameter()]
    [string]$DefaultBranch = 'main',

    [Parameter()]
    [string]$DefaultRef = '',

    [Parameter()]
    [ValidateSet(7, 14, 21, 30)]
    [int]$WindowDays = 21,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int]$LookbackDays = 7,

    [Parameter()]
    [int]$PrNumber = 0,

    [Parameter()]
    [datetime]$Now = [datetime]::UtcNow,

    [Parameter()]
    [string]$RepositoryPath = '',

    [Parameter()]
    [string]$PullRequestsPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# The functions below read these through dynamic scope; listed so analyzers see them used.
$null = $Repository, $DefaultBranch, $DefaultRef, $LookbackDays, $PrNumber, $Now, $PullRequestsPath

. (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')

$script:MaxPullRequests = 200
$script:MaxFiles = 200
$script:MaxSetCommits = 500
$script:MaxRecordBytes = 1048576
$script:MaxSourceBytes = 2097152
$script:EmptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
$script:OriginKey = @{ a = 'aiAgent'; c = 'aiCompletion'; h = 'aiChat' }

function Write-Annotation {
    param([ValidateSet('notice', 'warning', 'error')][string]$Level, [string]$Message)
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::${Level}::$Message" }
    else { Write-Host "[$Level] $Message" }
}

function ConvertTo-UtcDate {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value).UtcDateTime
}

function Get-CandidatePullRequest {
    if ($PullRequestsPath) {
        $raw = Get-Content -Path $PullRequestsPath -Raw | ConvertFrom-Json
    }
    elseif ($PrNumber -gt 0) {
        $raw = gh pr view $PrNumber --repo $Repository --json number, mergeCommit, mergedAt | ConvertFrom-Json
    }
    else {
        $to = $Now.AddDays(-$WindowDays)
        $from = $to.AddDays(-$LookbackDays)
        $search = 'merged:{0}..{1}' -f $from.ToString('yyyy-MM-dd'), $to.ToString('yyyy-MM-dd')
        $raw = gh pr list --repo $Repository --state merged --base $DefaultBranch --limit $script:MaxPullRequests `
            --json number, mergeCommit, mergedAt --search $search | ConvertFrom-Json
    }

    foreach ($item in @($raw | Where-Object { $null -ne $_ -and $null -ne $_.mergeCommit -and $null -ne $_.mergedAt })) {
        [PSCustomObject]@{
            Number   = [int]$item.number
            MergeSha = [string]$item.mergeCommit.oid
            MergedAt = ConvertTo-UtcDate -Value $item.mergedAt
        }
    }
}

# The commits a merged pull request put on the default branch (merge, squash or rebase).
function Get-MergedCommitSet {
    param([string]$Merge)

    $parents = @((git rev-list --parents -n 1 $Merge) -split '\s+' | Where-Object { $_ })
    if ($parents.Count -ge 3) {
        return [PSCustomObject]@{ Commits = @(git rev-list "$Merge^1..$Merge"); Base = $parents[1] }
    }

    # GitHub gives every commit of a rebase-merge the same committer and date.
    $signature = (git log -1 --format='%ce|%cI' $Merge)
    $commits = @($Merge)
    $oldest = $Merge
    for ($i = 0; $i -lt $script:MaxSetCommits; $i++) {
        $parent = @(git rev-parse --verify --quiet "$oldest^") | Select-Object -First 1
        if (-not $parent) { break }
        if ((git log -1 --format='%ce|%cI' $parent) -ne $signature) { break }
        $commits += $parent
        $oldest = $parent
    }
    $base = @(git rev-parse --verify --quiet "$oldest^") | Select-Object -First 1
    return [PSCustomObject]@{ Commits = $commits; Base = $(if ($base) { $base } else { $script:EmptyTree }) }
}

# old path -> new path (or $null when deleted) between two commits.
$script:RenameCache = @{}
function Get-PathChange {
    param([string]$From, [string]$To)

    $key = "$From..$To"
    if (-not $script:RenameCache.ContainsKey($key)) {
        $map = @{}
        foreach ($row in @(git diff --name-status -M $From $To)) {
            $parts = $row -split "`t"
            if ($parts[0] -like 'R*' -and $parts.Count -ge 3) { $map[$parts[1]] = $parts[2] }
            elseif ($parts[0] -eq 'D' -and $parts.Count -ge 2) { $map[$parts[1]] = $null }
        }
        $script:RenameCache[$key] = $map
    }
    return $script:RenameCache[$key]
}

function Resolve-PathAt {
    param([string]$From, [string]$To, [string]$Path)

    if ($From -eq $To) { return $Path }
    $map = Get-PathChange -From $From -To $To
    if ($map.ContainsKey($Path)) { return $map[$Path] }
    return $Path
}

function Get-EmptyPool {
    return [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()
}

function Copy-Pool {
    param($Pool)
    $copy = Get-EmptyPool
    if ($null -eq $Pool) { return $copy }
    foreach ($key in $Pool.Keys) { $copy[$key] = [System.Collections.Generic.List[string]]::new($Pool[$key]) }
    return $copy
}

function Get-PoolWeight {
    param($Pool)
    $total = 0
    foreach ($list in $Pool.Values) { $total += $list.Count }
    return $total
}

# Takes one AI line with this fingerprint out of the pool; returns its origin or $null.
function Use-Pool {
    param($Pool, [string]$Fingerprint)

    $list = $null
    if ($Pool.TryGetValue($Fingerprint, [ref]$list) -and $list.Count -gt 0) {
        $origin = $list[0]
        $list.RemoveAt(0)
        return $origin
    }
    return $null
}

function Get-BlameRow {
    param([string]$Rev, [string]$Path)

    $output = @(git blame --porcelain -w -M $Rev -- $Path 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return ConvertFrom-GitBlame -Lines $output
}

function Measure-PullRequest {
    param($Pr)

    $merge = $Pr.MergeSha
    if ($merge -notmatch '^[0-9a-f]{40}$') {
        Write-Annotation -Level notice -Message "PR #$($Pr.Number): no merge commit; skipped."
        return $null
    }
    $cutoff = $Pr.MergedAt.AddDays($WindowDays)
    if ($cutoff -gt $Now) {
        Write-Annotation -Level notice -Message "PR #$($Pr.Number): not yet $WindowDays days since merge; skipped."
        return $null
    }

    $ref = if ($DefaultRef) { $DefaultRef } else { "origin/$DefaultBranch" }
    $measured = @(git rev-list -1 --first-parent --before="$($cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ'))" $ref 2>$null) | Select-Object -First 1
    if (-not $measured) {
        Write-Annotation -Level notice -Message "PR #$($Pr.Number): no commit on $ref at the measurement date; skipped."
        return $null
    }
    git merge-base --is-ancestor $merge $measured 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Annotation -Level notice -Message "PR #$($Pr.Number): merge commit is not on $ref; skipped."
        return $null
    }

    $set = Get-MergedCommitSet -Merge $merge
    $inSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$set.Commits)

    # AI fingerprints per path (as of the merge), rebuilt from the committed source.
    $pools = @{}
    $schemas = [System.Collections.Generic.HashSet[string]]::new()
    $sawMetadata = $false
    foreach ($commit in $set.Commits) {
        $names = @(git diff-tree --root --no-commit-id -r --name-only --diff-filter=A $commit -- .analytics/)
        foreach ($path in @($names | Where-Object { $_ -match '^\.analytics/[0-9a-f]{12}/summary\.json$' })) {
            $blob = Read-GitBlob -Hash $commit -Path $path -MaxBytes 65536
            if ($blob.Status -ne 'ok') { continue }
            $schema = Get-JsonProperty -Object $(try { $blob.Text | ConvertFrom-Json } catch { $null }) -Name 'schema'
            if ($schema -in $script:AnalyticsSchemas) {
                [void]$schemas.Add([string]$schema)
                $sawMetadata = $true
            }
        }

        $records = @($names | Where-Object { $_ -match '^\.analytics/[0-9a-f]{12}/files/.+\.json$' }) | Select-Object -First $script:AnalyticsMaxFileRecords
        foreach ($path in $records) {
            $blob = Read-GitBlob -Hash $commit -Path $path -MaxBytes $script:MaxRecordBytes
            if ($blob.Status -ne 'ok') { continue }
            $record = ConvertFrom-AnalyticsFileRecord -Json $blob.Text
            if ($null -eq $record) { continue }

            $source = Read-GitBlob -Hash $commit -Path $record['Path'] -MaxBytes $script:MaxSourceBytes
            if ($source.Status -ne 'ok') { continue }
            $lines = [string[]]($source.Text -split "`n")

            $entries = if ($null -ne $record['Ai']) { $record['Ai'] } else { $record['V1'] }
            $finalPath = Resolve-PathAt -From $commit -To $merge -Path $record['Path']
            if (-not $finalPath) { continue }

            foreach ($entry in $entries) {
                if ($entry.Line -gt $lines.Count) { continue }
                $fp = Get-LineFingerprint -Text $lines[$entry.Line - 1].TrimEnd("`r")
                if ($null -eq $fp) { continue }
                if ($entry.Contains('Fp') -and $entry.Fp -cne $fp) { continue }

                if (-not $pools.ContainsKey($finalPath)) { $pools[$finalPath] = Get-EmptyPool }
                if (-not $pools[$finalPath].ContainsKey($fp)) { $pools[$finalPath][$fp] = [System.Collections.Generic.List[string]]::new() }
                $pools[$finalPath][$fp].Add($entry.Origin)
            }
        }
    }

    if (-not $sawMetadata) {
        Write-Annotation -Level notice -Message "PR #$($Pr.Number): no .analytics metadata in its commits (human-authored); skipped."
        return $null
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    $byWeight = @($pools.Keys | Sort-Object { Get-PoolWeight -Pool $pools[$_] } -Descending)
    foreach ($path in $byWeight) { $paths.Add($path) }
    foreach ($path in @(git diff --name-only -M $set.Base $merge -- . ':(exclude).analytics')) {
        if ($path -and -not $paths.Contains($path)) { $paths.Add($path) }
    }
    if ($paths.Count -gt $script:MaxFiles) {
        Write-Annotation -Level notice -Message "PR #$($Pr.Number): $($paths.Count) files; measuring the $($script:MaxFiles) with the most AI lines."
        $paths = [System.Collections.Generic.List[string]]($paths | Select-Object -First $script:MaxFiles)
    }

    $merged = @{ human = 0L; aiAgent = 0L; aiCompletion = 0L; aiChat = 0L }
    $surviving = @{ human = 0L; aiAgent = 0L; aiCompletion = 0L; aiChat = 0L }
    $files = [System.Collections.Generic.List[object]]::new()

    foreach ($path in $paths) {
        $file = @{ path = $path; aiMerged = 0L; aiSurviving = 0L; deleted = $false }

        $pool = Copy-Pool -Pool $pools[$path]
        foreach ($row in (Get-BlameRow -Rev $merge -Path $path)) {
            if (-not $inSet.Contains($row.Sha)) { continue }
            $fp = Get-LineFingerprint -Text $row.Text.TrimEnd("`r")
            if ($null -eq $fp) { continue }
            $origin = Use-Pool -Pool $pool -Fingerprint $fp
            if ($origin) { $merged[$script:OriginKey[$origin]]++; $file.aiMerged++ } else { $merged.human++ }
        }

        $pathAtMeasure = Resolve-PathAt -From $merge -To $measured -Path $path
        if (-not $pathAtMeasure) { $file.deleted = $true }
        else {
            $pool = Copy-Pool -Pool $pools[$path]
            foreach ($row in (Get-BlameRow -Rev $measured -Path $pathAtMeasure)) {
                if (-not $inSet.Contains($row.Sha)) { continue }
                $fp = Get-LineFingerprint -Text $row.Text.TrimEnd("`r")
                if ($null -eq $fp) { continue }
                $origin = Use-Pool -Pool $pool -Fingerprint $fp
                if ($origin) { $surviving[$script:OriginKey[$origin]]++; $file.aiSurviving++ } else { $surviving.human++ }
            }
        }
        $file.aiSurviving = [math]::Min($file.aiSurviving, $file.aiMerged)
        if ($file.aiMerged -gt 0) { $files.Add([ordered]@{ path = $file.path; aiMerged = $file.aiMerged; aiSurviving = $file.aiSurviving; deleted = $file.deleted }) }
    }

    foreach ($key in $merged.Keys) { $surviving[$key] = [math]::Min($surviving[$key], $merged[$key]) }
    $aiMerged = $merged.aiAgent + $merged.aiCompletion + $merged.aiChat
    $aiSurviving = $surviving.aiAgent + $surviving.aiCompletion + $surviving.aiChat
    $stamp = $Now.ToUniversalTime().ToString('o')
    $originPair = { param($key) [ordered]@{ merged = $merged[$key]; surviving = $surviving[$key] } }

    return [ordered]@{
        kind                = 'ai-survival'
        schemaVersion       = 1
        repository          = $Repository
        prNumber            = $Pr.Number
        mergeCommitSha      = $merge
        mergedAt            = $Pr.MergedAt.ToString('o')
        windowDays          = $WindowDays
        measuredAt          = $stamp
        measuredCommitSha   = $measured
        aiLinesMerged       = $aiMerged
        aiLinesSurviving    = $aiSurviving
        humanLinesMerged    = $merged.human
        humanLinesSurviving = $surviving.human
        byOrigin            = [ordered]@{
            aiAgent      = (& $originPair 'aiAgent')
            aiCompletion = (& $originPair 'aiCompletion')
            aiChat       = (& $originPair 'aiChat')
        }
        files               = @($files | Sort-Object { $_['aiMerged'] } -Descending | Select-Object -First $script:MaxFiles)
        metadataSchemas     = @($schemas | Sort-Object)
        calculatedAt        = $stamp
    }
}

$location = if ($RepositoryPath) { $RepositoryPath } else { (Get-Location).Path }
Push-Location -Path $location
try {
    $candidates = @(Get-CandidatePullRequest | Sort-Object Number -Unique | Select-Object -First $script:MaxPullRequests)
    Write-Host "Measuring AI code survival at $WindowDays days for $($candidates.Count) pull request(s)"

    $results = @(foreach ($candidate in $candidates) {
            $record = Measure-PullRequest -Pr $candidate
            if ($null -ne $record) {
                Write-Host "PR #$($candidate.Number): AI $($record.aiLinesSurviving)/$($record.aiLinesMerged) lines survived, human $($record.humanLinesSurviving)/$($record.humanLinesMerged)"
                $record
            }
        })

    $directory = Split-Path -Path $OutputPath -Parent
    if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    ConvertTo-Json -InputObject $results -Depth 8 | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host "Wrote $($results.Count) survival record(s) to $OutputPath"
}
finally {
    Pop-Location
}
