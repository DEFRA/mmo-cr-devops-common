<#
.SYNOPSIS
    Collects GitHub Copilot authorship metrics from the commits contained in a
    pull request and writes the result to a JSON file for publication.

.DESCRIPTION
    The script:
      1. Enumerates every commit in the analysed range.
      2. Classifies each commit as 'Copilot-assisted', 'Human-authored',
         'Rebase' or 'Dependabot'.
      3. Calculates per-commit line volume (added + deleted) using git numstat
         with rename detection, excluding generated / vendored files and any
         path listed in .analyticsignore.
      4. Aggregates commit-based and line-based Copilot rates plus a per
         contributor breakdown, counting ONLY 'Copilot-assisted' and
         'Human-authored' commits.
      5. Writes the metrics object as JSON to -OutputPath.

    Rebase and Dependabot commits are reported in commitBreakdown so a consumer
    can show how many were set aside, but they are excluded from every total in
    summary and contributorBreakdown.

.PARAMETER TargetBranch
    The pull request target branch (with or without the refs/heads/ prefix).

.PARAMETER SourceCommitId
    The head commit SHA of the pull request source branch.

.PARAMETER BaseCommitId
    Optional base commit SHA. When set, the analysed range is
    <BaseCommitId>..<SourceCommitId>. When empty, the range is
    origin/<TargetBranch>..<SourceCommitId>.

.PARAMETER PrNumber
    The pull request number. Must resolve to an integer of 1 or greater.

.PARAMETER SourceBranch
    The pull request source branch (with or without the refs/heads/ prefix).

.PARAMETER BuildId
    The workflow run identifier, recorded in the metrics payload.

.PARAMETER RepoName
    The owner/repository name, recorded in the metrics payload.

.PARAMETER RepositoryPath
    Optional path to the checked-out source repository.

.PARAMETER AnalyticsIgnorePath
    Optional path to an .analyticsignore file. Defaults to .analyticsignore in
    the repository root. Patterns found there are added to the built-in
    exclusions; they never replace them.

.PARAMETER PrMergedAt
    Optional merge timestamp (ISO 8601) written to the payload's prMergedAt
    field. Empty on pre-merge runs.

.PARAMETER OutputPath
    File path the metrics JSON is written to.

.NOTES
    Merge commits are detected structurally by parent count rather than by
    subject text, so a genuine commit whose subject happens to begin with
    "Merge" is not misclassified.

.EXAMPLE
    Get-CopilotMetrics.ps1 -TargetBranch "main" -SourceCommitId "abc123" `
        -PrNumber "42" -SourceBranch "feature/x" -BuildId "1234567890" `
        -RepoName "DEFRA/mmo-cr-external-frontend" -OutputPath "./metrics.json"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetBranch,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceCommitId,

    [Parameter()]
    [string]$BaseCommitId = '',

    [Parameter()]
    [string]$PrNumber = '0',

    [Parameter()]
    [string]$SourceBranch = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BuildId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RepoName,

    [Parameter()]
    [string]$RepositoryPath,

    [Parameter()]
    [string]$AnalyticsIgnorePath,

    [Parameter()]
    [string]$PrMergedAt = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 7.4+ turns a non-zero native exit code into a terminating error
# when ErrorActionPreference is Stop, which GitHub sets for every pwsh step.
# Git exit codes are inspected explicitly below, so opt out of that.
$PSNativeCommandUseErrorActionPreference = $false

# Commit kinds that count toward the published metrics.
$countableClassifications = @('Copilot-assisted', 'Human-authored')

# Standard git-generated merge/rebase subjects. Structural parent-count
# detection catches merge commits; this catches rebase/squash artefacts that
# leave only a subject behind.
$rebaseSubjectPattern = '^(merge (branch|remote-tracking branch|pull request|tag)\b|rebase(d)?\b)'

function Get-Sum {
    param($Items, [string]$Property)
    $sum = 0
    foreach ($item in $Items) { $sum += [int]$item.$Property }
    return $sum
}

function Write-Annotation {
    param([ValidateSet('notice', 'warning', 'error')][string]$Level, [string]$Message)
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::${Level}::$Message"
    }
    else {
        Write-Host "[$Level] $Message"
    }
}

<#
    Converts .analyticsignore entries into git exclude pathspecs.
      "docs/"        -> :(exclude)docs/**    (directory)
      "a/b/c.js"     -> :(exclude)a/b/c.js   (path-anchored)
      "*.min.js"     -> :(exclude)**/*.min.js (matched at any depth)
#>
function ConvertTo-ExcludePathspec {
    param([string]$Entry)

    $value = $Entry.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('#')) { return $null }

    $value = $value.TrimStart('/')
    if ($value.EndsWith('/')) { return ":(exclude)$value**" }
    if ($value.Contains('/')) { return ":(exclude)$value" }
    return ":(exclude)**/$value"
}

