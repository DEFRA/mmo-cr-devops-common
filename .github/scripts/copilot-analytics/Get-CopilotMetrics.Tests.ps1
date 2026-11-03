BeforeAll {
    $script:collector = Join-Path $PSScriptRoot 'Get-CopilotMetrics.ps1'
    $script:savedEnv = @{}
    foreach ($name in 'GITHUB_OUTPUT', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') {
        $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:GITHUB_OUTPUT = $null
    $env:GIT_AUTHOR_NAME = 'Ada Example'
    $env:GIT_AUTHOR_EMAIL = 'ada@example.com'
    $env:GIT_COMMITTER_NAME = 'Ada Example'
    $env:GIT_COMMITTER_EMAIL = 'ada@example.com'

    function Write-TestFile {
        param([string]$Path, [int]$Count)
        $full = Join-Path $script:repo $Path
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -Path $full -Value (1..$Count | ForEach-Object { "line $_" })
    }

    function Invoke-Git { git -C $script:repo @args | Out-Null }

    $script:repo = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $script:repo | Out-Null
    Invoke-Git init --quiet -b main
    Invoke-Git config commit.gpgsign false

    Write-TestFile 'README.md' 2
    Write-TestFile 'src/server/app.js' 2
    Invoke-Git add -A
    Invoke-Git commit --quiet -m 'Initial commit'

    Invoke-Git checkout --quiet -b 'feature/MMO-7-charts'
    Write-TestFile 'src/server/chart.js' 10
    Write-TestFile 'src/server/chart.test.js' 5
    Write-TestFile 'web/package-lock.json' 100
    Invoke-Git add -A
    Invoke-Git commit --quiet -m 'Add chart' -m 'Copilot-Assisted: true'

    Write-TestFile 'src/client/view.js' 3
    Invoke-Git add -A
    Invoke-Git commit --quiet -m 'Add view' -m 'Refs CR-42'

    Write-TestFile 'src/server/agent.js' 6
    Write-TestFile '.analytics/0123456789ab/summary.json' 1
    Set-Content -Path (Join-Path $script:repo '.analytics/0123456789ab/summary.json') -Value '{"schema":"mmo-attribution/1","id":"0123456789ab","totals":{"aiCompletion":0,"aiChat":0,"aiAgent":4,"aiModified":0,"pasted":0,"typed":2,"untracked":0}}'
    Invoke-Git add -A
    Invoke-Git commit --quiet -m 'Add agent helper'

    Invoke-Git checkout --quiet main
    Write-TestFile 'docs/main-only.md' 20
    Invoke-Git add -A
    Invoke-Git commit --quiet -m 'Main-only change'

    Invoke-Git checkout --quiet 'feature/MMO-7-charts'
    Invoke-Git merge --quiet --no-ff --no-edit main

    $script:head = (git -C $script:repo rev-parse HEAD).Trim()
    $script:base = (git -C $script:repo merge-base main $script:head).Trim()

    function Invoke-Collector {
        param([hashtable]$Extra = @{})
        $out = Join-Path $TestDrive "metrics-$([guid]::NewGuid()).json"
        $arguments = @{
            TargetBranch   = 'main'
            SourceCommitId = $script:head
            BaseCommitId   = $script:base
            PrNumber       = '5'
            SourceBranch   = 'feature/MMO-7-charts'
            BuildId        = 'build-1'
            RepoName       = 'DEFRA/example'
            RepositoryPath = $script:repo
            PrTitle        = 'MMO-7 Add charts'
            OutputPath     = $out
        }
        foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }

        Push-Location
        try { & $script:collector @arguments 6>$null | Out-Null }
        finally { Pop-Location }

        $raw = Get-Content -Path $out -Raw
        if ($env:COPILOT_ANALYTICS_SAMPLE_PATH -and $Extra.Count -eq 0) {
            Copy-Item -Path $out -Destination $env:COPILOT_ANALYTICS_SAMPLE_PATH
        }
        return @{ Raw = $raw; Json = ($raw | ConvertFrom-Json) }
    }

    $script:result = Invoke-Collector
}

AfterAll {
    foreach ($name in $script:savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name])
    }
}

