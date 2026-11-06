<#
.SYNOPSIS
    Pure helpers for the legacy v1 -> v2 migration, unit tested with Pester; dot-source only.
    Messages name a field, never its value: authors, subjects and titles are personal data.
#>

Set-StrictMode -Version Latest

. (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'CopilotMetrics.Helpers.ps1')

$script:IsoDateTimePattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
$script:RepositoryPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$'
$script:CommitClassifications = @('Copilot-assisted', 'Human-authored', 'Rebase', 'Dependabot')
$script:CountedClassifications = @('Copilot-assisted', 'Human-authored')
$script:AttributionSources = @('extension', 'legacy-trailer', 'none')

# Mirrors the producer's always-excluded paths; .analytics/** is not counted at all.
$script:BuiltInIgnoreGlobs = @(
    '**/package-lock.json',
    '**/yarn.lock',
    '**/pnpm-lock.yaml',
    '**/*.snap',
    '**/*.min.js',
    '**/*.min.css',
    '**/*.map'
)
$script:AnalyticsDirectoryGlob = '.analytics/**'

$script:RootKeys = @('prNumber', 'repository', 'sourceBranch', 'targetBranch', 'buildId')
$script:RootDateKeys = @('calculatedAt', 'prCreatedAt', 'firstCommitAt', 'lastCommitAt', 'prMergedAt')
$script:SummaryCountKeys = @('totalCommits', 'copilotAssistedCommits', 'humanAuthoredCommits', 'totalLinesTouched', 'copilotAssistedLines', 'humanAuthoredLines')
$script:SummaryRateKeys = @('copilotAssistedRate', 'copilotAssistedLineRate')
$script:SummaryOptionalKeys = @('excludedCommits', 'rebaseCommits', 'dependabotCommits')
$script:ContributorCountKeys = @('totalCommits', 'copilotAssisted', 'humanAuthored', 'linesAdded', 'linesDeleted', 'linesTouched', 'copilotAssistedLines', 'humanAuthoredLines')
$script:CommitCountKeys = @('filesChanged', 'linesAdded', 'linesDeleted', 'linesTouched')

$script:GlobRegexCache = @{}
$script:JsonSupportsDateKind = (Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')

#region Reading legacy documents

<# Dictionary-aware property read: ConvertFrom-Json -AsHashtable output has no PSObject properties. #>
function Get-LegacyField {
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return , $property.Value
}

<# The value as an array when it is one, otherwise an empty array. #>
function Get-LegacyArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-LegacyField -Object $Object -Name $Name
    if ($value -is [array]) { return , [object[]]$value }
    return , [object[]]@()
}

# One NDJSON line to a hashtable. -DateKind (7.5+) keeps dates as strings; older hosts yield [datetime].
function ConvertFrom-JsonLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $arguments = @{ AsHashtable = $true; NoEnumerate = $true; ErrorAction = 'Stop' }
    if ($script:JsonSupportsDateKind) { $arguments['DateKind'] = 'String' }
    return $Line | ConvertFrom-Json @arguments
}

# Any BSON date shape as yyyy-MM-ddTHH:mm:ss.fffZ (UTC; no offset means UTC), $null when empty.
# Throws FormatException, never echoing the value, when the input is unusable.
function ConvertFrom-LegacyDate {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('$date')) { return ConvertFrom-LegacyDate -Value $Value['$date'] }
        if ($Value.Contains('$numberLong')) {
            $millis = 0L
            if (-not [int64]::TryParse([string]$Value['$numberLong'], [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$millis)) {
                throw [System.FormatException]::new('Unrecognised date value.')
            }
            return ConvertFrom-LegacyDate -Value $millis
        }
        throw [System.FormatException]::new('Unrecognised date value.')
    }

    $offset = [DateTimeOffset]::MinValue
    if ($Value -is [datetime]) {
        $utc = if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
        $offset = [DateTimeOffset]::new($utc)
    }
    elseif ($Value -is [DateTimeOffset]) {
        $offset = $Value
    }
    elseif ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [DateTimeOffset]::TryParse($Value.Trim(), [cultureinfo]::InvariantCulture, $styles, [ref]$offset)) {
            throw [System.FormatException]::new('Unrecognised date value.')
        }
    }
    elseif (($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) -and $Value -isnot [bool]) {
        try { $offset = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value) }
        catch { throw [System.FormatException]::new('Unrecognised date value.') }
    }
    else {
        throw [System.FormatException]::new('Unrecognised date value.')
    }

    return $offset.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
}