if ($RepositoryPath) {
    if (-not (Test-Path -Path $RepositoryPath -PathType Container)) {
        throw "Repository path '$RepositoryPath' does not exist."
    }
    Set-Location -Path $RepositoryPath
}

# Generated / vendored / lock files always excluded: a single lockfile or
# bundle bump is thousands of machine-written lines and would otherwise
# dominate a line-weighted rate.
$excludePaths = [System.Collections.Generic.List[string]]::new()
foreach ($default in @(
        ':(exclude)**/package-lock.json',
        ':(exclude)**/yarn.lock',
        ':(exclude)**/pnpm-lock.yaml',
        ':(exclude)**/*.snap',
        ':(exclude)**/*.min.js',
        ':(exclude)**/*.min.css',
        ':(exclude)**/*.map'
    )) { $excludePaths.Add($default) }

$ignoreFile = if ([string]::IsNullOrWhiteSpace($AnalyticsIgnorePath)) { '.analyticsignore' } else { $AnalyticsIgnorePath }

if (Test-Path -Path $ignoreFile -PathType Leaf) {
    $added = 0
    foreach ($line in (Get-Content -Path $ignoreFile)) {
        $spec = ConvertTo-ExcludePathspec -Entry $line
        if ($spec) {
            $excludePaths.Add($spec)
            $added++
        }
    }
    Write-Host "Applied $added exclusion pattern(s) from $ignoreFile"
}
else {
    Write-Host "No .analyticsignore found at '$ignoreFile'; using built-in exclusions only."
}

$targetBranch = ($TargetBranch -replace '^refs/heads/', '').Trim()
$sourceCommitId = $SourceCommitId.Trim()
$sourceBranch = ($SourceBranch -replace '^refs/heads/', '').Trim()
$buildId = $BuildId.Trim()
$repoName = $RepoName.Trim()
$baseCommitId = $BaseCommitId.Trim()

$prNum = 0
if (-not [int]::TryParse($PrNumber.Trim(), [ref]$prNum) -or $prNum -lt 1) {
    Write-Annotation -Level error -Message "PR number '$PrNumber' is not a positive integer. The consumer requires prNumber >= 1, so nothing will be published."
    throw "Invalid PR number '$PrNumber'."
}

Write-Host "PR #$prNum  |  $sourceBranch -> $targetBranch  |  Build $buildId"

if ([string]::IsNullOrWhiteSpace($baseCommitId)) {
    git fetch --quiet origin $targetBranch
    $commitRange = "origin/$targetBranch..$sourceCommitId"
}
else {
    $commitRange = "$baseCommitId..$sourceCommitId"
}

$commitHashes = @(@(git log $commitRange --format="%H") |
    Where-Object { $_ -match '^[0-9a-f]{40}$' })

if ($commitHashes.Count -eq 0) {
    Write-Annotation -Level warning -Message "No commits found in range [$commitRange]. Nothing to publish."
    exit 0
}

Write-Host "Analysing $($commitHashes.Count) commit(s) in range [$commitRange]"

$commitData = @(foreach ($hash in $commitHashes) {
        $author = (git log -1 --format="%an" $hash).Trim()
        $authorEmail = (git log -1 --format="%ae" $hash).Trim()
        $subject = (git log -1 --format="%s"  $hash).Trim()
        $fullBody = (git log -1 --format="%B"  $hash) -join "`n"
        $parents = @((git log -1 --format="%P" $hash) -split '\s+' | Where-Object { $_ -match '^[0-9a-f]{40}$' })
        $rawCommitted = (git log -1 --format="%cI" $hash).Trim()
        $committedAt = if ($rawCommitted) { [DateTimeOffset]::Parse($rawCommitted).UtcDateTime.ToString('o') } else { '' }
        $rawAuthored = (git log -1 --format="%aI" $hash).Trim()
        $authoredAt = if ($rawAuthored) { [DateTimeOffset]::Parse($rawAuthored).UtcDateTime.ToString('o') } else { '' }

        $isBot = $author -match '(?i)^dependabot(\[bot\]|-preview\[bot\])?$' -or
                 $authorEmail -match '(?i)dependabot'

        # A merge commit's numstat is a combined diff of conflict resolutions,
        # which upstream tooling previously billed as human-authored work.
        $classification =
        if ($parents.Count -ge 2) { 'Rebase' }
        elseif ($subject -imatch $rebaseSubjectPattern) { 'Rebase' }
        elseif ($isBot) { 'Dependabot' }
        elseif ($fullBody -match '(?i)Copilot-Assisted:\s*true') { 'Copilot-assisted' }
        else { 'Human-authored' }

        $linesAdded = 0
        $linesDeleted = 0
        $filesChanged = 0

        $numstat = @(git show $hash --numstat --format="" -M -- . $excludePaths)
        foreach ($line in $numstat) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -lt 3) { continue }
            $filesChanged++
            # Binary files report '-' instead of a numeric count.
            $a = 0; $d = 0
            [void][int]::TryParse($parts[0], [ref]$a)
            [void][int]::TryParse($parts[1], [ref]$d)
            $linesAdded += $a
            $linesDeleted += $d
        }

        [PSCustomObject]@{
            commit         = $hash.Substring(0, 7)
            committedAt    = $committedAt
            authoredAt     = $authoredAt
            author         = $author
            subject        = $subject
            classification = $classification
            filesChanged   = $filesChanged
            linesAdded     = $linesAdded
            linesDeleted   = $linesDeleted
            linesTouched   = $linesAdded + $linesDeleted
            netLines       = $linesAdded - $linesDeleted
        }
    })

