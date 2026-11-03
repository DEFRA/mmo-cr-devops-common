BeforeAll {
    $script:publish = Join-Path $PSScriptRoot 'Publish-AiSurvival.ps1'
    $script:saved = @{}
    foreach ($name in 'INGEST_OIDC_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'INGEST_OIDC_AUDIENCE') {
        $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    # A throwaway local server: answers each request with the next status and records what it saw.
    function Open-TestServer {
        param([int[]]$Statuses)

        $port = Get-Random -Minimum 20000 -Maximum 40000
        $log = Join-Path $TestDrive "server-$port.log"
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript({
                param($Port, $Statuses, $Log)
                $listener = [System.Net.HttpListener]::new()
                $listener.Prefixes.Add("http://127.0.0.1:$Port/")
                $listener.Start()
                for ($i = 0; $i -lt $Statuses.Count; $i++) {
                    $pending = $listener.GetContextAsync()
                    if (-not $pending.Wait(10000)) { break }
                    $context = $pending.Result
                    $body = [System.IO.StreamReader]::new($context.Request.InputStream).ReadToEnd()
                    $entry = @{ authorization = $context.Request.Headers['Authorization']; body = $body } | ConvertTo-Json -Compress
                    Add-Content -Path $Log -Value $entry
                    $context.Response.StatusCode = $Statuses[$i]
                    $context.Response.Close()
                }
                $listener.Stop()
            }).AddArgument($port).AddArgument($Statuses).AddArgument($log)
        $handle = $shell.BeginInvoke()
        Start-Sleep -Milliseconds 500
        return @{ Url = "http://127.0.0.1:$port/api/ingest/survival"; Log = $log; Shell = $shell; Handle = $handle; Runspace = $runspace }
    }

    function Close-TestServer {
        param($Server)
        if (-not $Server.Handle.AsyncWaitHandle.WaitOne(3000)) { $Server.Shell.Stop() }
        $Server.Shell.Dispose()
        $Server.Runspace.Dispose()
    }

    function Write-RecordFile {
        param([int[]]$Numbers)
        $path = Join-Path $TestDrive "records-$([guid]::NewGuid()).json"
        $records = foreach ($n in $Numbers) { [ordered]@{ kind = 'ai-survival'; repository = 'DEFRA/example'; prNumber = $n; mergedAt = '2026-01-10T12:00:00.0000000Z' } }
        Set-Content -Path $path -Value (ConvertTo-Json -InputObject @($records) -Depth 4)
        return $path
    }
}

AfterAll {
    foreach ($name in $script:saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:saved[$name])
    }
}

Describe 'Publish-AiSurvival' {
    BeforeEach {
        $env:INGEST_OIDC_TOKEN = 'jwt-token'
    }

    It 'Posts each record with a bearer token and keeps the date strings as measured' {
        $server = Open-TestServer -Statuses @(201, 200)
        try {
            & $script:publish -IngestUrl $server.Url -InputPath (Write-RecordFile -Numbers 1, 2) -RetryDelaySeconds 0 6>$null | Out-Null
        }
        finally { Close-TestServer -Server $server }

        $seen = @(Get-Content -Path $server.Log | ForEach-Object { $_ | ConvertFrom-Json })
        $seen.Count | Should -Be 2
        $seen[0].authorization | Should -Be 'Bearer jwt-token'
        $seen[0].body | Should -Match '"prNumber":\s*1'
        $seen[0].body | Should -Match '2026-01-10T12:00:00.0000000Z'
    }

    It 'Carries on after a rejected record and succeeds when at least one was published' {
        $server = Open-TestServer -Statuses @(400, 201)
        try {
            { & $script:publish -IngestUrl $server.Url -InputPath (Write-RecordFile -Numbers 1, 2) -RetryDelaySeconds 0 6>$null | Out-Null } | Should -Not -Throw
        }
        finally { Close-TestServer -Server $server }

        @(Get-Content -Path $server.Log).Count | Should -Be 2
    }

    It 'Retries a server error and then succeeds' {
        $server = Open-TestServer -Statuses @(503, 201)
        try {
            & $script:publish -IngestUrl $server.Url -InputPath (Write-RecordFile -Numbers 1) -RetryDelaySeconds 0 6>$null | Out-Null
        }
        finally { Close-TestServer -Server $server }

        @(Get-Content -Path $server.Log).Count | Should -Be 2
    }

    It 'Throws when every record is rejected' {
        $server = Open-TestServer -Statuses @(401)
        try {
            { & $script:publish -IngestUrl $server.Url -InputPath (Write-RecordFile -Numbers 1) -RetryDelaySeconds 0 6>$null | Out-Null } | Should -Throw '*Every survival record failed*'
        }
        finally { Close-TestServer -Server $server }
    }

    It 'Refuses plain HTTP to a remote host, a missing file and a missing credential' {
        { & $script:publish -IngestUrl 'http://example.com/x' -InputPath (Write-RecordFile -Numbers 1) 6>$null | Out-Null } | Should -Throw '*unencrypted*'
        { & $script:publish -IngestUrl 'https://example.com/x' -InputPath (Join-Path $TestDrive 'missing.json') 6>$null | Out-Null } | Should -Throw '*Missing survival file*'

        $env:INGEST_OIDC_TOKEN = $null
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = $null
        $env:INGEST_OIDC_AUDIENCE = $null
        { & $script:publish -IngestUrl 'https://example.com/x' -InputPath (Write-RecordFile -Numbers 1) 6>$null | Out-Null } | Should -Throw '*Missing OIDC credential*'
    }

    It 'Does nothing for an empty list' {
        $path = Join-Path $TestDrive 'empty.json'
        Set-Content -Path $path -Value '[]'

        { & $script:publish -IngestUrl 'https://example.com/x' -InputPath $path 6>$null | Out-Null } | Should -Not -Throw
    }
}