# Unwraps $date, $oid and the $number* wrappers recursively; anything else passes through
# unchanged so validation reports it.
function ConvertFrom-ExtendedJsonValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 1) {
            $key = [string]@($Value.Keys)[0]
            $inner = $Value[$key]
            $culture = [cultureinfo]::InvariantCulture
            if ($key -ceq '$date') { return ConvertFrom-LegacyDate -Value (ConvertFrom-ExtendedJsonValue -Value $inner) }
            if ($key -ceq '$oid') { return [string]$inner }
            if ($key -ceq '$numberLong') {
                $long = 0L
                if (-not [int64]::TryParse([string]$inner, [System.Globalization.NumberStyles]::Integer, $culture, [ref]$long)) { throw [System.FormatException]::new('Unrecognised $numberLong value.') }
                return $long
            }
            if ($key -ceq '$numberInt') {
                $int = 0
                if (-not [int]::TryParse([string]$inner, [System.Globalization.NumberStyles]::Integer, $culture, [ref]$int)) { throw [System.FormatException]::new('Unrecognised $numberInt value.') }
                return $int
            }
            if ($key -ceq '$numberDouble' -or $key -ceq '$numberDecimal') {
                $double = 0.0
                $text = [string]$inner
                if ($text -eq 'NaN') { return [double]::NaN }
                if ($text -eq 'Infinity') { return [double]::PositiveInfinity }
                if ($text -eq '-Infinity') { return [double]::NegativeInfinity }
                if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $culture, [ref]$double)) { throw [System.FormatException]::new("Unrecognised $key value.") }
                return $double
            }
        }
        $result = [ordered]@{}
        foreach ($name in $Value.Keys) { $result[$name] = ConvertFrom-ExtendedJsonValue -Value $Value[$name] }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertFrom-ExtendedJsonValue -Value $item)) }
        return , $items.ToArray()
    }

    return $Value
}

#endregion

#region Path classification

# A git :(glob) pattern as an anchored regex: * and ? stay in a segment, **/ spans zero or more
# directories, a trailing /** matches everything beneath.
function ConvertTo-GlobRegex {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Glob)

    $builder = [System.Text.StringBuilder]::new('^')
    $length = $Glob.Length
    $i = 0
    while ($i -lt $length) {
        $char = $Glob[$i]
        if ($char -eq '*') {
            $isDouble = ($i + 1 -lt $length) -and ($Glob[$i + 1] -eq '*')
            $atSegmentStart = ($i -eq 0) -or ($Glob[$i - 1] -eq '/')
            if ($isDouble -and $atSegmentStart -and ($i + 2 -lt $length) -and ($Glob[$i + 2] -eq '/')) {
                [void]$builder.Append('(?:.*/)?')
                $i += 3
            }
            elseif ($isDouble -and $atSegmentStart -and ($i + 2 -eq $length)) {
                [void]$builder.Append('.*')
                $i += 2
            }
            else {
                [void]$builder.Append('[^/]*')
                $i += if ($isDouble) { 2 } else { 1 }
            }
        }
        elseif ($char -eq '?') {
            [void]$builder.Append('[^/]')
            $i++
        }
        elseif ($char -eq '\' -and ($i + 1 -lt $length)) {
            [void]$builder.Append([regex]::Escape([string]$Glob[$i + 1]))
            $i += 2
        }
        elseif ($char -eq '[' -and ($Glob.IndexOf(']', $i + 2) -gt 0)) {
            $close = $Glob.IndexOf(']', $i + 2)
            $body = $Glob.Substring($i + 1, $close - $i - 1)
            $negate = $body.StartsWith('!') -or $body.StartsWith('^')
            if ($negate) { $body = $body.Substring(1) }
            $body = $body -replace '([\\\[\]^])', '\$1'
            [void]$builder.Append($(if ($negate) { "[^/$body]" } else { "[$body]" }))
            $i = $close + 1
        }
        else {
            [void]$builder.Append([regex]::Escape([string]$char))
            $i++
        }
    }
    [void]$builder.Append('$')
    return $builder.ToString()
}

