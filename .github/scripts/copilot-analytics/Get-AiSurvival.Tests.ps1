BeforeAll {
    $script:survival = Join-Path $PSScriptRoot 'Get-AiSurvival.ps1'
    . (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')

    $script:saved = @{}
    foreach ($name in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE') {
        $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    $script:repo = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $script:repo | Out-Null

    function Save-Commit {
        param([string]$Message, [string]$Date, [string]$Email = 'ada@example.com')
        $env:GIT_AUTHOR_NAME = 'Ada Example'
        $env:GIT_AUTHOR_EMAIL = 'ada@example.com'
        $env:GIT_COMMITTER_NAME = 'Ada Example'
        $env:GIT_COMMITTER_EMAIL = $Email
        $env:GIT_AUTHOR_DATE = $Date
        $env:GIT_COMMITTER_DATE = $Date
        git -C $script:repo add -A | Out-Null
        git -C $script:repo commit --quiet -m $Message | Out-Null
    }

    function Write-Source {
        param([string]$Path, [string[]]$Lines)
        $full = Join-Path $script:repo $Path
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -Path $full -Value $Lines
    }

    function Add-AnalyticsFolder {
        param([string]$Id, [string]$Path, [int[]]$AiLines, [string]$Origin = 'a', [switch]$V1)

        $lines = @(Get-Content -Path (Join-Path $script:repo $Path))
        $folder = Join-Path $script:repo ".analytics/$Id"
        $recordPath = Join-Path $folder "files/$Path.json"
        New-Item -ItemType Directory -Path (Split-Path $recordPath) -Force | Out-Null

        if ($V1) {
            $record = [ordered]@{ schema = 'mmo-attribution-file/1'; path = $Path; added = $lines.Count; counts = @{}; ranges = [ordered]@{ 'ai-agent' = ($AiLines -join ',') } }
            $summary = [ordered]@{ schema = 'mmo-attribution/1'; id = $Id; totals = @{} }
        }
        else {
            $ai = @()
            foreach ($n in $AiLines) { $ai += , @($n, $Origin, (Get-LineFingerprint -Text $lines[$n - 1]), 0) }
            $record = [ordered]@{ schema = 'ai-attribution-file/2'; path = $Path; added = $lines.Count; counts = @{}; ranges = @{}; ai = $ai }
            $summary = [ordered]@{ schema = 'ai-attribution/2'; id = $Id; totals = @{} }
        }
        Set-Content -Path (Join-Path $folder 'summary.json') -Value ($summary | ConvertTo-Json -Depth 6)
        Set-Content -Path $recordPath -Value ($record | ConvertTo-Json -Depth 8)
    }

    function Get-Head { (git -C $script:repo rev-parse HEAD).Trim() }

    git -C $script:repo init --quiet -b main | Out-Null
    git -C $script:repo config commit.gpgsign false | Out-Null
    Write-Source -Path 'README.md' -Lines @('readme')
    Save-Commit -Message 'Initial commit' -Date '2026-01-01T10:00:00+0000'

    # PR 1: merge commit, two feature commits.
    git -C $script:repo checkout --quiet -b pr1 | Out-Null
    Write-Source -Path 'src/a.js' -Lines (1..10 | ForEach-Object { "a$_" })
    Add-AnalyticsFolder -Id 'aaaaaaaaaaaa' -Path 'src/a.js' -AiLines (1..6)
    Save-Commit -Message 'Add a' -Date '2026-01-05T10:00:00+0000'
    Write-Source -Path 'src/b.js' -Lines @('b1', 'b2', 'b3')
    Add-AnalyticsFolder -Id 'bbbbbbbbbbbb' -Path 'src/b.js' -AiLines (1..3) -Origin 'c'
    Save-Commit -Message 'Add b' -Date '2026-01-06T10:00:00+0000'
    git -C $script:repo checkout --quiet main | Out-Null
    Write-Source -Path 'README.md' -Lines @('readme', 'more')
    Save-Commit -Message 'Main work' -Date '2026-01-08T10:00:00+0000'
    $env:GIT_COMMITTER_DATE = '2026-01-10T12:00:00+0000'
    $env:GIT_AUTHOR_DATE = '2026-01-10T12:00:00+0000'
    git -C $script:repo merge --quiet --no-ff --no-edit pr1 | Out-Null
    $script:merge1 = Get-Head

    # After the merge: two AI lines rewritten, one reindented, a file deleted.
    Write-Source -Path 'src/a.js' -Lines @('a1x', 'a2x', '  a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10')
    Save-Commit -Message 'Edit a' -Date '2026-01-12T10:00:00+0000'
    git -C $script:repo rm --quiet src/b.js | Out-Null
    Save-Commit -Message 'Delete b' -Date '2026-01-13T10:00:00+0000'
    Write-Source -Path 'src/a.js' -Lines @('a1x', 'a2x', '  a3', 'a4 late', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10')
    Save-Commit -Message 'Edit a after the window' -Date '2026-02-05T10:00:00+0000'

    # PR 2: squash merge of two commits.
    git -C $script:repo checkout --quiet -b pr2 | Out-Null
    Write-Source -Path 'src/c.js' -Lines @('c1', 'c2', 'c3', 'c4')
    Add-AnalyticsFolder -Id 'cccccccccccc' -Path 'src/c.js' -AiLines (1..4) -Origin 'h'
    Save-Commit -Message 'Add c' -Date '2026-02-08T10:00:00+0000'
    Write-Source -Path 'src/d.js' -Lines @('d1', 'd2')
    Add-AnalyticsFolder -Id 'dddddddddddd' -Path 'src/d.js' -AiLines (1..2)
    Save-Commit -Message 'Add d' -Date '2026-02-09T10:00:00+0000'
    git -C $script:repo checkout --quiet main | Out-Null
    git -C $script:repo merge --quiet --squash pr2 | Out-Null
    Save-Commit -Message 'Squash pr2 (#2)' -Date '2026-02-10T12:00:00+0000' -Email 'noreply@github.com'
    $script:merge2 = Get-Head

    # PR 3: rebase merge, three commits with one committer and date.
    foreach ($n in 1..3) {
        Write-Source -Path "src/e$n.js" -Lines @("e$n-1", "e$n-2")
        Add-AnalyticsFolder -Id ('e' * 11 + "$n") -Path "src/e$n.js" -AiLines 1
        Save-Commit -Message "Rebased $n" -Date '2026-02-12T10:00:00+0000' -Email 'noreply@github.com'
    }
    $script:merge3 = Get-Head

    # PR 4: human only, no metadata.
    Write-Source -Path 'src/h.js' -Lines @('h1')
    Save-Commit -Message 'Human change' -Date '2026-02-14T10:00:00+0000'
    $script:merge4 = Get-Head

    # PR 5: format v1 metadata.
    Write-Source -Path 'src/v1.js' -Lines @('v1', 'v2', 'v3')
    Add-AnalyticsFolder -Id 'fffffffffff1' -Path 'src/v1.js' -AiLines 1, 2 -V1
    Save-Commit -Message 'Old format' -Date '2026-02-16T10:00:00+0000'
    $script:merge5 = Get-Head

    # Whitespace-only change to a squashed AI line, inside PR 2's window.
    Write-Source -Path 'src/c.js' -Lines @('    c1', 'c2', 'c3', 'c4')
    Save-Commit -Message 'Reindent c' -Date '2026-03-01T10:00:00+0000'

    function Get-SurvivalOutput {
        param([hashtable]$Extra = @{})
        $list = Join-Path $TestDrive "prs-$([guid]::NewGuid()).json"
        $out = Join-Path $TestDrive "survival-$([guid]::NewGuid()).json"
        $prs = @(
            @{ number = 1; mergeCommit = @{ oid = $script:merge1 }; mergedAt = '2026-01-10T12:00:00Z' }
            @{ number = 2; mergeCommit = @{ oid = $script:merge2 }; mergedAt = '2026-02-10T12:00:00Z' }
            @{ number = 3; mergeCommit = @{ oid = $script:merge3 }; mergedAt = '2026-02-12T10:00:00Z' }
            @{ number = 4; mergeCommit = @{ oid = $script:merge4 }; mergedAt = '2026-02-14T10:00:00Z' }
            @{ number = 5; mergeCommit = @{ oid = $script:merge5 }; mergedAt = '2026-02-16T10:00:00Z' }
            @{ number = 6; mergeCommit = @{ oid = $script:merge5 }; mergedAt = '2026-03-30T10:00:00Z' }
            @{ number = 7; mergeCommit = $null; mergedAt = '2026-01-10T12:00:00Z' }
        )
        Set-Content -Path $list -Value (ConvertTo-Json -InputObject $prs -Depth 4)
        $arguments = @{
            Repository       = 'DEFRA/example'
            DefaultRef       = 'main'
            Now              = [datetime]::Parse('2026-04-01T00:00:00Z').ToUniversalTime()
            RepositoryPath   = $script:repo
            PullRequestsPath = $list
            OutputPath       = $out
        }
        foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
        & $script:survival @arguments 6>$null | Out-Null
        return @(Get-Content -Path $out -Raw | ConvertFrom-Json)
    }

    $script:records = Get-SurvivalOutput
    $script:byPr = @{}
    foreach ($record in $script:records) { $script:byPr[[int]$record.prNumber] = $record }
}

AfterAll {
    foreach ($name in $script:saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:saved[$name])
    }
}

Describe 'Get-AiSurvival' {
    It 'Measures merged AI pull requests and skips human-only, too-recent and merge-less ones' {
        ($script:records | ForEach-Object { [int]$_.prNumber } | Sort-Object) | Should -Be @(1, 2, 3, 5)
    }

    It 'Counts rewritten and deleted AI lines but not reindented ones or edits after the window' {
        $r = $script:byPr[1]

        $r.kind | Should -Be 'ai-survival'
        $r.mergeCommitSha | Should -Be $script:merge1
        $r.windowDays | Should -Be 21
        $r.aiLinesMerged | Should -Be 9
        $r.aiLinesSurviving | Should -Be 4
        $r.humanLinesMerged | Should -Be 4
        $r.humanLinesSurviving | Should -Be 4
        $r.byOrigin.aiAgent.merged | Should -Be 6
        $r.byOrigin.aiAgent.surviving | Should -Be 4
        $r.byOrigin.aiCompletion.merged | Should -Be 3
        $r.byOrigin.aiCompletion.surviving | Should -Be 0
        $r.metadataSchemas | Should -Be @('ai-attribution/2')
    }

    It 'Reports per-file counts including deletions' {
        $files = @($script:byPr[1].files)

        $a = $files | Where-Object { $_.path -eq 'src/a.js' }
        $b = $files | Where-Object { $_.path -eq 'src/b.js' }
        $a.aiMerged | Should -Be 6
        $a.aiSurviving | Should -Be 4
        $a.deleted | Should -BeFalse
        $b.aiMerged | Should -Be 3
        $b.aiSurviving | Should -Be 0
        $b.deleted | Should -BeTrue
    }

    It 'Measures at the last default-branch commit within the window' {
        $expected = (git -C $script:repo log main --first-parent --before='2026-01-31T12:00:00Z' -1 --format=%H).Trim()

        $script:byPr[1].measuredCommitSha | Should -Be $expected
    }

    It 'Measures a squash merge from the fingerprints of the squashed commits' {
        $r = $script:byPr[2]

        $r.aiLinesMerged | Should -Be 6
        $r.aiLinesSurviving | Should -Be 6
        $r.byOrigin.aiChat.merged | Should -Be 4
        $r.byOrigin.aiAgent.merged | Should -Be 2
        $r.humanLinesMerged | Should -Be 0
    }

    It 'Groups the commits of a rebase merge by committer and date' {
        $r = $script:byPr[3]

        $r.aiLinesMerged | Should -Be 3
        $r.aiLinesSurviving | Should -Be 3
        $r.humanLinesMerged | Should -Be 3
        $r.humanLinesSurviving | Should -Be 3
    }

    It 'Reads format v1 metadata by recomputing fingerprints' {
        $r = $script:byPr[5]

        $r.aiLinesMerged | Should -Be 2
        $r.aiLinesSurviving | Should -Be 2
        $r.humanLinesMerged | Should -Be 1
        $r.metadataSchemas | Should -Be @('mmo-attribution/1')
    }

    It 'Never reports more surviving than merged and stamps the measurement time' {
        foreach ($r in $script:records) {
            $r.aiLinesSurviving | Should -BeLessOrEqual $r.aiLinesMerged
            $r.humanLinesSurviving | Should -BeLessOrEqual $r.humanLinesMerged
            ([datetime]$r.measuredAt).ToUniversalTime().Year | Should -Be 2026
        }
    }

    It 'Writes an empty array when nothing qualifies' {
        $out = Join-Path $TestDrive 'empty.json'
        $list = Join-Path $TestDrive 'none.json'
        Set-Content -Path $list -Value '[]'

        & $script:survival -Repository 'DEFRA/example' -DefaultRef main -RepositoryPath $script:repo -PullRequestsPath $list -OutputPath $out 6>$null | Out-Null

        (Get-Content -Path $out -Raw).Trim() | Should -Be '[]'
    }
}
