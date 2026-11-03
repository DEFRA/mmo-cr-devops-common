<#
.SYNOPSIS
    Pure helpers for Get-CopilotMetrics.ps1, kept separate so they can be unit
    tested with Pester. Dot-source this file; it has no side effects.
#>

Set-StrictMode -Version Latest

# The same trailer drives classification and attribution so they cannot disagree.
$script:CopilotTrailerPattern = '(?i)Copilot-Assisted:\s*true'

# Mirrors the backend joi rule; see mmo-cr-copilot-backend ADR 0001.
$script:JiraKeyContractPattern = '^[A-Z][A-Z0-9_]{1,49}-[1-9]\d{0,9}$'
$script:JiraKeySearchPattern = '(?<![A-Za-z0-9_])[A-Z][A-Z0-9_]+-[1-9]\d*(?!\d)'

$script:ModuleContainerFolders = @('src', 'packages', 'apps', 'services', 'libs', 'lib', 'modules')

$script:DefaultTestGlobs = @(
    '**/*.test.*',
    '**/*.spec.*',
    '**/test/**',
    '**/tests/**',
    '**/__tests__/**',
    '**/test-helpers/**',
    '**/*.Tests.ps1',
    '**/*_test.*',
    '**/*Test.java',
    '**/*Tests.cs'
)

function Test-CopilotTrailer {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Message)

    return [bool]($Message -match $script:CopilotTrailerPattern)
}

$script:AnalyticsTotalKeys = @('aiCompletion', 'aiChat', 'aiAgent', 'aiModified', 'pasted', 'typed', 'untracked')
$script:AnalyticsMaxCount = 10000000
$script:AnalyticsSchemas = @('ai-attribution/2', 'mmo-attribution/1', 'mmo-attribution/2')
$script:AnalyticsFileSchemas = @('ai-attribution-file/2', 'mmo-attribution-file/1', 'mmo-attribution-file/2')
$script:AnalyticsMaxFileRecords = 200
$script:AnalyticsMaxModels = 20
$script:AnalyticsMaxTokens = 10000000000L
$script:AnalyticsUsageKeys = @('requests', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheCreationTokens', 'reasoningTokens')

<#
    Fingerprint of one source line, identical to the extension's fingerprint():
    sha256 of "ai-fp/1`n" + the line with ASCII whitespace runs collapsed and
    trimmed, first 8 hex characters. $null for a blank line.
#>
function Get-LineFingerprint {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $norm = ($Text -creplace '[ \t\r\n\f\v]+', ' ') -creplace '^ | $', ''
    if ($norm -eq '') { return $null }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("ai-fp/1`n$norm")
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant().Substring(0, 8)
}

<#
    Validates one .analytics/<id>/summary.json written by the DEFRA AI
    Attribution extension. Returns the totals, or $null when the file is
    malformed so the caller can fall back to the trailer.
#>
function ConvertFrom-AnalyticsSummary {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $doc = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $doc) { return $null }

    $schema = $doc.PSObject.Properties['schema']
    $totalsProperty = $doc.PSObject.Properties['totals']
    if ($null -eq $schema -or $schema.Value -notin $script:AnalyticsSchemas -or $null -eq $totalsProperty -or $null -eq $totalsProperty.Value) { return $null }

    $totals = [ordered]@{}
    foreach ($key in $script:AnalyticsTotalKeys) {
        $property = $totalsProperty.Value.PSObject.Properties[$key]
        if ($null -eq $property) { return $null }
        $number = 0
        if (-not [int]::TryParse([string]$property.Value, [ref]$number) -or $number -lt 0 -or $number -gt $script:AnalyticsMaxCount) { return $null }
        $totals[$key] = $number
    }
    return $totals
}

<# Sums the totals of every summary a commit added. #>
function Merge-AnalyticsTotal {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][object[]]$Summary)

    $merged = [ordered]@{}
    foreach ($key in $script:AnalyticsTotalKeys) { $merged[$key] = 0 }
    foreach ($item in $Summary) {
        foreach ($key in $script:AnalyticsTotalKeys) { $merged[$key] += [int]$item[$key] }
    }
    return $merged
}