function Test-GlobMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Glob
    )

    if (-not $script:GlobRegexCache.ContainsKey($Glob)) {
        $script:GlobRegexCache[$Glob] = [regex]::new((ConvertTo-GlobRegex -Glob $Glob), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    }
    return $script:GlobRegexCache[$Glob].IsMatch($Path)
}

<# Globs from the text of an .analyticsignore or .analyticstests file; comments and blanks are dropped. #>
function ConvertFrom-AnalyticsRuleText {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $globs = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @("$Text" -split '\r?\n')) {
        $glob = ConvertTo-GlobPattern -Entry $line
        if ($glob) { $globs.Add($glob) }
    }
    return $globs.ToArray()
}

# skipped (.analytics/**), excluded, test or nonTest, as the live producer buckets a path.
# -IgnoreGlob and -TestGlob extend the built-in lists, never replace them.
function Get-PathBucket {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$IgnoreGlob = @(),
        [AllowEmptyCollection()][string[]]$TestGlob = @()
    )

    if (Test-GlobMatch -Path $Path -Glob $script:AnalyticsDirectoryGlob) { return 'skipped' }
    foreach ($glob in @($script:BuiltInIgnoreGlobs) + @($IgnoreGlob)) {
        if (Test-GlobMatch -Path $Path -Glob $glob) { return 'excluded' }
    }
    foreach ($glob in @($script:DefaultTestGlobs) + @($TestGlob)) {
        if (Test-GlobMatch -Path $Path -Glob $glob) { return 'test' }
    }
    return 'nonTest'
}

<# Builds the payload `files` block from the entries of GitHub's pulls/{n}/files response. #>
function ConvertTo-FilesBlockFromPullFile {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$File = @(),
        [AllowEmptyCollection()][string[]]$IgnoreGlob = @(),
        [AllowEmptyCollection()][string[]]$TestGlob = @()
    )

    $changed = 0; $changedLines = 0
    $testFiles = 0; $testLines = 0
    $excludedFiles = 0; $excludedLines = 0
    $modules = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($entry in @($File)) {
        $path = [string](Get-LegacyField -Object $entry -Name 'filename')
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $added = ConvertTo-IntegerValue -Value (Get-LegacyField -Object $entry -Name 'additions')
        $deleted = ConvertTo-IntegerValue -Value (Get-LegacyField -Object $entry -Name 'deletions')
        $touched = $(if ($added -is [int64]) { $added } else { 0 }) + $(if ($deleted -is [int64]) { $deleted } else { 0 })

        switch (Get-PathBucket -Path $path -IgnoreGlob $IgnoreGlob -TestGlob $TestGlob) {
            'nonTest' { $changed++; $changedLines += $touched; [void]$modules.Add((Get-ModuleKey -Path $path)) }
            'test' { $testFiles++; $testLines += $touched }
            'excluded' { $excludedFiles++; $excludedLines += $touched }
        }
    }

    return [ordered]@{
        changed          = $changed
        linesTouched     = $changedLines
        testFilesChanged = $testFiles
        testLinesTouched = $testLines
        modulesTouched   = $modules.Count
        excluded         = [ordered]@{
            filesChanged = $excludedFiles
            linesTouched = $excludedLines
        }
    }
}

#endregion

#region Transform

