<#
.SYNOPSIS
    Collects GitHub Copilot authorship metrics from the commits contained in a
    pull request and writes the result to a JSON file for publication.

.DESCRIPTION
    The script:
      1. Enumerates every commit in the analysed range.
      2. Classifies each commit as 'Copilot-assisted', 'Human-authored',
         'Rebase' or 'Dependabot'. A commit that adds valid .analytics
         metadata is classified by it alone (AI lines = Copilot-assisted);
         only a commit without it falls back to the legacy trailer, then human.
      3. Calculates per-commit line volume (added + deleted) using git numstat
         with rename detection, excluding generated / vendored files and any
         path listed in .analyticsignore.
      4. Aggregates commit-based and line-based Copilot rates plus a per
         contributor breakdown, counting ONLY 'Copilot-assisted' and
         'Human-authored' commits.
      5. Builds the contract v2 blocks: PR title, candidate Jira keys, net-diff
         file counts split into test / non-test / excluded, and per-commit
         attribution.
      6. Writes the metrics object as JSON to -OutputPath.

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

.PARAMETER PrTitle
    The pull request title. Untrusted: pass it through an environment
    variable, never by interpolating it into a script.

.PARAMETER Source
    'live' for pull request events, 'backfill' for a manual re-collection.

.PARAMETER JiraProjectKeys
    Optional comma-separated Jira project keys. When set, only keys in those
    projects are emitted and the branch name is matched case-insensitively.

.PARAMETER TestGlobsPath
    Optional path to an .analyticstests file. Defaults to .analyticstests in
    the repository root. Globs found there are added to the built-in test
    globs.

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

    [Parameter()]
    [string]$PrTitle = '',

    [Parameter()]
    [ValidateSet('live', 'backfill')]
    [string]$Source = 'live',

    [Parameter()]
    [string]$JiraProjectKeys = '',

    [Parameter()]
    [string]$TestGlobsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')

$schemaVersion = 2
$maxPrTitleLength = 256
$maxJiraKeys = 50

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
    Totals from the .analytics summaries ADDED by this commit. A folder that
    merely exists in the tree belongs to an earlier commit, so only added
    files count. Returns $null when the commit added no valid summary.

    v2 file records list every AI line with a fingerprint. Each is checked
    against the committed code; lines that do not match are subtracted from the
    totals, so they fall back to human-authored. Also returns Usage (model and
    token counts, or $null) and Mismatched.