Describe 'Get-CopilotMetrics contract v2' {
    It 'Emits schemaVersion 2 with a live source by default' {
        $script:result.Json.schemaVersion | Should -Be 2
        $script:result.Json.source | Should -Be 'live'
    }

    It 'Emits the PR title' {
        $script:result.Json.prTitle | Should -Be 'MMO-7 Add charts'
    }

    It 'Collects Jira keys from the branch, title and counted commit bodies' {
        @($script:result.Json.jiraKeys) | Should -Be @('CR-42', 'MMO-7')
    }

    It 'Never emits commit bodies' {
        $script:result.Raw | Should -Not -Match 'Refs CR-42'
        $script:result.Raw | Should -Not -Match 'Copilot-Assisted:'
    }

    It 'Counts the net diff split into test, non-test and excluded files' {
        $files = $script:result.Json.files

        $files.changed | Should -Be 3
        $files.linesTouched | Should -Be 19
        $files.testFilesChanged | Should -Be 1
        $files.testLinesTouched | Should -Be 5
        $files.modulesTouched | Should -Be 2
        $files.excluded.filesChanged | Should -Be 1
        $files.excluded.linesTouched | Should -Be 100
    }

    It 'Classifies and attributes by metadata, then trailer, then human' {
        $byClass = @($script:result.Json.commitBreakdown)

        $meta = @($byClass | Where-Object { $_.subject -eq 'Add agent helper' })
        $meta.Count | Should -Be 1
        $meta[0].classification | Should -Be 'Copilot-assisted'
        $meta[0].attribution.source | Should -Be 'extension'
        $meta[0].attribution.aiAgentLines | Should -Be 4
        $meta[0].attribution.typedLines | Should -Be 2
        $meta[0].linesAdded | Should -Be 6

        $trailer = @($byClass | Where-Object { $_.subject -eq 'Add chart' })
        $trailer[0].classification | Should -Be 'Copilot-assisted'
        $trailer[0].attribution.source | Should -Be 'legacy-trailer'

        $human = @($byClass | Where-Object { $_.subject -eq 'Add view' })
        $human[0].classification | Should -Be 'Human-authored'
        $human[0].attribution.source | Should -Be 'extension'
        $human[0].attribution.typedLines | Should -Be $human[0].linesAdded
        $human[0].attribution.aiAgentLines | Should -Be 0

        foreach ($commit in $byClass | Where-Object { $_.classification -eq 'Rebase' }) {
            $commit.attribution.source | Should -Be 'none'
        }
    }

    It 'Excludes .analytics from line counts and from the excluded summary' {
        $script:result.Raw | Should -Not -Match '\.analytics'
        $script:result.Json.files.excluded.filesChanged | Should -Be 1
    }

    It 'Ignores a malformed metadata file and falls back to human' {
        $bad = Join-Path $TestDrive 'bad-repo'
        New-Item -ItemType Directory -Path $bad | Out-Null
        git -C $bad init --quiet -b main
        git -C $bad config commit.gpgsign false
        Set-Content -Path (Join-Path $bad 'a.txt') -Value 'base'
        git -C $bad add -A
        git -C $bad commit --quiet -m 'base'
        git -C $bad checkout --quiet -b feature
        New-Item -ItemType Directory -Path (Join-Path $bad '.analytics/aaaaaaaaaaaa') -Force | Out-Null
        Set-Content -Path (Join-Path $bad '.analytics/aaaaaaaaaaaa/summary.json') -Value '{broken'
        Set-Content -Path (Join-Path $bad 'b.txt') -Value @('one', 'two')
        git -C $bad add -A
        git -C $bad commit --quiet -m 'Add b'
        $headSha = (git -C $bad rev-parse HEAD).Trim()
        $baseSha = (git -C $bad rev-parse main).Trim()

        $result = Invoke-Collector -Extra @{ RepositoryPath = $bad; SourceCommitId = $headSha; BaseCommitId = $baseSha }

        $result.Json.commitBreakdown[0].classification | Should -Be 'Human-authored'
        $result.Json.commitBreakdown[0].attribution.typedLines | Should -Be 2
    }

    It 'Serialises a single Jira key as a JSON array' {
        $single = Invoke-Collector -Extra @{ JiraProjectKeys = 'CR' }

        $single.Raw | Should -Match '"jiraKeys":\["CR-42"\]'
    }

    It 'Serialises no Jira keys as an empty JSON array' {
        $none = Invoke-Collector -Extra @{ JiraProjectKeys = 'NOPE' }

        $none.Raw | Should -Match '"jiraKeys":\[\]'
    }

    It 'Marks a backfill run' {
        (Invoke-Collector -Extra @{ Source = 'backfill' }).Json.source | Should -Be 'backfill'
    }

    It 'Truncates a long title' {
        $long = Invoke-Collector -Extra @{ PrTitle = 'x' * 300 }

        $long.Json.prTitle.Length | Should -Be 256
    }

    It 'Refuses to emit a payload without a title' {
        { Invoke-Collector -Extra @{ PrTitle = '' } } | Should -Throw '*validation failed*'
    }

    It 'Counts paths from .analyticstests as test files' {
        $globs = Join-Path $TestDrive 'analyticstests'
        Set-Content -Path $globs -Value 'src/client/'

        $files = (Invoke-Collector -Extra @{ TestGlobsPath = $globs }).Json.files

        $files.changed | Should -Be 2
        $files.testFilesChanged | Should -Be 2
    }
}