<# A whole number as [int64]; anything else is returned unchanged so validation can report it. #>
function ConvertTo-IntegerValue {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return [int64]$Value }
    if ($Value -is [double] -and [double]::IsFinite($Value) -and $Value -eq [math]::Floor($Value) -and [math]::Abs($Value) -lt 9e15) { return [int64]$Value }
    if ($Value -is [decimal] -and $Value -eq [math]::Floor($Value) -and [math]::Abs($Value) -lt 9e15) { return [int64]$Value }
    return , $Value
}

<# Copies only the named keys that are present and not null; the rest of the source is dropped. #>
function Copy-AllowedKey {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]$Source,
        [Parameter(Mandatory)][string[]]$Key,
        [AllowEmptyCollection()][string[]]$IntegerKey = @()
    )

    $copy = [ordered]@{}
    if ($null -eq $Source) { return $copy }
    foreach ($name in $Key) {
        $value = Get-LegacyField -Object $Source -Name $name
        if ($null -eq $value) { continue }
        if ($IntegerKey -contains $name) { $value = ConvertTo-IntegerValue -Value $value }
        $copy[$name] = $value
    }
    return $copy
}

# Legacy data has no line-level signal, so nothing is inferred: Copilot-assisted keeps the
# trailer source and every other commit is `none`.
function Get-LegacyAttribution {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowEmptyString()][string]$Classification = '')

    if ($Classification -ceq 'Copilot-assisted') { return [ordered]@{ source = 'legacy-trailer' } }
    return [ordered]@{ source = 'none' }
}