function Get-JsonProperty {
    [CmdletBinding()]
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-EmptyUsageEntry {
    param([string]$Model)

    $entry = [ordered]@{ model = $Model }
    foreach ($key in $script:AnalyticsUsageKeys) { $entry[$key] = 0L }
    return $entry
}

<#
    Model and token usage from a v2 summary, aggregated per model across its
    sessions. Returns $null for v1, usage that is not `captured`, or malformed
    data; the caller then simply has no usage for the commit.
#>
function ConvertFrom-AnalyticsUsage {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $doc = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ((Get-JsonProperty $doc 'schema') -notin @('ai-attribution/2', 'mmo-attribution/2')) { return $null }
    if ((Get-JsonProperty (Get-JsonProperty $doc 'signals') 'usage') -ne 'captured') { return $null }
    $usage = Get-JsonProperty $doc 'usage'
    if ($null -eq $usage) { return $null }

    $byModel = [ordered]@{}
    $sessionCount = 0
    foreach ($session in @(Get-JsonProperty $usage 'sessions')) {
        if ($null -eq $session) { continue }
        $sessionCount++
        foreach ($item in @(Get-JsonProperty $session 'models')) {
            $name = [string](Get-JsonProperty $item 'model')
            if ($name -notmatch '^[A-Za-z0-9._:/ -]{1,100}$') { continue }
            if (-not $byModel.Contains($name)) { $byModel[$name] = Get-EmptyUsageEntry -Model $name }
            foreach ($key in $script:AnalyticsUsageKeys) {
                $number = 0L
                if ([int64]::TryParse([string](Get-JsonProperty $item $key), [ref]$number) -and $number -ge 0 -and $number -le $script:AnalyticsMaxTokens) {
                    $byModel[$name][$key] = [math]::Min($script:AnalyticsMaxTokens, $byModel[$name][$key] + $number)
                }
            }
        }
    }
    if ($byModel.Count -eq 0) { return $null }
    return [ordered]@{ models = @($byModel.Values); sessions = $sessionCount }
}

<# Sums per-commit usage; models beyond the cap are folded into "other". #>
function Merge-AnalyticsUsage {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Usage)

    $items = @($Usage | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return $null }

    $byModel = [ordered]@{}
    $sessions = 0
    foreach ($item in $items) {
        $sessions += [int]$item['sessions']
        foreach ($entry in $item['models']) {
            if (-not $byModel.Contains($entry['model'])) { $byModel[$entry['model']] = Get-EmptyUsageEntry -Model $entry['model'] }
            foreach ($key in $script:AnalyticsUsageKeys) {
                $byModel[$entry['model']][$key] = [math]::Min($script:AnalyticsMaxTokens, $byModel[$entry['model']][$key] + [int64]$entry[$key])
            }
        }
    }

    $models = @($byModel.Values | Sort-Object { $_['inputTokens'] + $_['outputTokens'] } -Descending)
    if ($models.Count -gt $script:AnalyticsMaxModels) {
        $other = Get-EmptyUsageEntry -Model 'other'
        foreach ($entry in $models[($script:AnalyticsMaxModels - 1)..($models.Count - 1)]) {
            foreach ($key in $script:AnalyticsUsageKeys) { $other[$key] = [math]::Min($script:AnalyticsMaxTokens, $other[$key] + $entry[$key]) }
        }
        $models = @($models[0..($script:AnalyticsMaxModels - 2)]) + @($other)
    }
    return [ordered]@{ models = $models; sessions = $sessions }
}

<#
    Validates one .analytics/<id>/files/<path>.json. Returns the source path
    and, for v2, the listed AI lines. Ai is $null for v1 (nothing to verify).
    Returns $null when the record is malformed or its path is unsafe.