Describe 'Get-CopilotMetrics v2 line verification' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')

        $script:repo2 = Join-Path $TestDrive 'repo2'
        New-Item -ItemType Directory -Path $script:repo2 | Out-Null
        git -C $script:repo2 init --quiet -b main | Out-Null
        git -C $script:repo2 config commit.gpgsign false | Out-Null
        Set-Content -Path (Join-Path $script:repo2 'README.md') -Value 'readme'
        git -C $script:repo2 add -A | Out-Null
        git -C $script:repo2 commit --quiet -m 'Initial commit' | Out-Null
        git -C $script:repo2 checkout --quiet -b feature/v2 | Out-Null

        function Add-V2Commit {
            param([string]$Id, [string]$Subject, [string]$SourcePath, [string]$RecordPath, [string]$WrongFpFor = '', [bool]$WithUsage = $false)

            $lines = 1..4 | ForEach-Object { "line $_" }
            if ($SourcePath) {
                $full = Join-Path $script:repo2 $SourcePath
                New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
                Set-Content -Path $full -Value $lines
            }
            $ai = @()
            foreach ($n in 1..3) {
                $fp = if ("$n" -eq $WrongFpFor) { '00000000' } else { Get-LineFingerprint -Text "line $n" }
                $ai += , @($n, 'a', $fp, 0)
            }
            $record = [ordered]@{
                schema = 'ai-attribution-file/2'; path = $RecordPath; added = 4
                counts = [ordered]@{ aiCompletion = 0; aiChat = 0; aiAgent = 3; aiModified = 0; pasted = 0; typed = 1; untracked = 0 }
                ranges = [ordered]@{ 'ai-agent' = '1-3' }; ai = $ai
            }
            $summary = [ordered]@{
                schema = 'ai-attribution/2'; id = $Id; extensionVersion = '0.2.0'
                totals = [ordered]@{ aiCompletion = 0; aiChat = 0; aiAgent = 3; aiModified = 0; pasted = 0; typed = 1; untracked = 0 }
                fileCount = 1
                signals = [ordered]@{ agentHooks = 'installed'; completionKeys = 'enabled'; usage = $(if ($WithUsage) { 'captured' } else { 'off' }) }
            }
            if ($WithUsage) {
                $summary['usage'] = [ordered]@{
                    source = 'copilot-otel-file'
                    sessions = @([ordered]@{
                            agent = 'GitHub Copilot Chat'
                            models = @([ordered]@{ model = 'claude-sonnet-4.5'; requests = 7; inputTokens = 48211; outputTokens = 3112; cacheReadTokens = 30120; cacheCreationTokens = 0; reasoningTokens = 0 })
                        })
                }
            }
            $folder = Join-Path $script:repo2 ".analytics/$Id"
            New-Item -ItemType Directory -Path (Join-Path $folder 'files/src') -Force | Out-Null
            Set-Content -Path (Join-Path $folder 'summary.json') -Value ($summary | ConvertTo-Json -Depth 8)
            Set-Content -Path (Join-Path $folder "files/$RecordPath.json") -Value ($record | ConvertTo-Json -Depth 8)
            git -C $script:repo2 add -A | Out-Null
            git -C $script:repo2 commit --quiet -m $Subject | Out-Null
        }

        Add-V2Commit -Id 'aaaaaaaaaaaa' -Subject 'Add verified' -SourcePath 'src/good.js' -RecordPath 'src/good.js' -WithUsage $true
        Add-V2Commit -Id 'bbbbbbbbbbbb' -Subject 'Add tampered' -SourcePath 'src/bad.js' -RecordPath 'src/bad.js' -WrongFpFor '2'
        Add-V2Commit -Id 'cccccccccccc' -Subject 'Add missing' -SourcePath 'src/other.js' -RecordPath 'src/gone.js'

        $script:head2 = (git -C $script:repo2 rev-parse HEAD).Trim()
        $script:base2 = (git -C $script:repo2 rev-parse main).Trim()
        $script:v2 = Invoke-Collector -Extra @{ RepositoryPath = $script:repo2; SourceCommitId = $script:head2; BaseCommitId = $script:base2; SourceBranch = 'feature/v2'; PrTitle = 'Verify' }
        $script:v2Commits = @($script:v2.Json.commitBreakdown)
    }

    It 'Counts every listed AI line of a verified commit and passes usage through' {
        $commit = @($script:v2Commits | Where-Object { $_.subject -eq 'Add verified' })[0]

        $commit.classification | Should -Be 'Copilot-assisted'
        $commit.attribution.aiAgentLines | Should -Be 3
        $commit.attribution.typedLines | Should -Be 1
        $commit.attribution.usage.sessions | Should -Be 1
        $commit.attribution.usage.commitsWithUsage | Should -Be 1
        $commit.attribution.usage.models[0].model | Should -Be 'claude-sonnet-4.5'
        $commit.attribution.usage.models[0].inputTokens | Should -Be 48211
    }

    It 'Counts a line whose fingerprint does not match as human-authored' {
        $commit = @($script:v2Commits | Where-Object { $_.subject -eq 'Add tampered' })[0]

        $commit.attribution.aiAgentLines | Should -Be 2
        $commit.attribution.typedLines | Should -Be 2
        $commit.attribution.PSObject.Properties['usage'] | Should -BeNullOrEmpty
    }

    It 'Counts every line as human when the recorded file is not in the commit' {
        $commit = @($script:v2Commits | Where-Object { $_.subject -eq 'Add missing' })[0]

        $commit.classification | Should -Be 'Human-authored'
        $commit.attribution.typedLines | Should -Be 4
        $commit.attribution.aiAgentLines | Should -Be 0
    }
}