# Builds an ingest payload from an unwrapped legacy document, copying allow-listed keys only so
# Mongo-internal fields never leave. Version 1 omits the v2 fields; a bad date throws FormatException.
function ConvertTo-MigratedPayload {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Legacy,
        [AllowEmptyString()][string]$PrTitle = '',
        [AllowNull()][System.Collections.IDictionary]$Files = $null,
        [ValidateSet(1, 2)][int]$Version = 2,
        [AllowEmptyCollection()][string[]]$JiraProjectKey = @()
    )

    $payload = [ordered]@{ schemaVersion = $Version }
    if ($Version -eq 2) { $payload['source'] = 'backfill' }

    $root = Copy-AllowedKey -Source $Legacy -Key $script:RootKeys -IntegerKey @('prNumber')
    if ($root.Contains('buildId') -and $root['buildId'] -is [ValueType] -and $root['buildId'] -isnot [bool]) {
        $root['buildId'] = [System.Convert]::ToString($root['buildId'], [cultureinfo]::InvariantCulture)
    }
    if ($root.Contains('sourceBranch') -and [string]::IsNullOrWhiteSpace([string]$root['sourceBranch'])) {
        $root.Remove('sourceBranch')
    }
    foreach ($name in $root.Keys) { $payload[$name] = $root[$name] }

    foreach ($name in $script:RootDateKeys) {
        try { $iso = ConvertFrom-LegacyDate -Value (Get-LegacyField -Object $Legacy -Name $name) }
        catch { throw [System.FormatException]::new("Field '$name' is not a valid date.") }
        if ($iso) { $payload[$name] = $iso }
    }

    $payload['summary'] = Copy-AllowedKey -Source (Get-LegacyField -Object $Legacy -Name 'summary') `
        -Key ($script:SummaryCountKeys + $script:SummaryRateKeys + $script:SummaryOptionalKeys) `
        -IntegerKey ($script:SummaryCountKeys + $script:SummaryOptionalKeys)

    $contributorKeys = @('contributor') + $script:ContributorCountKeys + @('netLines')
    $contributors = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in (Get-LegacyArray -Object $Legacy -Name 'contributorBreakdown')) {
        $contributors.Add((Copy-AllowedKey -Source $(if ($entry -is [System.Collections.IDictionary]) { $entry } else { $null }) `
                    -Key $contributorKeys -IntegerKey ($script:ContributorCountKeys + @('netLines'))))
    }
    $payload['contributorBreakdown'] = $contributors.ToArray()

    $commitKeys = @('commit', 'author', 'subject', 'classification') + $script:CommitCountKeys + @('netLines')
    $commits = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($entry in (Get-LegacyArray -Object $Legacy -Name 'commitBreakdown')) {
        $commit = Copy-AllowedKey -Source $(if ($entry -is [System.Collections.IDictionary]) { $entry } else { $null }) `
            -Key $commitKeys -IntegerKey ($script:CommitCountKeys + @('netLines'))
        try { $committedAt = ConvertFrom-LegacyDate -Value (Get-LegacyField -Object $entry -Name 'committedAt') }
        catch { throw [System.FormatException]::new("Field 'commitBreakdown[$index].committedAt' is not a valid date.") }
        if ($committedAt) { $commit['committedAt'] = $committedAt }
        if (-not $commit.Contains('subject')) { $commit['subject'] = '' }
        elseif ($commit['subject'] -is [string]) { $commit['subject'] = Limit-Text -Text $commit['subject'] -MaximumLength 1024 }
        if ($Version -eq 2) {
            $commit['attribution'] = Get-LegacyAttribution -Classification ([string]$(if ($commit.Contains('classification')) { $commit['classification'] } else { '' }))
        }
        $commits.Add($commit)
        $index++
    }
    $payload['commitBreakdown'] = $commits.ToArray()

    if ($Version -eq 2) {
        $title = Limit-Text -Text $PrTitle.Trim() -MaximumLength 256
        $subjects = @($commits | Where-Object { $_.Contains('classification') -and $script:CountedClassifications -contains $_['classification'] } |
                ForEach-Object { [string]$_['subject'] })
        $branch = if ($payload.Contains('sourceBranch')) { [string]$payload['sourceBranch'] } else { '' }

        $payload['prTitle'] = $title
        $payload['jiraKeys'] = [string[]]@(Get-JiraKey -Branch $branch -Title $title -Message $subjects -ProjectKey $JiraProjectKey)
        if ($null -ne $Files) { $payload['files'] = $Files }
    }

    return $payload
}

#endregion

#region Pre-validation

function Test-ContractInteger {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    if ($Value -is [int] -or $Value -is [long]) { return $true }
    if ($Value -is [double]) { return [double]::IsFinite($Value) -and $Value -eq [math]::Floor($Value) }
    if ($Value -is [decimal]) { return $Value -eq [math]::Floor($Value) }
    return $false
}

function Test-ContractNumber {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    if ($Value -is [double]) { return [double]::IsFinite($Value) }
    return $Value -is [int] -or $Value -is [long] -or $Value -is [decimal]
}

function Test-ContractText {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][int]$Maximum,
        [switch]$AllowEmpty
    )

    if ($Value -isnot [string]) { return $false }
    if ($Value.Length -eq 0) { return [bool]$AllowEmpty }
    return $Value.Length -le $Maximum
}

function Test-ContractCountField {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Name,
        [switch]$Optional
    )

    foreach ($field in $Name) {
        $value = Get-LegacyField -Object $Object -Name $field
        if ($null -eq $value) {
            if (-not $Optional) { "$Path.$field is required." }
            continue
        }
        if (-not (Test-ContractInteger -Value $value) -or $value -lt 0) { "$Path.$field must be an integer of 0 or more." }
    }
}