#>
function ConvertFrom-AnalyticsFileRecord {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $doc = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $schema = Get-JsonProperty $doc 'schema'
    if ($schema -notin $script:AnalyticsFileSchemas) { return $null }

    $path = [string](Get-JsonProperty $doc 'path')
    if ($path -eq '' -or $path.StartsWith('/') -or @($path -split '/') -contains '..' -or @($path -split '/') -contains '') { return $null }

    $ai = $null
    if ($schema -in @('ai-attribution-file/2', 'mmo-attribution-file/2') -and $null -ne $doc.PSObject.Properties['ai']) {
        $ai = [System.Collections.Generic.List[object]]::new()
        foreach ($tuple in @($doc.ai)) {
            $parts = @($tuple)
            $line = 0
            if ($parts.Count -ne 4 -or -not [int]::TryParse([string]$parts[0], [ref]$line) -or $line -lt 1) { return $null }
            if ([string]$parts[1] -cnotin @('a', 'c', 'h') -or [string]$parts[2] -cnotmatch '^[0-9a-f]{8}$') { return $null }
            $ai.Add([ordered]@{ Line = $line; Origin = [string]$parts[1]; Fp = [string]$parts[2]; Modified = ([int]$parts[3] -eq 1) })
        }
    }
    $v1 = $null
    if ($null -eq $ai) {
        $v1 = [System.Collections.Generic.List[object]]::new()
        $ranges = Get-JsonProperty $doc 'ranges'
        foreach ($pair in @(@('ai-agent', 'a'), @('ai-completion', 'c'), @('ai-chat', 'h'))) {
            foreach ($line in ConvertFrom-RangeText -Text ([string](Get-JsonProperty $ranges $pair[0]))) {
                $v1.Add([ordered]@{ Line = $line; Origin = $pair[1] })
            }
        }
    }
    return [ordered]@{
        Path      = $path
        Schema    = $schema
        Truncated = [bool](Get-JsonProperty $doc 'aiTruncated')
        Ai        = $ai
        V1        = $v1
    }
}

<#
    Compares each listed AI line with the fingerprint of the committed line at
    that number. $Lines is $null when the file is absent from the commit, so
    every listed line is a mismatch.
#>
function Test-AnalyticsFileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [AllowNull()][string[]]$Lines
    )

    $mismatched = [System.Collections.Generic.List[object]]::new()
    $verified = 0
    foreach ($item in $Record['Ai']) {
        $text = if ($null -ne $Lines -and $item.Line -le $Lines.Count) { $Lines[$item.Line - 1].TrimEnd("`r") } else { $null }
        if ($null -ne $text -and (Get-LineFingerprint -Text $text) -ceq $item.Fp) { $verified++ } else { $mismatched.Add($item) }
    }
    return [ordered]@{ Listed = $Record['Ai'].Count; Verified = $verified; Mismatched = $mismatched.ToArray() }
}

<#
    Per-commit attribution block of payload contract v2.
      extension       Metadata from .analytics, or inferred 100% human when a
                      Human-authored commit carries none.
      legacy-trailer  Copilot-assisted by the old trailer, no line counts.
      none            Rebase, merge and Dependabot commits.
#>
function Get-CommitAttribution {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Classification,
        [AllowNull()]$AnalyticsTotal = $null,
        [int]$LinesAdded = 0,
        [AllowNull()]$Usage = $null
    )

    if ($Classification -eq 'Rebase' -or $Classification -eq 'Dependabot') {
        return [ordered]@{ source = 'none' }
    }

    if ($null -ne $AnalyticsTotal) {
        $known = $AnalyticsTotal['aiCompletion'] + $AnalyticsTotal['aiChat'] + $AnalyticsTotal['aiAgent'] + $AnalyticsTotal['pasted']
        $attribution = [ordered]@{
            source            = 'extension'
            version           = 1
            aiCompletionLines = [int]$AnalyticsTotal['aiCompletion']
            aiChatLines       = [int]$AnalyticsTotal['aiChat']
            aiAgentLines      = [int]$AnalyticsTotal['aiAgent']
            pastedLines       = [int]$AnalyticsTotal['pasted']
            typedLines        = [math]::Max(0, $LinesAdded - $known)
        }
        if ($null -ne $Usage) {
            $attribution['usage'] = [ordered]@{
                models           = @($Usage['models'])
                sessions         = [int]$Usage['sessions']
                commitsWithUsage = 1
            }
        }
        return $attribution
    }

    if ($Classification -eq 'Copilot-assisted') { return [ordered]@{ source = 'legacy-trailer' } }

    return [ordered]@{
        source            = 'extension'
        version           = 1
        aiCompletionLines = 0
        aiChatLines       = 0
        aiAgentLines      = 0
        pastedLines       = 0
        typedLines        = $LinesAdded
    }
}

<#
    Candidate Jira issue keys from the branch, title and commit messages.
    Without an allow-list every well-formed match is a candidate; the backend
    filters against configured projects later.