$counted = @($commitData | Where-Object { $countableClassifications -contains $_.classification })
$excluded = @($commitData | Where-Object { $countableClassifications -notcontains $_.classification })

if ($excluded.Count -gt 0) {
    $rebaseCount = @($excluded | Where-Object { $_.classification -eq 'Rebase' }).Count
    $botCount = @($excluded | Where-Object { $_.classification -eq 'Dependabot' }).Count
    $excludedLines = Get-Sum $excluded 'linesTouched'
    Write-Host "Excluded $($excluded.Count) commit(s) from metrics: $rebaseCount rebase/merge, $botCount dependabot ($excludedLines line(s) set aside)"
}

if ($counted.Count -eq 0) {
    Write-Annotation -Level warning -Message "All $($commitData.Count) commit(s) in this pull request are rebase/merge or Dependabot commits. There is nothing to measure, so no payload will be published."
    exit 0
}

# git log returns commits newest-first; last element is the oldest.
$firstCommitAt = $counted[-1].committedAt
$lastCommitAt = $counted[0].committedAt
$prCreatedAt = if ($counted[-1].authoredAt) { $counted[-1].authoredAt } else { $counted[-1].committedAt }

$prMergedAtValue = if ([string]::IsNullOrWhiteSpace($PrMergedAt)) {
    ''
}
else {
    $pm = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($PrMergedAt, [ref]$pm)) { $pm.UtcDateTime.ToString('o') } else { $PrMergedAt.Trim() }
}

$total = $counted.Count
$assisted = @($counted | Where-Object { $_.classification -eq 'Copilot-assisted' }).Count
$humanAuthored = $total - $assisted

$assistedLines = Get-Sum (@($counted | Where-Object { $_.classification -eq 'Copilot-assisted' })) 'linesTouched'
$humanAuthoredLines = Get-Sum (@($counted | Where-Object { $_.classification -eq 'Human-authored' })) 'linesTouched'
$totalLines = $assistedLines + $humanAuthoredLines

# Commit-based rate is the primary headline: it matches the granularity of
# the commit-level 'Copilot-Assisted' flag. The line-based rate is secondary
# context and is known to over-state AI (assisted commits skew line-heavy).
$commitRate = if ($total -gt 0) { [math]::Round(($assisted / $total) * 100, 2) } else { 0.0 }
$lineRate = if ($totalLines -gt 0) { [math]::Round(($assistedLines / $totalLines) * 100, 2) } else { 0.0 }

$contributorBreakdown = @(
    $counted |
        Group-Object -Property author |
        ForEach-Object {
            $grp = $_.Group
            [PSCustomObject]@{
                contributor          = $_.Name
                totalCommits         = $grp.Count
                copilotAssisted      = @($grp | Where-Object { $_.classification -eq 'Copilot-assisted' }).Count
                humanAuthored        = @($grp | Where-Object { $_.classification -eq 'Human-authored' }).Count
                linesAdded           = Get-Sum $grp 'linesAdded'
                linesDeleted         = Get-Sum $grp 'linesDeleted'
                linesTouched         = Get-Sum $grp 'linesTouched'
                netLines             = Get-Sum $grp 'netLines'
                copilotAssistedLines = Get-Sum (@($grp | Where-Object { $_.classification -eq 'Copilot-assisted' })) 'linesTouched'
                humanAuthoredLines   = Get-Sum (@($grp | Where-Object { $_.classification -eq 'Human-authored' })) 'linesTouched'
            }
        }
)