# Mirrors the backend joi schema (src/schemas/payload.js) for the fields emitted here.
# One message per problem, naming path and rule, never the value; empty means acceptable.
function Test-MigratedPayload {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Payload)

    $errors = [System.Collections.Generic.List[string]]::new()
    $isoDate = { param($v) $v -is [string] -and $v -cmatch $script:IsoDateTimePattern }

    $versionValue = Get-LegacyField -Object $Payload -Name 'schemaVersion'
    $version = 1
    if ($null -ne $versionValue) {
        if ((Test-ContractInteger -Value $versionValue) -and ($versionValue -eq 1 -or $versionValue -eq 2)) { $version = [int]$versionValue }
        else { $errors.Add('schemaVersion must be 1 or 2.') }
    }

    $prNumber = Get-LegacyField -Object $Payload -Name 'prNumber'
    if (-not (Test-ContractInteger -Value $prNumber) -or $prNumber -lt 1) { $errors.Add('prNumber must be an integer of 1 or more.') }
    if (-not (Test-ContractText -Value (Get-LegacyField -Object $Payload -Name 'repository') -Maximum 512)) { $errors.Add('repository must be a string of 1 to 512 characters.') }
    if (-not (Test-ContractText -Value (Get-LegacyField -Object $Payload -Name 'targetBranch') -Maximum 512)) { $errors.Add('targetBranch must be a string of 1 to 512 characters.') }
    if (-not (Test-ContractText -Value (Get-LegacyField -Object $Payload -Name 'buildId') -Maximum 128)) { $errors.Add('buildId must be a string of 1 to 128 characters.') }
    $sourceBranch = Get-LegacyField -Object $Payload -Name 'sourceBranch'
    if ($null -ne $sourceBranch -and -not (Test-ContractText -Value $sourceBranch -Maximum 512)) { $errors.Add('sourceBranch must be a string of 1 to 512 characters.') }

    if (-not (& $isoDate (Get-LegacyField -Object $Payload -Name 'calculatedAt'))) { $errors.Add('calculatedAt must be an ISO-8601 date-time with an offset.') }
    foreach ($name in @('prCreatedAt', 'firstCommitAt', 'lastCommitAt', 'prMergedAt')) {
        $value = Get-LegacyField -Object $Payload -Name $name
        if ($null -ne $value -and -not (& $isoDate $value)) { $errors.Add("$name must be an ISO-8601 date-time with an offset.") }
    }

    $summary = Get-LegacyField -Object $Payload -Name 'summary'
    if ($summary -isnot [System.Collections.IDictionary]) { $errors.Add('summary is required.') }
    else {
        $errors.AddRange([string[]]@(Test-ContractCountField -Object $summary -Path 'summary' -Name $script:SummaryCountKeys))
        $errors.AddRange([string[]]@(Test-ContractCountField -Object $summary -Path 'summary' -Name $script:SummaryOptionalKeys -Optional))
        foreach ($name in $script:SummaryRateKeys) {
            $value = Get-LegacyField -Object $summary -Name $name
            if (-not (Test-ContractNumber -Value $value) -or $value -lt 0 -or $value -gt 100) { $errors.Add("summary.$name must be a number from 0 to 100.") }
        }
    }

    $contributors = Get-LegacyField -Object $Payload -Name 'contributorBreakdown'
    if ($contributors -isnot [array] -or $contributors.Count -lt 1 -or $contributors.Count -gt 200) { $errors.Add('contributorBreakdown must be an array of 1 to 200 entries.') }
    else {
        for ($i = 0; $i -lt $contributors.Count; $i++) {
            $path = "contributorBreakdown[$i]"
            $entry = $contributors[$i]
            if (-not (Test-ContractText -Value (Get-LegacyField -Object $entry -Name 'contributor') -Maximum 256)) { $errors.Add("$path.contributor must be a string of 1 to 256 characters.") }
            $errors.AddRange([string[]]@(Test-ContractCountField -Object $entry -Path $path -Name $script:ContributorCountKeys))
            if (-not (Test-ContractInteger -Value (Get-LegacyField -Object $entry -Name 'netLines'))) { $errors.Add("$path.netLines must be an integer.") }
        }
    }

    $commits = Get-LegacyField -Object $Payload -Name 'commitBreakdown'
    if ($commits -isnot [array] -or $commits.Count -lt 1 -or $commits.Count -gt 1000) { $errors.Add('commitBreakdown must be an array of 1 to 1000 entries.') }
    else {
        for ($i = 0; $i -lt $commits.Count; $i++) {
            $path = "commitBreakdown[$i]"
            $entry = $commits[$i]
            if (-not (Test-ContractText -Value (Get-LegacyField -Object $entry -Name 'commit') -Maximum 64)) { $errors.Add("$path.commit must be a string of 1 to 64 characters.") }
            if (-not (Test-ContractText -Value (Get-LegacyField -Object $entry -Name 'author') -Maximum 256)) { $errors.Add("$path.author must be a string of 1 to 256 characters.") }
            if (-not (Test-ContractText -Value (Get-LegacyField -Object $entry -Name 'subject') -Maximum 1024 -AllowEmpty)) { $errors.Add("$path.subject must be a string of at most 1024 characters.") }
            $committedAt = Get-LegacyField -Object $entry -Name 'committedAt'
            if ($null -ne $committedAt -and -not (& $isoDate $committedAt)) { $errors.Add("$path.committedAt must be an ISO-8601 date-time with an offset.") }
            if ($script:CommitClassifications -cnotcontains (Get-LegacyField -Object $entry -Name 'classification')) { $errors.Add("$path.classification must be a known classification.") }
            $errors.AddRange([string[]]@(Test-ContractCountField -Object $entry -Path $path -Name $script:CommitCountKeys))
            if (-not (Test-ContractInteger -Value (Get-LegacyField -Object $entry -Name 'netLines'))) { $errors.Add("$path.netLines must be an integer.") }

            if ($version -eq 2) {
                $attribution = Get-LegacyField -Object $entry -Name 'attribution'
                if ($attribution -isnot [System.Collections.IDictionary]) { $errors.Add("$path.attribution is required.") }
                elseif ($script:AttributionSources -cnotcontains (Get-LegacyField -Object $attribution -Name 'source')) { $errors.Add("$path.attribution.source must be a known source.") }
                elseif ((Get-LegacyField -Object $attribution -Name 'source') -cne 'extension' -and @($attribution.Keys | Where-Object { $_ -cne 'source' }).Count -gt 0) {
                    $errors.Add("$path.attribution carries keys that only the extension source may have.")
                }
            }
        }
    }

    if ($version -eq 2) {
        if ((Get-LegacyField -Object $Payload -Name 'source') -cnotin @('live', 'backfill')) { $errors.Add('source must be live or backfill.') }
        if (-not (Test-ContractText -Value (Get-LegacyField -Object $Payload -Name 'prTitle') -Maximum 256)) { $errors.Add('prTitle must be a string of 1 to 256 characters.') }

        $jiraKeys = Get-LegacyField -Object $Payload -Name 'jiraKeys'
        if ($jiraKeys -isnot [array] -or $jiraKeys.Count -gt 50) { $errors.Add('jiraKeys must be an array of at most 50 keys.') }
        else {
            if (@($jiraKeys | Where-Object { $_ -isnot [string] -or $_.Length -gt 64 -or $_ -cnotmatch $script:JiraKeyContractPattern }).Count -gt 0) { $errors.Add('jiraKeys must hold only well-formed Jira keys.') }
            if (@($jiraKeys | Select-Object -Unique).Count -ne $jiraKeys.Count) { $errors.Add('jiraKeys must be unique.') }
        }

        $files = Get-LegacyField -Object $Payload -Name 'files'
        if ($files -isnot [System.Collections.IDictionary]) { $errors.Add('files is required.') }
        else {
            $errors.AddRange([string[]]@(Test-ContractCountField -Object $files -Path 'files' -Name @('changed', 'linesTouched', 'testFilesChanged', 'testLinesTouched', 'modulesTouched')))
            $excluded = Get-LegacyField -Object $files -Name 'excluded'
            if ($excluded -isnot [System.Collections.IDictionary]) { $errors.Add('files.excluded is required.') }
            else { $errors.AddRange([string[]]@(Test-ContractCountField -Object $excluded -Path 'files.excluded' -Name @('filesChanged', 'linesTouched'))) }
        }
    }

    return $errors.ToArray()
}