#>
function Get-JiraKey {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyString()][string]$Branch = '',
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyCollection()][string[]]$Message = @(),
        [AllowEmptyCollection()][string[]]$ProjectKey = @(),
        [int]$Maximum = 50
    )

    $allowList = @($ProjectKey | ForEach-Object { "$_".Trim().ToUpperInvariant() } | Where-Object { $_ })
    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    $branchOptions = if ($allowList.Count -gt 0) { 'IgnoreCase' } else { 'None' }
    $sources = @(
        @{ Text = $Branch; Options = $branchOptions }
        @{ Text = $Title; Options = 'None' }
    ) + @($Message | ForEach-Object { @{ Text = $_; Options = 'None' } })

    foreach ($source in $sources) {
        if ([string]::IsNullOrEmpty($source.Text)) { continue }
        foreach ($match in [regex]::Matches($source.Text, $script:JiraKeySearchPattern, $source.Options)) {
            $key = $match.Value.ToUpperInvariant()
            if ($key -cnotmatch $script:JiraKeyContractPattern) { continue }
            if ($allowList.Count -gt 0 -and $allowList -notcontains $key.Split('-')[0]) { continue }
            [void]$found.Add($key)
        }
    }

    $sorted = [System.Collections.Generic.List[string]]::new($found)
    $sorted.Sort([StringComparer]::Ordinal)
    return [string[]]@($sorted | Select-Object -First $Maximum)
}

function Get-ModuleKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $segments = @($Path.Trim('/') -split '/' | Where-Object { $_ })
    if ($segments.Count -le 1) { return '(root)' }
    if ($segments.Count -ge 3 -and $script:ModuleContainerFolders -contains $segments[0]) {
        return "$($segments[0])/$($segments[1])"
    }
    return $segments[0]
}

<#
    Converts a gitignore-style entry to a git glob pattern.
      "e2e/"      -> e2e/**
      "a/b.js"    -> a/b.js       (path-anchored)
      "*.feature" -> **/*.feature (any depth)
#>
function ConvertTo-GlobPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Entry)

    $value = $Entry.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('#')) { return $null }

    $value = $value.TrimStart('/')
    if ($value.EndsWith('/')) { return "$value**" }
    if ($value.Contains('/')) { return $value }
    return "**/$value"
}

# Rename entries look like "old => new" or "dir/{old => new}/file".
function Resolve-NumstatPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = $Path.Trim('"')
    $resolved = $resolved -replace '\{[^{}]* => ([^{}]*)\}', '$1'
    if ($resolved.Contains(' => ')) { $resolved = ($resolved -split ' => ')[-1] }
    return ($resolved -replace '/{2,}', '/')
}

function Get-NumstatTotal {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Line = @())

    $files = 0
    $lines = 0
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Line)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $parts = $entry -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $files++
        # Binary files report '-' and count as a file with no lines.
        $added = 0; $deleted = 0
        [void][int]::TryParse($parts[0], [ref]$added)
        [void][int]::TryParse($parts[1], [ref]$deleted)
        $lines += $added + $deleted
        $paths.Add((Resolve-NumstatPath -Path $parts[2]))
    }

    return @{ Files = $files; Lines = $lines; Paths = $paths.ToArray() }
}

function ConvertTo-FilesBlock {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()][AllowNull()][string[]]$TestLine = @(),
        [AllowEmptyCollection()][AllowNull()][string[]]$NonTestLine = @(),
        [AllowEmptyCollection()][AllowNull()][string[]]$AllLine = @()
    )

    $test = Get-NumstatTotal -Line $TestLine
    $nonTest = Get-NumstatTotal -Line $NonTestLine
    $all = Get-NumstatTotal -Line $AllLine
    $modules = @($nonTest.Paths | ForEach-Object { Get-ModuleKey -Path $_ } | Sort-Object -Unique)

    return [ordered]@{
        changed          = $nonTest.Files
        linesTouched     = $nonTest.Lines
        testFilesChanged = $test.Files
        testLinesTouched = $test.Lines
        modulesTouched   = $modules.Count
        excluded         = [ordered]@{
            filesChanged = [math]::Max(0, $all.Files - $test.Files - $nonTest.Files)
            linesTouched = [math]::Max(0, $all.Lines - $test.Lines - $nonTest.Lines)
        }
    }
}

