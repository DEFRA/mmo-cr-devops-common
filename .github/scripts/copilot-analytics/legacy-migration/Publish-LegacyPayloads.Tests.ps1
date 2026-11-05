BeforeAll {
    $script:publish = Join-Path $PSScriptRoot 'Publish-LegacyPayloads.ps1'
    $script:saved = @{}
    foreach ($name in 'INGEST_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN', 'COPILOT_ANALYTICS_INGEST_URL') {
        $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:runCounter = 0
    $script:lastRunId = $null

    # One in-memory server plays both the ingest endpoint and the GitHub API. It records every
    # request and answers from the state the test sets up, or from a queue of scripted responses.
    $script:state = [hashtable]::Synchronized(@{
            Requests    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            IngestQueue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            GitHubQueue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            Pulls       = @{}
            Files       = @{}
            Contents    = @{}
            Ready       = $false
            Listener    = $null
        })

    function Open-TestServer {
        param($State)

        $port = Get-Random -Minimum 20000 -Maximum 40000
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript({
                param($Port, $State)

                function Write-Response($Context, [int]$Status, [string]$Content, $Headers) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
                    $Context.Response.StatusCode = $Status
                    $Context.Response.ContentType = 'application/json'
                    foreach ($name in $Headers.Keys) { $Context.Response.Headers.Add($name, [string]$Headers[$name]) }
                    $Context.Response.ContentLength64 = $bytes.Length
                    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $Context.Response.Close()
                }

                $listener = [System.Net.HttpListener]::new()
                $listener.Prefixes.Add("http://127.0.0.1:$Port/")
                $listener.Start()
                $State.Listener = $listener
                $State.Ready = $true

                while ($listener.IsListening) {
                    try { $context = $listener.GetContext() } catch { break }
                    try {
                        $request = $context.Request
                        $body = [System.IO.StreamReader]::new($request.InputStream, [System.Text.Encoding]::UTF8).ReadToEnd()
                        $path = $request.Url.AbsolutePath
                        [void]$State.Requests.Add(@{
                                Method        = $request.HttpMethod
                                Path          = $path
                                Query         = $request.Url.Query
                                Authorization = $request.Headers['Authorization']
                                IngestToken   = $request.Headers['x-ingest-token']
                                Idempotency   = $request.Headers['x-idempotency-key']
                                Source        = $request.Headers['x-analytics-source']
                                Body          = $body
                            })

                        $scripted = $null
                        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/ingest') {
                            if ($State.IngestQueue.Count -gt 0) { $scripted = $State.IngestQueue.Dequeue() }
                            else { $scripted = @{ Status = 201; Body = '{"status":"stored"}'; Headers = @{} } }
                        }
                        elseif ($path -like '/repos/*') {
                            if ($State.GitHubQueue.Count -gt 0) { $scripted = $State.GitHubQueue.Dequeue() }
                            elseif ($path -match '^/repos/([^/]+/[^/]+)/pulls/(\d+)/files$') {
                                $key = "$($Matches[1])#$($Matches[2])"
                                if ($State.Files.ContainsKey($key)) {
                                    $page = 1
                                    if ($request.Url.Query -match '[?&]page=(\d+)') { $page = [int]$Matches[1] }
                                    $slice = @(@($State.Files[$key]) | Select-Object -Skip (($page - 1) * 100) -First 100)
                                    $scripted = @{ Status = 200; Body = (ConvertTo-Json -InputObject $slice -Compress -Depth 4); Headers = @{} }
                                }
                            }
                            elseif ($path -match '^/repos/([^/]+/[^/]+)/pulls/(\d+)$') {
                                $key = "$($Matches[1])#$($Matches[2])"
                                if ($State.Pulls.ContainsKey($key)) {
                                    $scripted = @{ Status = 200; Body = (ConvertTo-Json -InputObject @{ title = $State.Pulls[$key] } -Compress); Headers = @{} }
                                }
                            }
                            elseif ($path -match '^/repos/([^/]+/[^/]+)/contents/(.+)$') {
                                $key = "$($Matches[1]):$($Matches[2])"
                                if ($State.Contents.ContainsKey($key)) {
                                    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($State.Contents[$key]))
                                    $scripted = @{ Status = 200; Body = (ConvertTo-Json -InputObject @{ encoding = 'base64'; content = $encoded } -Compress); Headers = @{} }
                                }
                            }
                        }
                        if ($null -eq $scripted) { $scripted = @{ Status = 404; Body = '{"message":"Not Found"}'; Headers = @{} } }
                        Write-Response $context $scripted.Status $scripted.Body $scripted.Headers
                    }
                    catch {
                        try { Write-Response $context 500 '{}' @{} } catch { $null = $_ }
                    }
                }
            }).AddArgument($port).AddArgument($State)
        $handle = $shell.BeginInvoke()
        foreach ($i in 1..50) {
            if ($State.Ready) { break }
            Start-Sleep -Milliseconds 100
        }
        return @{ Base = "http://127.0.0.1:$port"; Shell = $shell; Handle = $handle; Runspace = $runspace }
    }

    function Close-TestServer {
        param($Server, $State)

        try { $State.Listener.Close() } catch { $null = $_ }
        if (-not $Server.Handle.AsyncWaitHandle.WaitOne(3000)) { $Server.Shell.Stop() }
        $Server.Shell.Dispose()
        $Server.Runspace.Dispose()
    }

    function Clear-TestState {
        $script:state.Requests.Clear()
        $script:state.IngestQueue.Clear()
        $script:state.GitHubQueue.Clear()
        $script:state.Pulls.Clear()
        $script:state.Files.Clear()
        $script:state.Contents.Clear()
    }

    function Add-PullFixture {
        param([string]$Repository = 'DEFRA/example', [int]$PrNumber = 42, [string]$Title = 'MMO-12 Add charts', [object[]]$Files)

        if (-not $PSBoundParameters.ContainsKey('Files')) {
            $Files = @(
                @{ filename = 'src/app/a.js'; additions = 10; deletions = 2 }
                @{ filename = 'src/app/a.test.js'; additions = 5; deletions = 0 }
                @{ filename = 'package-lock.json'; additions = 100; deletions = 50 }
            )
        }
        $script:state.Pulls["$Repository#$PrNumber"] = $Title
        $script:state.Files["$Repository#$PrNumber"] = $Files
    }

    function Get-LegacyLine {
        param(
            [string]$Repository = 'DEFRA/example',
            [int]$PrNumber = 42,
            [string]$CalculatedAt = '2024-03-05T10:20:30.123Z',
            [string]$BuildId = '1234',
            [scriptblock]$Mutate
        )

        $commit = { param($hash, $subject, $classification, $date) [ordered]@{
                commit = $hash; committedAt = @{ '$date' = $date }; author = 'Alex Example'; subject = $subject
                classification = $classification; filesChanged = 2; linesAdded = 8; linesDeleted = 2; linesTouched = 10; netLines = 6
            } }
        $document = [ordered]@{
            _id                  = @{ '$oid' = '65f0c0ffee0000000000abcd' }
            prNumber             = $PrNumber
            repository           = $Repository
            sourceBranch         = 'feature/MMO-12-charts'
            targetBranch         = 'main'
            buildId              = $BuildId
            calculatedAt         = @{ '$date' = $CalculatedAt }
            prMergedAt           = @{ '$date' = '2024-03-05T10:00:00Z' }
            receivedAt           = @{ '$date' = '2024-03-05T10:21:00Z' }
            projectSlug          = 'internal'
            summary              = [ordered]@{
                totalCommits = 2; copilotAssistedCommits = 1; humanAuthoredCommits = 1; copilotAssistedRate = 50
                totalLinesTouched = 20; copilotAssistedLines = 10; humanAuthoredLines = 10; copilotAssistedLineRate = 50
            }
            contributorBreakdown = @([ordered]@{
                    contributor = 'Alex Example'; totalCommits = 2; copilotAssisted = 1; humanAuthored = 1; linesAdded = 16
                    linesDeleted = 4; linesTouched = 20; netLines = 12; copilotAssistedLines = 10; humanAuthoredLines = 10
                })
            commitBreakdown      = @(
                (& $commit 'aaaa111' 'MMO-12 add chart' 'Copilot-assisted' '2024-03-02T10:00:00Z')
                (& $commit 'bbbb222' 'Fix axis CR-7' 'Human-authored' '2024-03-03T10:00:00Z')
            )
        }
        if ($Mutate) { & $Mutate $document }
        return ConvertTo-Json -InputObject $document -Depth 10 -Compress
    }

    function Write-LegacyFile {
        param([string[]]$Line)

        $path = Join-Path $TestDrive "legacy-$([guid]::NewGuid()).ndjson"
        Set-Content -Path $path -Value $Line -Encoding utf8NoBOM
        return $path
    }

    function Invoke-Publish {
        param([string]$InputFile, [hashtable]$Extra = @{})

        $script:runCounter++
        $script:lastRunId = "test$($script:runCounter)"
        $arguments = @{
            InputPath          = $InputFile
            IngestUrl          = "$($script:server.Base)/api/ingest"
            GitHubApiUrl       = $script:server.Base
            OutputDirectory    = Join-Path $TestDrive 'out'
            RunId              = $script:lastRunId
            DelayMilliseconds  = 0
            BackoffBaseSeconds = 0
        }
        foreach ($name in $Extra.Keys) { $arguments[$name] = $Extra[$name] }
        return & $script:publish @arguments 3>$null 6>$null
    }

    function Get-AuditRecord {
        return , @(Get-Content -Path (Join-Path $TestDrive "out/audit-$($script:lastRunId).jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Get-IngestRequest {
        return , @($script:state.Requests | Where-Object { $_.Path -eq '/api/ingest' })
    }

    $script:server = Open-TestServer -State $script:state
}

AfterAll {
    Close-TestServer -Server $script:server -State $script:state
    foreach ($name in $script:saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:saved[$name])
    }
}