#>
function Get-AnalyticsTotal {
    param([string]$Hash)

    $names = @(git diff-tree --root --no-commit-id -r --name-only --diff-filter=A $Hash -- .analytics/)
    $summaryPaths = @($names | Where-Object { $_ -match '^\.analytics/[0-9a-f]{12}/summary\.json$' })
    $recordPaths = @($names | Where-Object { $_ -match '^\.analytics/[0-9a-f]{12}/files/.+\.json$' })

    $summaries = [System.Collections.Generic.List[object]]::new()
    $usages = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $summaryPaths) {
        $blob = Read-GitBlob -Hash $Hash -Path $path -MaxBytes 65536
        if ($blob.Status -ne 'ok') { continue }
        $totals = ConvertFrom-AnalyticsSummary -Json $blob.Text
        if ($null -eq $totals) { continue }
        $summaries.Add($totals)
        $usage = ConvertFrom-AnalyticsUsage -Json $blob.Text
        if ($null -ne $usage) { $usages.Add($usage) }
    }
    if ($summaries.Count -eq 0) { return $null }

    $total = Merge-AnalyticsTotal -Summary $summaries.ToArray()
    $originKey = @{ a = 'aiAgent'; c = 'aiCompletion'; h = 'aiChat' }
    $mismatched = 0

    if ($recordPaths.Count -gt $script:AnalyticsMaxFileRecords) {
        Write-Annotation -Level notice -Message "Commit $($Hash.Substring(0, 7)): $($recordPaths.Count) attribution file records; line verification skipped."
    }
    else {
        foreach ($path in $recordPaths) {
            $blob = Read-GitBlob -Hash $Hash -Path $path -MaxBytes 1048576
            if ($blob.Status -ne 'ok') { continue }
            $record = ConvertFrom-AnalyticsFileRecord -Json $blob.Text
            if ($null -eq $record -or $null -eq $record['Ai']) { continue }

            $source = Read-GitBlob -Hash $Hash -Path $record['Path'] -MaxBytes 2097152
            if ($source.Status -eq 'oversize') { continue }
            $lines = if ($source.Status -eq 'ok') { [string[]]($source.Text -split "`n") } else { $null }

            $result = Test-AnalyticsFileRecord -Record $record -Lines $lines
            foreach ($item in $result['Mismatched']) {
                $mismatched++
                $key = $originKey[$item.Origin]
                $total[$key] = [math]::Max(0, $total[$key] - 1)
                if ($item.Modified) { $total['aiModified'] = [math]::Max(0, $total['aiModified'] - 1) }
            }
        }
    }
    if ($mismatched -gt 0) {
        Write-Annotation -Level warning -Message "Commit $($Hash.Substring(0, 7)): $mismatched recorded AI line(s) did not match the committed code and were counted as human."
    }

    $total['Mismatched'] = $mismatched
    $total['Usage'] = Merge-AnalyticsUsage -Usage $usages.ToArray()
    return $total
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
        ':(exclude)**/*.map',
        ':(exclude).analytics/**'
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

$testGlobs = [System.Collections.Generic.List[string]]::new([string[]]$DefaultTestGlobs)
$testsFile = if ([string]::IsNullOrWhiteSpace($TestGlobsPath)) { '.analyticstests' } else { $TestGlobsPath }

if (Test-Path -Path $testsFile -PathType Leaf) {
    $added = 0
    foreach ($line in (Get-Content -Path $testsFile)) {
        $glob = ConvertTo-GlobPattern -Entry $line
        if ($glob) {
            $testGlobs.Add($glob)
            $added++
        }
    }
    Write-Host "Applied $added test glob(s) from $testsFile"
}

$testIncludePaths = @($testGlobs | ForEach-Object { ":(glob)$_" })
$testExcludePaths = @($testGlobs | ForEach-Object { ":(exclude,glob)$_" })

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
    $diffBase = (git merge-base "origin/$targetBranch" $sourceCommitId | Select-Object -First 1)
}
else {
    $commitRange = "$baseCommitId..$sourceCommitId"
    $diffBase = $baseCommitId
}

$commitHashes = @(@(git log $commitRange --format="%H") |
    Where-Object { $_ -match '^[0-9a-f]{40}$' })

if ($commitHashes.Count -eq 0) {
    Write-Annotation -Level warning -Message "No commits found in range [$commitRange]. Nothing to publish."
    exit 0
}

Write-Host "Analysing $($commitHashes.Count) commit(s) in range [$commitRange]"

# Scanned for Jira keys only; commit bodies are never emitted.
$countedMessages = [System.Collections.Generic.List[string]]::new()

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
        $analyticsTotal = if ($parents.Count -lt 2 -and -not $isBot) { Get-AnalyticsTotal -Hash $hash } else { $null }
        $aiLines = if ($analyticsTotal) { $analyticsTotal['aiCompletion'] + $analyticsTotal['aiChat'] + $analyticsTotal['aiAgent'] } else { 0 }

        # Valid .analytics metadata is authoritative; the trailer applies only without it.
        $classification =
        if ($parents.Count -ge 2) { 'Rebase' }
        elseif ($subject -imatch $rebaseSubjectPattern) { 'Rebase' }
        elseif ($isBot) { 'Dependabot' }
        elseif ($aiLines -gt 0) { 'Copilot-assisted' }
        elseif ($null -eq $analyticsTotal -and (Test-CopilotTrailer -Message $fullBody)) { 'Copilot-assisted' }
        else { 'Human-authored' }

        if ($countableClassifications -contains $classification) { $countedMessages.Add($fullBody) }

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
            attribution    = Get-CommitAttribution -Classification $classification -AnalyticsTotal $(if ($aiLines -gt 0) { $analyticsTotal } else { $null }) -LinesAdded $linesAdded -Usage $(if ($aiLines -gt 0) { $analyticsTotal['Usage'] } else { $null })
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