# Truncates by text element so a surrogate pair or combining sequence is never split.
function Limit-Text {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$MaximumLength
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $MaximumLength) { return $Text }

    $builder = [System.Text.StringBuilder]::new()
    $elements = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = $elements.GetTextElement()
        if ($builder.Length + $element.Length -gt $MaximumLength) { break }
        [void]$builder.Append($element)
    }
    return $builder.ToString()
}

# Ingest credentials: a GitHub Actions OIDC token when one is available
# (dashboard ADR 0003), otherwise the shared x-ingest-token secret.
function Get-IngestAuthHeader {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()][AllowNull()][string]$OidcToken,
        [AllowEmptyString()][AllowNull()][string]$SharedToken
    )

    if (-not [string]::IsNullOrWhiteSpace($OidcToken)) {
        return @{ 'Authorization' = "Bearer $OidcToken" }
    }
    if (-not [string]::IsNullOrWhiteSpace($SharedToken)) {
        return @{ 'x-ingest-token' = $SharedToken }
    }
    return $null
}

# A token id can be used once at the dashboard, so callers ask for a new one per attempt.
function Get-OidcToken {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:INGEST_OIDC_TOKEN)) {
        return $env:INGEST_OIDC_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -or
        [string]::IsNullOrWhiteSpace($env:INGEST_OIDC_AUDIENCE)) {
        return $null
    }
    $audience = [System.Uri]::EscapeDataString($env:INGEST_OIDC_AUDIENCE)
    $response = Invoke-RestMethod -Uri "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=$audience" `
        -Headers @{ Authorization = "bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" } `
        -TimeoutSec 30
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::add-mask::$($response.value)"
    }
    return $response.value
}

<#
    Reads one committed blob in the current directory's repository. Status is
    ok, missing or oversize; Text is only set when ok.
#>
function Read-GitBlob {
    [CmdletBinding()]
    param([string]$Hash, [string]$Path, [int64]$MaxBytes)

    $size = 0L
    $sizeText = @(git cat-file -s "${Hash}:$Path" 2>$null) | Select-Object -First 1
    if (-not [int64]::TryParse([string]$sizeText, [ref]$size)) { return [PSCustomObject]@{ Status = 'missing'; Text = $null } }
    if ($size -gt $MaxBytes) { return [PSCustomObject]@{ Status = 'oversize'; Text = $null } }
    return [PSCustomObject]@{ Status = 'ok'; Text = (@(git show "${Hash}:$Path") -join "`n") }
}

<# Line numbers from text such as 1-3,7,9-10. #>
function ConvertFrom-RangeText {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([AllowEmptyString()][AllowNull()][string]$Text)

    $numbers = [System.Collections.Generic.List[int]]::new()
    foreach ($part in @("$Text" -split ',')) {
        if ($part.Trim() -notmatch '^(\d+)(?:-(\d+))?$') { continue }
        $start = [int]$Matches[1]
        $end = if ($Matches[2]) { [int]$Matches[2] } else { $start }
        if ($end -lt $start -or ($end - $start) -gt 1000000) { continue }
        foreach ($n in $start..$end) { $numbers.Add($n) }
    }
    return $numbers.ToArray()
}

<#
    Parses `git blame --porcelain` output into one row per final line:
    Sha, OrigLine, FinalLine, Path and Text.
#>
function ConvertFrom-GitBlame {
    [CmdletBinding()]
    param([AllowNull()][string[]]$Lines)

    $rows = [System.Collections.Generic.List[object]]::new()
    $paths = @{}
    $current = $null
    foreach ($line in @($Lines)) {
        if ($line.StartsWith("`t")) {
            if ($null -ne $current) {
                $rows.Add([PSCustomObject]@{
                        Sha       = $current.Sha
                        OrigLine  = $current.OrigLine
                        FinalLine = $current.FinalLine
                        Path      = $paths[$current.Sha]
                        Text      = $line.Substring(1)
                    })
                $current = $null
            }
            continue
        }
        if ($line -match '^([0-9a-f]{40}) (\d+) (\d+)(?: \d+)?$') {
            $current = [PSCustomObject]@{ Sha = $Matches[1]; OrigLine = [int]$Matches[2]; FinalLine = [int]$Matches[3] }
        }
        elseif ($line.StartsWith('filename ') -and $null -ne $current) {
            $paths[$current.Sha] = $line.Substring('filename '.Length)
        }
    }
    return $rows.ToArray()
}