Describe 'Publish-LegacyPayloads' {
    BeforeEach {
        Clear-TestState
        $env:INGEST_TOKEN = 'test-ingest-secret'
        $env:GITHUB_TOKEN = 'test-github-secret'
        $env:GH_TOKEN = $null
        $env:COPILOT_ANALYTICS_INGEST_URL = $null
        Add-PullFixture
    }

    Context 'Publishing a document' {
        It 'Sends one schemaVersion 2 backfill payload built from the legacy document and GitHub' {
            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['stored'] | Should -Be 1
            $requests = Get-IngestRequest
            $requests.Count | Should -Be 1
            $payload = $requests[0].Body | ConvertFrom-Json
            $payload.schemaVersion | Should -Be 2
            $payload.source | Should -Be 'backfill'
            $payload.prTitle | Should -Be 'MMO-12 Add charts'
            $requests[0].Body | Should -Match '"calculatedAt":"2024-03-05T10:20:30.123Z"'
            $payload.buildId | Should -Be '1234'
            $payload.jiraKeys | Should -Be @('CR-7', 'MMO-12')
            $payload.files.changed | Should -Be 1
            $payload.files.linesTouched | Should -Be 12
            $payload.files.testFilesChanged | Should -Be 1
            $payload.files.excluded.filesChanged | Should -Be 1
            $payload.commitBreakdown[0].attribution.source | Should -Be 'legacy-trailer'
            $payload.commitBreakdown[1].attribution.source | Should -Be 'none'
        }

        It 'Never sends Mongo-internal fields' {
            $null = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $body = (Get-IngestRequest)[0].Body
            foreach ($internal in '_id', 'receivedAt', 'projectSlug') { $body | Should -Not -Match $internal }
        }

        It 'Sends the ingest token only to the ingest endpoint and the GitHub token only to GitHub' {
            $null = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $ingest = Get-IngestRequest
            $ingest[0].IngestToken | Should -Be 'test-ingest-secret'
            $ingest[0].Authorization | Should -BeNullOrEmpty
            $ingest[0].Source | Should -Be 'legacy-migration'
            $ingest[0].Idempotency | Should -Be 'legacy-pr-42-build-1234'
            $github = @($script:state.Requests | Where-Object { $_.Path -ne '/api/ingest' })
            $github.Count | Should -BeGreaterThan 0
            foreach ($request in $github) {
                $request.Authorization | Should -Be 'Bearer test-github-secret'
                $request.IngestToken | Should -BeNullOrEmpty
            }
        }

        It 'Applies .analyticsignore and .analyticstests from the target branch' {
            $script:state.Contents['DEFRA/example:.analyticsignore'] = "# generated`r`nsrc/app/generated/"
            $script:state.Contents['DEFRA/example:.analyticstests'] = '*.feature'
            Add-PullFixture -Files @(
                @{ filename = 'src/app/a.js'; additions = 10; deletions = 0 }
                @{ filename = 'src/app/generated/x.js'; additions = 40; deletions = 0 }
                @{ filename = 'e2e/login.feature'; additions = 7; deletions = 0 }
            )

            $null = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $payload = (Get-IngestRequest)[0].Body | ConvertFrom-Json
            $payload.files.changed | Should -Be 1
            $payload.files.testFilesChanged | Should -Be 1
            $payload.files.testLinesTouched | Should -Be 7
            $payload.files.excluded.filesChanged | Should -Be 1
            $payload.files.excluded.linesTouched | Should -Be 40
            $contents = @($script:state.Requests | Where-Object { $_.Path -like '*/contents/*' })
            $contents[0].Query | Should -Match 'ref=main'
        }

        It 'Reads every page of changed files' {
            Add-PullFixture -Files @(1..150 | ForEach-Object { @{ filename = "src/app/file$_.js"; additions = 1; deletions = 0 } })

            $null = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $payload = (Get-IngestRequest)[0].Body | ConvertFrom-Json
            $payload.files.changed | Should -Be 150
            @($script:state.Requests | Where-Object { $_.Path -like '*/files' }).Count | Should -Be 2
        }

        It 'Fetches the repository rules once for every pull request in a repository' {
            Add-PullFixture -PrNumber 43
            $file = Write-LegacyFile -Line @((Get-LegacyLine -PrNumber 42), (Get-LegacyLine -PrNumber 43))

            $null = Invoke-Publish -InputFile $file

            @($script:state.Requests | Where-Object { $_.Path -like '*/contents/.analyticsignore' }).Count | Should -Be 1
        }

        It 'Skips blank lines' {
            $file = Write-LegacyFile -Line @('', (Get-LegacyLine), '   ')

            (Invoke-Publish -InputFile $file).counts['inputLines'] | Should -Be 1
        }
    }

    Context 'Choosing documents' {
        It 'Sends only the newest document for a pull request' {
            $file = Write-LegacyFile -Line @(
                (Get-LegacyLine -CalculatedAt '2024-03-05T10:20:30.123Z' -BuildId 'new')
                (Get-LegacyLine -CalculatedAt '2024-03-01T10:20:30.123Z' -BuildId 'old')
            )

            $result = Invoke-Publish -InputFile $file

            $result.counts['superseded'] | Should -Be 1
            $result.counts['uniquePullRequests'] | Should -Be 1
            $requests = Get-IngestRequest
            $requests.Count | Should -Be 1
            ($requests[0].Body | ConvertFrom-Json).buildId | Should -Be 'new'
        }

        It 'Prefers the later line when calculatedAt ties' {
            $file = Write-LegacyFile -Line @((Get-LegacyLine -BuildId 'first'), (Get-LegacyLine -BuildId 'second'))

            $null = Invoke-Publish -InputFile $file

            ((Get-IngestRequest)[0].Body | ConvertFrom-Json).buildId | Should -Be 'second'
        }

        It 'Compares calculatedAt across date shapes' {
            $epoch = [DateTimeOffset]::Parse('2024-04-01T00:00:00Z').ToUnixTimeMilliseconds()
            $file = Write-LegacyFile -Line @(
                (Get-LegacyLine -BuildId 'iso')
                (Get-LegacyLine -BuildId 'epoch' -Mutate { param($d) $d['calculatedAt'] = @{ '$date' = @{ '$numberLong' = "$epoch" } } })
            )

            $null = Invoke-Publish -InputFile $file

            ((Get-IngestRequest)[0].Body | ConvertFrom-Json).buildId | Should -Be 'epoch'
        }

        It 'Keeps different pull requests and repositories apart' {
            Add-PullFixture -PrNumber 43
            Add-PullFixture -Repository 'DEFRA/other'
            $file = Write-LegacyFile -Line @(
                (Get-LegacyLine -PrNumber 42), (Get-LegacyLine -PrNumber 43), (Get-LegacyLine -Repository 'DEFRA/other')
            )

            (Invoke-Publish -InputFile $file).counts['stored'] | Should -Be 3
        }

        It 'Honours -Repository' {
            Add-PullFixture -Repository 'DEFRA/other'
            $file = Write-LegacyFile -Line @((Get-LegacyLine), (Get-LegacyLine -Repository 'DEFRA/other'))

            $result = Invoke-Publish -InputFile $file -Extra @{ Repository = @('DEFRA/other') }

            $result.counts['stored'] | Should -Be 1
            $result.counts['filteredOut'] | Should -Be 1
            ((Get-IngestRequest)[0].Body | ConvertFrom-Json).repository | Should -Be 'DEFRA/other'
        }

        It 'Honours -MaxRecords' {
            Add-PullFixture -PrNumber 43
            $file = Write-LegacyFile -Line @((Get-LegacyLine -PrNumber 42), (Get-LegacyLine -PrNumber 43))

            $result = Invoke-Publish -InputFile $file -Extra @{ MaxRecords = 1 }

            $result.counts['uniquePullRequests'] | Should -Be 2
            $result.counts['selected'] | Should -Be 1
            (Get-IngestRequest).Count | Should -Be 1
        }

        It 'Runs one batch with -SkipRecords and -MaxRecords' {
            Add-PullFixture -PrNumber 43
            Add-PullFixture -PrNumber 44
            $file = Write-LegacyFile -Line @((Get-LegacyLine -PrNumber 42), (Get-LegacyLine -PrNumber 43), (Get-LegacyLine -PrNumber 44))

            $result = Invoke-Publish -InputFile $file -Extra @{ SkipRecords = 1; MaxRecords = 1 }

            $result.counts['uniquePullRequests'] | Should -Be 3
            $result.counts['selected'] | Should -Be 1
            $result.skipRecords | Should -Be 1
            @(Get-IngestRequest).Count | Should -Be 1
            ((Get-IngestRequest)[0].Body | ConvertFrom-Json).prNumber | Should -Be 43
        }

        It 'Records unusable lines and carries on' {
            $file = Write-LegacyFile -Line @(
                'this is not json'
                '[1,2]'
                (Get-LegacyLine -Repository 'someone-else/example')
                (Get-LegacyLine -Repository 'DEFRA/..')
                (Get-LegacyLine -Mutate { param($d) $d['prNumber'] = 0 })
                (Get-LegacyLine -Mutate { param($d) $d.Remove('calculatedAt') })
                (Get-LegacyLine -Mutate { param($d) $d['calculatedAt'] = 'garbage' })
                (Get-LegacyLine -PrNumber 50)
            )
            Add-PullFixture -PrNumber 50

            $result = Invoke-Publish -InputFile $file

            $result.counts['invalid'] | Should -Be 7
            $result.counts['stored'] | Should -Be 1
            @((Get-AuditRecord) | Where-Object { $_.outcome -eq 'invalid' } | ForEach-Object { $_.reason }) | Should -Be @(
                'unreadable-json', 'not-an-object', 'repository-owner-not-allowed', 'invalid-repository', 'invalid-prNumber', 'missing-calculatedAt', 'invalid-calculatedAt'
            )
        }
    }

    Context 'Dry run' {
        It 'Validates without sending and without needing ingest credentials' {
            $env:INGEST_TOKEN = $null

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ DryRun = $true; IngestUrl = $null }

            $result.mode | Should -Be 'dry-run'
            $result.counts['dryRunValid'] | Should -Be 1
            (Get-IngestRequest).Count | Should -Be 0
            (Get-AuditRecord)[0].bytes | Should -BeGreaterThan 100
        }

        It 'Reports an invalid payload' {
            $file = Write-LegacyFile -Line (Get-LegacyLine -Mutate { param($d) $d['commitBreakdown'][0].Remove('author') })

            $result = Invoke-Publish -InputFile $file -Extra @{ DryRun = $true }

            $result.counts['invalid'] | Should -Be 1
            $result.counts['dryRunValid'] | Should -Be 0
        }
    }

    Context 'Validation before sending' {
        It 'Does not send a payload that fails the contract, and logs the rule but not the value' {
            $file = Write-LegacyFile -Line (Get-LegacyLine -Mutate { param($d) $d['commitBreakdown'][0]['author'] = ('a' * 300) })

            $result = Invoke-Publish -InputFile $file

            $result.counts['invalid'] | Should -Be 1
            (Get-IngestRequest).Count | Should -Be 0
            $record = (Get-AuditRecord)[0]
            $record.reason | Should -Be 'contract-validation'
            $record.errors | Should -Contain 'commitBreakdown[0].author must be a string of 1 to 256 characters.'
        }

        It 'Reports an unreadable commit date by field' {
            $file = Write-LegacyFile -Line (Get-LegacyLine -Mutate { param($d) $d['commitBreakdown'][1]['committedAt'] = 'garbage' })

            $result = Invoke-Publish -InputFile $file

            $result.counts['invalid'] | Should -Be 1
            (Get-AuditRecord)[0].reason | Should -BeLike "*commitBreakdown``[1``].committedAt*"
        }

        It 'Refuses a payload over -MaxBytes' {
            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ MaxBytes = 1024 }

            $result.counts['invalid'] | Should -Be 1
            (Get-AuditRecord)[0].reason | Should -Be 'payload-too-large'
            (Get-IngestRequest).Count | Should -Be 0
        }
    }

    Context 'Enrichment failures' {
        It 'Skips a pull request GitHub does not know' {
            $script:state.Pulls.Clear()

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['skipped'] | Should -Be 1
            (Get-AuditRecord)[0].reason | Should -Be 'enrichment-pull-http-404'
            (Get-IngestRequest).Count | Should -Be 0
        }

        It 'Sends a schemaVersion 1 payload with -OnEnrichmentFailure FallbackV1' {
            $script:state.Pulls.Clear()

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ OnEnrichmentFailure = 'FallbackV1' }

            $result.counts['stored'] | Should -Be 1
            $result.counts['fallbackV1'] | Should -Be 1
            $payload = (Get-IngestRequest)[0].Body | ConvertFrom-Json
            $payload.schemaVersion | Should -Be 1
            $payload.PSObject.Properties.Name | Should -Not -Contain 'prTitle'
            $payload.PSObject.Properties.Name | Should -Not -Contain 'files'
            $payload.commitBreakdown[0].PSObject.Properties.Name | Should -Not -Contain 'attribution'
        }

        It 'Skips when the repository rules cannot be read' {
            $script:state.GitHubQueue.Enqueue(@{ Status = 200; Body = '{"title":"MMO-12 Add charts"}'; Headers = @{} })
            $script:state.GitHubQueue.Enqueue(@{ Status = 200; Body = '[]'; Headers = @{} })
            $script:state.GitHubQueue.Enqueue(@{ Status = 403; Body = '{}'; Headers = @{} })

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['skipped'] | Should -Be 1
            (Get-AuditRecord)[0].reason | Should -Be 'enrichment-rules-unavailable'
        }

        It 'Retries a transient GitHub failure' {
            $script:state.GitHubQueue.Enqueue(@{ Status = 503; Body = ''; Headers = @{} })

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['stored'] | Should -Be 1
        }

        It 'Waits out a GitHub rate limit and carries on' {
            $script:state.GitHubQueue.Enqueue(@{ Status = 429; Body = ''; Headers = @{ 'Retry-After' = '0' } })

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['stored'] | Should -Be 1
        }

        It 'Aborts when the rate limit would take longer than -MaxRateLimitWaitSeconds' {
            $script:state.GitHubQueue.Enqueue(@{ Status = 429; Body = ''; Headers = @{ 'Retry-After' = '600' } })

            { Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ MaxRateLimitWaitSeconds = 5 } } | Should -Throw '*rate limit*'
            (Get-IngestRequest).Count | Should -Be 0
        }

        It 'Aborts when GitHub rejects the credential' {
            $script:state.GitHubQueue.Enqueue(@{ Status = 401; Body = ''; Headers = @{} })

            { Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) } | Should -Throw '*GitHub rejected*'
        }
    }

    Context 'Ingest outcomes and retries' {
        It 'Counts an ignored record as success' {
            $script:state.IngestQueue.Enqueue(@{ Status = 201; Body = '{"status":"ignored"}'; Headers = @{} })

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['ignored'] | Should -Be 1
            $result.counts['stored'] | Should -Be 0
        }

        It 'Retries a 503 and then succeeds' {
            $script:state.IngestQueue.Enqueue(@{ Status = 503; Body = ''; Headers = @{} })

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $result.counts['stored'] | Should -Be 1
            $result.counts['retries'] | Should -Be 1
            (Get-IngestRequest).Count | Should -Be 2
            (Get-AuditRecord)[0].attempts | Should -Be 2
        }

        It 'Retries a 429 that carries Retry-After' {
            $script:state.IngestQueue.Enqueue(@{ Status = 429; Body = ''; Headers = @{ 'Retry-After' = '0' } })

            (Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))).counts['stored'] | Should -Be 1
        }

        It 'Resends the same payload on a retry' {
            $script:state.IngestQueue.Enqueue(@{ Status = 502; Body = ''; Headers = @{} })

            $null = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $requests = Get-IngestRequest
            $requests[1].Body | Should -Be $requests[0].Body
        }

        It 'Gives up after -MaxAttempts and records a failure' {
            foreach ($i in 1..3) { $script:state.IngestQueue.Enqueue(@{ Status = 503; Body = ''; Headers = @{} }) }

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ MaxAttempts = 3 }

            $result.counts['failed'] | Should -Be 1
            (Get-IngestRequest).Count | Should -Be 3
            (Get-AuditRecord)[0].outcome | Should -Be 'failed'
        }

        It 'Does not retry a rejection and moves on to the next record' {
            Add-PullFixture -PrNumber 43
            $script:state.IngestQueue.Enqueue(@{ Status = 400; Body = '{"message":"bad"}'; Headers = @{} })
            $file = Write-LegacyFile -Line @((Get-LegacyLine -PrNumber 42), (Get-LegacyLine -PrNumber 43))

            $result = Invoke-Publish -InputFile $file

            $result.counts['rejected'] | Should -Be 1
            $result.counts['stored'] | Should -Be 1
            (Get-IngestRequest).Count | Should -Be 2
        }

        It 'Aborts at once on a 401 and writes the summary' {
            Add-PullFixture -PrNumber 43
            $script:state.IngestQueue.Enqueue(@{ Status = 401; Body = '{}'; Headers = @{} })
            $file = Write-LegacyFile -Line @((Get-LegacyLine -PrNumber 42), (Get-LegacyLine -PrNumber 43))

            { Invoke-Publish -InputFile $file } | Should -Throw '*401*'

            (Get-IngestRequest).Count | Should -Be 1
            $summary = Get-Content -Path (Join-Path $TestDrive "out/summary-$($script:lastRunId).json") -Raw | ConvertFrom-Json
            $summary.aborted | Should -BeTrue
            $summary.abortReason | Should -Match '401'
            (Get-AuditRecord)[0].outcome | Should -Be 'auth-failed'
        }

        It 'Records a connection failure as retryable' {
            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ IngestUrl = 'http://127.0.0.1:1/api/ingest'; MaxAttempts = 2 }

            $result.counts['failed'] | Should -Be 1
            (Get-AuditRecord)[0].attempts | Should -Be 2
        }
    }

    Context 'Audit and summary' {
        It 'Writes an audit line per record and a summary' {
            $null = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine))

            $record = (Get-AuditRecord)[0]
            $record.repository | Should -Be 'DEFRA/example'
            $record.prNumber | Should -Be 42
            $record.outcome | Should -Be 'stored'
            $record.http | Should -Be 201
            $summary = Get-Content -Path (Join-Path $TestDrive "out/summary-$($script:lastRunId).json") -Raw | ConvertFrom-Json
            $summary.mode | Should -Be 'live'
            $summary.aborted | Should -BeFalse
            $summary.counts.stored | Should -Be 1
        }

        It 'Never records a secret, title, author or contributor' {
            $console = & {
                $script:runCounter++
                $script:lastRunId = "test$($script:runCounter)"
                & $script:publish -InputPath (Write-LegacyFile -Line (Get-LegacyLine)) -IngestUrl "$($script:server.Base)/api/ingest" `
                    -GitHubApiUrl $script:server.Base -OutputDirectory (Join-Path $TestDrive 'out') -RunId $script:lastRunId `
                    -DelayMilliseconds 0 6>&1 *>&1 | Out-String
            }
            $files = Get-Content -Path (Join-Path $TestDrive "out/audit-$($script:lastRunId).jsonl"), (Join-Path $TestDrive "out/summary-$($script:lastRunId).json") -Raw

            foreach ($text in @($console, ($files -join ''))) {
                $text | Should -Not -Match 'test-ingest-secret'
                $text | Should -Not -Match 'test-github-secret'
                $text | Should -Not -Match 'Alex Example'
                $text | Should -Not -Match 'Add charts'
            }
        }

        It 'Refuses to reuse a run id' {
            $file = Write-LegacyFile -Line (Get-LegacyLine)
            $null = Invoke-Publish -InputFile $file
            $used = $script:lastRunId

            { Invoke-Publish -InputFile $file -Extra @{ RunId = $used } } | Should -Throw '*already been used*'
        }
    }

    Context 'Input checks' {
        It 'Rejects <Name>' -ForEach @(
            @{ Name = 'plain HTTP to a remote host'; Extra = @{ IngestUrl = 'http://example.org/api/ingest' }; Message = '*HTTPS*' }
            @{ Name = 'credentials in the URL'; Extra = @{ IngestUrl = 'https://user:pass@example.org/api/ingest' }; Message = '*credentials*' }
            @{ Name = 'a query string on the URL'; Extra = @{ IngestUrl = 'https://example.org/api/ingest?token=abc' }; Message = '*query string*' }
            @{ Name = 'the wrong endpoint path'; Extra = @{ IngestUrl = 'https://example.org/api/ingest/survival' }; Message = '*/api/ingest*' }
            @{ Name = 'a relative URL'; Extra = @{ IngestUrl = '/api/ingest' }; Message = '*absolute URL*' }
            @{ Name = 'a missing ingest URL'; Extra = @{ IngestUrl = '' }; Message = '*absolute URL*' }
            @{ Name = 'a plain HTTP GitHub URL'; Extra = @{ GitHubApiUrl = 'http://github.example.org' }; Message = '*HTTPS*' }
        ) {
            $file = Write-LegacyFile -Line (Get-LegacyLine)

            { Invoke-Publish -InputFile $file -Extra $Extra } | Should -Throw $Message
            (Get-IngestRequest).Count | Should -Be 0
        }

        It 'Requires INGEST_TOKEN unless -DryRun' {
            $env:INGEST_TOKEN = $null

            { Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) } | Should -Throw '*INGEST_TOKEN is not set*'
        }

        It 'Rejects a token that is not valid in a header without echoing it' {
            $env:INGEST_TOKEN = "bad token`r`nx-evil: 1"

            { Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) } | Should -Throw '*not valid in an HTTP header*'
            try { Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) } catch { $_.Exception.Message | Should -Not -Match 'evil' }
        }

        It 'Reads the ingest URL from COPILOT_ANALYTICS_INGEST_URL' {
            $env:COPILOT_ANALYTICS_INGEST_URL = "$($script:server.Base)/api/ingest"

            $result = Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ IngestUrl = $env:COPILOT_ANALYTICS_INGEST_URL }

            $result.counts['stored'] | Should -Be 1
        }

        It 'Rejects a missing input file' {
            { Invoke-Publish -InputFile (Join-Path $TestDrive 'missing.ndjson') } | Should -Throw '*does not exist*'
        }

        It 'Rejects a run id with unsafe characters' {
            { Invoke-Publish -InputFile (Write-LegacyFile -Line (Get-LegacyLine)) -Extra @{ RunId = '../escape' } } | Should -Throw
        }
    }
}