$prTitleValue = Limit-Text -Text $PrTitle.Trim() -MaximumLength $maxPrTitleLength
$jiraKeys = @(Get-JiraKey -Branch $sourceBranch -Title $prTitleValue -Message $countedMessages.ToArray() `
        -ProjectKey ($JiraProjectKeys -split ',') -Maximum $maxJiraKeys)

# Net diff, not a sum of commits, so rework within the PR is not double-counted.
$testNumstat = @(git diff --numstat -M $diffBase $sourceCommitId -- $testIncludePaths $excludePaths)
$nonTestNumstat = @(git diff --numstat -M $diffBase $sourceCommitId -- . $excludePaths $testExcludePaths)
$allNumstat = @(git diff --numstat -M $diffBase $sourceCommitId -- . ':(exclude).analytics/**')
$files = ConvertTo-FilesBlock -TestLine $testNumstat -NonTestLine $nonTestNumstat -AllLine $allNumstat

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
#   files                   Net PR diff (merge-base..head), split into test,
#                           non-test and excluded. Complexity inputs L, F, M.
#   attribution             Per commit: extension (.analytics metadata, or inferred
#                           100% human) | legacy-trailer | none.
# ---------------------------------------------------------------------
$metrics = [PSCustomObject]@{
    schemaVersion        = $schemaVersion
    source               = $Source
    prNumber             = $prNum
    repository           = $repoName
    prTitle              = $prTitleValue
    jiraKeys             = [string[]]$jiraKeys
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
    files                = $files
}

Write-Host ''
Write-Host "Counted commits    : $total  (assisted: $assisted, human-authored: $humanAuthored)"
Write-Host "Copilot rate       : $commitRate%  (commit-based, primary)"
Write-Host "Lines touched      : $totalLines  (assisted: $assistedLines, human-authored: $humanAuthoredLines)"
Write-Host "Copilot line rate  : $lineRate%  (volume-weighted, context only)"
Write-Host "Excluded commits   : $($excluded.Count)"
Write-Host "Files changed      : $($files.changed) non-test, $($files.testFilesChanged) test, $($files.excluded.filesChanged) excluded"
Write-Host "Jira keys          : $($jiraKeys.Count)"

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

if ([string]::IsNullOrWhiteSpace($metrics.prTitle)) {
    $validationErrors.Add('prTitle is required and must not be empty.')
}

if ($metrics.jiraKeys.Count -gt $maxJiraKeys) {
    $validationErrors.Add("jiraKeys must contain at most $maxJiraKeys entries.")
}

if (@($metrics.jiraKeys | Where-Object { $_ -cnotmatch $JiraKeyContractPattern }).Count -gt 0) {
    $validationErrors.Add('jiraKeys contains an entry that is not a valid Jira issue key.')
}

if (@('live', 'backfill') -cnotcontains $metrics.source) {
    $validationErrors.Add("source must be 'live' or 'backfill'.")
}

$fileCounts = @(
    $files.changed, $files.linesTouched, $files.testFilesChanged, $files.testLinesTouched,
    $files.modulesTouched, $files.excluded.filesChanged, $files.excluded.linesTouched
)
if (@($fileCounts | Where-Object { $_ -lt 0 }).Count -gt 0) {
    $validationErrors.Add('files counts must all be 0 or greater.')
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