# ---------------------------------------------------------------------
# METRIC LEGEND
#   classification          Copilot-assisted | Human-authored | Rebase |
#                           Dependabot. Only the first two are counted.
#   copilotAssistedRate     Commit-based %: assisted / counted commits.
#                           The recommended headline figure.
#   copilotAssistedLineRate Volume-weighted %. Context only - tends to
#                           over-state AI (assisted commits skew line-heavy).
#   linesTouched            added + deleted = diff VOLUME (not rework churn).
#   netLines                added - deleted = net growth of the codebase.
#   Rename detection (-M) is on, so moved files count as ~0. Generated and
#   .analyticsignore'd paths are excluded from line counts.
# ---------------------------------------------------------------------
$metrics = [PSCustomObject]@{
    prNumber             = $prNum
    repository           = $repoName
    sourceBranch         = $sourceBranch
    targetBranch         = $targetBranch
    buildId              = $buildId
    calculatedAt         = [DateTime]::UtcNow.ToString('o')
    prCreatedAt          = $prCreatedAt
    firstCommitAt        = $firstCommitAt
    lastCommitAt         = $lastCommitAt
    prMergedAt           = $prMergedAtValue
    summary              = [PSCustomObject]@{
        totalCommits            = $total
        copilotAssistedCommits  = $assisted
        humanAuthoredCommits    = $humanAuthored
        copilotAssistedRate     = $commitRate
        totalLinesTouched       = $totalLines
        copilotAssistedLines    = $assistedLines
        humanAuthoredLines      = $humanAuthoredLines
        copilotAssistedLineRate = $lineRate
        excludedCommits         = $excluded.Count
        rebaseCommits           = @($excluded | Where-Object { $_.classification -eq 'Rebase' }).Count
        dependabotCommits       = @($excluded | Where-Object { $_.classification -eq 'Dependabot' }).Count
    }
    contributorBreakdown = $contributorBreakdown
    commitBreakdown      = @($commitData)
}

Write-Host ''
Write-Host "Counted commits    : $total  (assisted: $assisted, human-authored: $humanAuthored)"
Write-Host "Copilot rate       : $commitRate%  (commit-based, primary)"
Write-Host "Lines touched      : $totalLines  (assisted: $assistedLines, human-authored: $humanAuthoredLines)"
Write-Host "Copilot line rate  : $lineRate%  (volume-weighted, context only)"
Write-Host "Excluded commits   : $($excluded.Count)"

# --- Pre-emit payload validation ----------------------------------------
$validationErrors = [System.Collections.Generic.List[string]]::new()

foreach ($field in @(
        @{ Name = 'repository'; Value = $metrics.repository }
        @{ Name = 'targetBranch'; Value = $metrics.targetBranch }
        @{ Name = 'buildId'; Value = $metrics.buildId }
        @{ Name = 'prCreatedAt'; Value = $metrics.prCreatedAt }
        @{ Name = 'firstCommitAt'; Value = $metrics.firstCommitAt }
        @{ Name = 'lastCommitAt'; Value = $metrics.lastCommitAt }
    )) {
    if ([string]::IsNullOrWhiteSpace($field.Value)) {
        $validationErrors.Add("$($field.Name) is required and must not be empty.")
    }
}

if ($metrics.prNumber -lt 1) {
    $validationErrors.Add("prNumber must be 1 or greater; got '$($metrics.prNumber)'.")
}

if ($metrics.contributorBreakdown.Count -lt 1) {
    $validationErrors.Add('contributorBreakdown must contain at least one entry.')
}

foreach ($tsField in @(
        @{ Name = 'calculatedAt'; Value = $metrics.calculatedAt }
        @{ Name = 'prCreatedAt'; Value = $metrics.prCreatedAt }
        @{ Name = 'firstCommitAt'; Value = $metrics.firstCommitAt }
        @{ Name = 'lastCommitAt'; Value = $metrics.lastCommitAt }
        @{ Name = 'prMergedAt'; Value = $metrics.prMergedAt }
    )) {
    if (-not [string]::IsNullOrWhiteSpace($tsField.Value)) {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($tsField.Value, [ref]$parsed)) {
            $validationErrors.Add("$($tsField.Name) '$($tsField.Value)' is not a valid ISO 8601 timestamp.")
        }
    }
}

if ($validationErrors.Count -gt 0) {
    foreach ($err in $validationErrors) { Write-Annotation -Level error -Message "Payload validation: $err" }
    throw "Metrics payload validation failed with $($validationErrors.Count) error(s). Nothing was written."
}
# -------------------------------------------------------------------------

$metricsJson = $metrics | ConvertTo-Json -Depth 10 -Compress
Set-Content -Path $OutputPath -Value $metricsJson -Encoding utf8 -NoNewline

Write-Host "Metrics written to $OutputPath ($([math]::Round($metricsJson.Length / 1KB, 1)) KB)"

if ($env:GITHUB_OUTPUT) {
    "metrics-path=$OutputPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "counted-commits=$total" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "excluded-commits=$($excluded.Count)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "should-publish=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