#endregion

#region Retry and outcome rules

<# Seconds to wait from a Retry-After header, as delta-seconds or an HTTP-date; $null when unusable. #>
function ConvertFrom-RetryAfter {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    if ($text -match '^\d{1,9}$') { return [double]$text }

    $date = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTimeOffset]::TryParseExact($text, 'r', [cultureinfo]::InvariantCulture, $styles, [ref]$date)) {
        return [math]::Max(0.0, ($date - $Now).TotalSeconds)
    }
    return $null
}

# Exponential backoff with full jitter; a server Retry-After raises the floor, up to a ceiling.
function Get-RetryDelaySecond {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Attempt,
        [ValidateRange(0, 3600)][double]$BaseSeconds = 2,
        [ValidateRange(0, 3600)][double]$CapSeconds = 60,
        [AllowNull()][object]$RetryAfterSeconds = $null,
        [ValidateRange(0, 3600)][double]$MaxRetryAfterSeconds = 300,
        [ValidateRange(0.0, 1.0)][double]$RandomValue = (Get-Random -Minimum 0.0 -Maximum 1.0)
    )

    $ceiling = [math]::Min($CapSeconds, $BaseSeconds * [math]::Pow(2, $Attempt - 1))
    $delay = $ceiling * $RandomValue
    if ($null -ne $RetryAfterSeconds) {
        $delay = [math]::Max($delay, [math]::Min([double]$RetryAfterSeconds, $MaxRetryAfterSeconds))
    }
    return [math]::Round($delay, 3)
}

# Seconds until GitHub's rate limit clears (Retry-After, or an exhausted quota's reset); else $null.
function Get-GitHubRateLimitWaitSecond {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$RetryAfter,
        [AllowNull()][AllowEmptyString()][string]$RateLimitRemaining,
        [AllowNull()][AllowEmptyString()][string]$RateLimitReset,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $retry = ConvertFrom-RetryAfter -Value $RetryAfter -Now $Now
    if ($null -ne $retry) { return $retry }

    $reset = 0L
    if ($RateLimitRemaining -eq '0' -and [int64]::TryParse($RateLimitReset, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$reset)) {
        return [math]::Max(0.0, ([DateTimeOffset]::FromUnixTimeSeconds($reset) - $Now).TotalSeconds + 1)
    }
    return $null
}

# Outcome: stored, ignored (still success), accepted, auth-failed (abort), rejected, transient-error
# or transport-error (retry). The body is read for its status only and never returned.
function Resolve-IngestOutcome {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [AllowNull()][AllowEmptyString()][string]$Body = ''
    )

    $result = { param($o, $s, $r, $a, $reason) [pscustomobject]@{ Outcome = $o; Success = $s; Retryable = $r; Abort = $a; Reason = $reason } }

    if ($StatusCode -ge 200 -and $StatusCode -lt 300) {
        $status = $null
        try { $status = (ConvertFrom-Json -InputObject $Body -ErrorAction Stop).status } catch { $status = $null }
        $outcome = switch ($status) { 'stored' { 'stored' } 'ignored' { 'ignored' } default { 'accepted' } }
        return & $result $outcome $true $false $false ''
    }
    if ($StatusCode -eq 0) { return & $result 'transport-error' $false $true $false 'no response from the ingest endpoint' }
    if ($StatusCode -eq 401) { return & $result 'auth-failed' $false $false $true 'the ingest credential was rejected' }
    if ($StatusCode -eq 408 -or $StatusCode -eq 429 -or $StatusCode -ge 500) { return & $result 'transient-error' $false $true $false "HTTP $StatusCode" }

    $reason = switch ($StatusCode) {
        400 { 'the payload failed validation at the ingest endpoint' }
        403 { 'the repository is not permitted or not mapped to a project' }
        413 { 'the payload is larger than the ingest endpoint accepts' }
        default { "HTTP $StatusCode" }
    }
    return & $result 'rejected' $false $false $false $reason
}

#endregion
