BeforeAll {
    . (Join-Path $PSScriptRoot 'LegacyMigration.Helpers.ps1')

    # A document as mongoexport --jsonFormat=relaxed writes it, unwrapped the way the publisher reads it.
    function Get-LegacyDocument {
        $json = @'
{"_id":{"$oid":"65f0c0ffee0000000000abcd"},"prNumber":42,"repository":"DEFRA/example","sourceBranch":"feature/MMO-12-charts","targetBranch":"main","buildId":"1234","calculatedAt":{"$date":"2024-03-05T10:20:30.123Z"},"prCreatedAt":{"$date":"2024-03-01T09:00:00Z"},"firstCommitAt":{"$date":"2024-03-02T10:00:00Z"},"lastCommitAt":{"$date":"2024-03-04T10:00:00Z"},"prMergedAt":{"$date":"2024-03-05T10:00:00Z"},"receivedAt":{"$date":"2024-03-05T10:21:00Z"},"projectSlug":"internal","updateCount":3,"classificationOverrides":[],"complexity":{"score":3},"summary":{"totalCommits":2,"copilotAssistedCommits":1,"humanAuthoredCommits":1,"copilotAssistedRate":50,"totalLinesTouched":30,"copilotAssistedLines":10,"humanAuthoredLines":20,"copilotAssistedLineRate":33.3},"contributorBreakdown":[{"contributor":"Alex Example","totalCommits":2,"copilotAssisted":1,"humanAuthored":1,"linesAdded":20,"linesDeleted":10,"linesTouched":30,"netLines":10,"copilotAssistedLines":10,"humanAuthoredLines":20}],"commitBreakdown":[{"commit":"aaaa111","committedAt":{"$date":"2024-03-02T10:00:00Z"},"author":"Alex Example","subject":"MMO-12 add chart","classification":"Copilot-assisted","filesChanged":2,"linesAdded":8,"linesDeleted":2,"linesTouched":10,"netLines":6},{"commit":"bbbb222","committedAt":{"$date":{"$numberLong":"1709460000000"}},"author":"Alex Example","subject":"Fix axis CR-7","classification":"Human-authored","filesChanged":3,"linesAdded":12,"linesDeleted":8,"linesTouched":20,"netLines":4}]}
'@
        return ConvertFrom-ExtendedJsonValue -Value (ConvertFrom-JsonLine -Line $json)
    }

    function Get-FilesBlock {
        return [ordered]@{
            changed = 3; linesTouched = 40; testFilesChanged = 1; testLinesTouched = 5; modulesTouched = 2
            excluded = [ordered]@{ filesChanged = 0; linesTouched = 0 }
        }
    }

    function Get-ValidPayload {
        return ConvertTo-MigratedPayload -Legacy (Get-LegacyDocument) -PrTitle 'MMO-12 Add charts' -Files (Get-FilesBlock)
    }
}

Describe 'ConvertFrom-LegacyDate' {
    It 'Reads a $date wrapper holding an ISO string' {
        ConvertFrom-LegacyDate -Value @{ '$date' = '2024-03-05T10:20:30.123Z' } | Should -Be '2024-03-05T10:20:30.123Z'
    }

    It 'Reads a $date wrapper holding epoch milliseconds' {
        ConvertFrom-LegacyDate -Value @{ '$date' = @{ '$numberLong' = '1709460000000' } } | Should -Be '2024-03-03T10:00:00.000Z'
    }

    It 'Reads a bare epoch in milliseconds' {
        ConvertFrom-LegacyDate -Value 1709460000000 | Should -Be '2024-03-03T10:00:00.000Z'
    }

    It 'Converts an offset to UTC' {
        ConvertFrom-LegacyDate -Value '2024-06-01T12:00:00+01:00' | Should -Be '2024-06-01T11:00:00.000Z'
    }

    It 'Reads a string with no offset as UTC' {
        ConvertFrom-LegacyDate -Value '2024-06-01T12:00:00' | Should -Be '2024-06-01T12:00:00.000Z'
    }

    It 'Pads and truncates to milliseconds' {
        ConvertFrom-LegacyDate -Value '2024-06-01T12:00:00.1234567Z' | Should -Be '2024-06-01T12:00:00.123Z'
    }

    It 'Reads a [datetime] of each kind as the same instant' {
        $utc = [datetime]::new(2024, 6, 1, 12, 0, 0, [System.DateTimeKind]::Utc)
        $unspecified = [datetime]::new(2024, 6, 1, 12, 0, 0, [System.DateTimeKind]::Unspecified)
        ConvertFrom-LegacyDate -Value $utc | Should -Be '2024-06-01T12:00:00.000Z'
        ConvertFrom-LegacyDate -Value $unspecified | Should -Be '2024-06-01T12:00:00.000Z'
        ConvertFrom-LegacyDate -Value $utc.ToLocalTime() | Should -Be '2024-06-01T12:00:00.000Z'
    }

    It 'Reads a [DateTimeOffset]' {
        ConvertFrom-LegacyDate -Value ([DateTimeOffset]::new(2024, 6, 1, 12, 0, 0, [timespan]::FromHours(2))) | Should -Be '2024-06-01T10:00:00.000Z'
    }

    It 'Returns null for null and blank values' {
        ConvertFrom-LegacyDate -Value $null | Should -BeNullOrEmpty
        ConvertFrom-LegacyDate -Value '' | Should -BeNullOrEmpty
        ConvertFrom-LegacyDate -Value '   ' | Should -BeNullOrEmpty
    }

    It 'Throws for <Name> without echoing the value' -ForEach @(
        @{ Name = 'garbage text'; Value = 'not-a-date-secret' }
        @{ Name = 'a boolean'; Value = $true }
        @{ Name = 'an unknown object'; Value = @{ other = 1 } }
        @{ Name = 'an unparsable $numberLong'; Value = @{ '$numberLong' = 'abc' } }
        @{ Name = 'an array'; Value = @(1, 2) }
    ) {
        { ConvertFrom-LegacyDate -Value $Value } | Should -Throw -ExceptionType ([System.FormatException])
        try { ConvertFrom-LegacyDate -Value $Value } catch { $_.Exception.Message | Should -Not -Match 'secret' }
    }
}

Describe 'ConvertFrom-JsonLine' {
    It 'Parses a line to a hashtable and keeps ISO strings readable as dates' {
        $doc = ConvertFrom-JsonLine -Line '{"a":{"$date":"2024-03-05T10:20:30.123Z"}}'

        $doc | Should -BeOfType [hashtable]
        ConvertFrom-LegacyDate -Value $doc['a'] | Should -Be '2024-03-05T10:20:30.123Z'
    }

    It 'Throws for malformed JSON' {
        { ConvertFrom-JsonLine -Line '{"a":' } | Should -Throw
    }

    It 'Returns an array root as one value' {
        $parsed = ConvertFrom-JsonLine -Line '[{"a":1},{"a":2}]'

        , $parsed | Should -BeOfType [array]
        $parsed.Count | Should -Be 2
    }

    It 'Returns an empty array root as an empty array' {
        $parsed = ConvertFrom-JsonLine -Line '[]'

        , $parsed | Should -BeOfType [array]
        $parsed.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-ExtendedJsonValue' {
    It 'Unwraps each Extended JSON wrapper' {
        $doc = ConvertFrom-ExtendedJsonValue -Value @{
            id     = @{ '$oid' = '65f0c0ffee0000000000abcd' }
            when   = @{ '$date' = '2024-03-05T10:20:30Z' }
            long   = @{ '$numberLong' = '9007199254740993' }
            int    = @{ '$numberInt' = '7' }
            double = @{ '$numberDouble' = '1.5' }
            nan    = @{ '$numberDouble' = 'NaN' }
        }

        $doc['id'] | Should -Be '65f0c0ffee0000000000abcd'
        $doc['when'] | Should -Be '2024-03-05T10:20:30.000Z'
        $doc['long'] | Should -BeOfType [int64]
        $doc['long'] | Should -Be 9007199254740993
        $doc['int'] | Should -BeOfType [int]
        $doc['double'] | Should -Be 1.5
        [double]::IsNaN($doc['nan']) | Should -BeTrue
    }

    It 'Unwraps wrappers nested in objects and arrays' {
        $doc = ConvertFrom-ExtendedJsonValue -Value @{ list = @(@{ at = @{ '$date' = '2024-03-05T10:20:30Z' } }) }

        $doc['list'][0]['at'] | Should -Be '2024-03-05T10:20:30.000Z'
    }

    It 'Keeps an empty array as an array' {
        $doc = ConvertFrom-ExtendedJsonValue -Value @{ list = @() }

        , $doc['list'] | Should -BeOfType [array]
        @($doc['list']).Count | Should -Be 0
    }

    It 'Keeps a one-element array as an array' {
        $doc = ConvertFrom-ExtendedJsonValue -Value @{ list = @('only') }

        , $doc['list'] | Should -BeOfType [array]
    }

    It 'Passes plain scalars and null through' {
        $doc = ConvertFrom-ExtendedJsonValue -Value @{ s = 'text'; n = 5; b = $true; z = $null }

        $doc['s'] | Should -Be 'text'
        $doc['n'] | Should -Be 5
        $doc['b'] | Should -BeTrue
        $doc['z'] | Should -BeNullOrEmpty
    }

    It 'Leaves an unknown single-key object and a multi-key $date object alone' {
        $doc = ConvertFrom-ExtendedJsonValue -Value @{ regex = @{ '$regex' = 'a.*' }; mixed = @{ '$date' = '2024-03-05T10:20:30Z'; extra = 1 } }

        $doc['regex']['$regex'] | Should -Be 'a.*'
        $doc['mixed'].Keys.Count | Should -Be 2
    }

    It 'Throws for an unparsable $numberLong' {
        { ConvertFrom-ExtendedJsonValue -Value @{ '$numberLong' = 'abc' } } | Should -Throw
    }

    It 'Does not change its input' {
        $source = @{ when = @{ '$date' = '2024-03-05T10:20:30Z' } }

        $null = ConvertFrom-ExtendedJsonValue -Value $source

        $source['when'] | Should -BeOfType [hashtable]
    }
}

Describe 'ConvertTo-GlobRegex' {
    It 'Matches <Path> against <Glob>: <Expected>' -ForEach @(
        @{ Glob = '**/*.test.*'; Path = 'a.test.js'; Expected = $true }
        @{ Glob = '**/*.test.*'; Path = 'src/deep/a.test.js'; Expected = $true }
        @{ Glob = '**/*.test.*'; Path = 'src/a.js'; Expected = $false }
        @{ Glob = '**/test/**'; Path = 'test/a.js'; Expected = $true }
        @{ Glob = '**/test/**'; Path = 'a/b/test/c/d.js'; Expected = $true }
        @{ Glob = '**/test/**'; Path = 'a/latest/c.js'; Expected = $false }
        @{ Glob = 'docs/**'; Path = 'docs/a/b.md'; Expected = $true }
        @{ Glob = 'docs/**'; Path = 'other/docs/a.md'; Expected = $false }
        @{ Glob = 'src/*.js'; Path = 'src/a.js'; Expected = $true }
        @{ Glob = 'src/*.js'; Path = 'src/a/b.js'; Expected = $false }
        @{ Glob = 'a/b.js'; Path = 'a/b.js'; Expected = $true }
        @{ Glob = 'a/b.js'; Path = 'a/bxjs'; Expected = $false }
        @{ Glob = 'file?.txt'; Path = 'file1.txt'; Expected = $true }
        @{ Glob = 'file?.txt'; Path = 'file12.txt'; Expected = $false }
        @{ Glob = 'file?.txt'; Path = 'file/.txt'; Expected = $false }
        @{ Glob = 'v[0-9].md'; Path = 'v7.md'; Expected = $true }
        @{ Glob = 'v[0-9].md'; Path = 'vx.md'; Expected = $false }
        @{ Glob = 'v[!0-9].md'; Path = 'vx.md'; Expected = $true }
        @{ Glob = 'v[!0-9].md'; Path = 'v7.md'; Expected = $false }
        @{ Glob = '**'; Path = 'anything/at/all.txt'; Expected = $true }
        @{ Glob = 'a\*b'; Path = 'a*b'; Expected = $true }
        @{ Glob = 'a\*b'; Path = 'axb'; Expected = $false }
        @{ Glob = 'a.b+c'; Path = 'a.b+c'; Expected = $true }
        @{ Glob = 'a.b+c'; Path = 'aXb+c'; Expected = $false }
        @{ Glob = 'a[b'; Path = 'a[b'; Expected = $true }
    ) {
        [regex]::IsMatch($Path, (ConvertTo-GlobRegex -Glob $Glob)) | Should -Be $Expected
    }

    It 'Anchors the whole path' {
        [regex]::IsMatch('xa.js', (ConvertTo-GlobRegex -Glob 'a.js')) | Should -BeFalse
        [regex]::IsMatch('a.jsx', (ConvertTo-GlobRegex -Glob 'a.js')) | Should -BeFalse
    }
}

Describe 'ConvertFrom-AnalyticsRuleText' {
    It 'Converts entries and drops comments and blank lines' {
        $text = "# comment`r`n`r`ndocs/`r`n*.feature`r`ne2e/spec.js`r`n/rooted.txt`r`n"

        ConvertFrom-AnalyticsRuleText -Text $text | Should -Be @('docs/**', '**/*.feature', 'e2e/spec.js', '**/rooted.txt')
    }

    It 'Returns an empty array for null or empty text' {
        @(ConvertFrom-AnalyticsRuleText -Text $null).Count | Should -Be 0
        @(ConvertFrom-AnalyticsRuleText -Text '').Count | Should -Be 0
    }
}

Describe 'Get-PathBucket' {
    It 'Puts <Path> in <Expected>' -ForEach @(
        @{ Path = 'src/app/index.js'; Expected = 'nonTest' }
        @{ Path = 'README.md'; Expected = 'nonTest' }
        @{ Path = 'src/app/index.test.js'; Expected = 'test' }
        @{ Path = 'index.spec.ts'; Expected = 'test' }
        @{ Path = 'test/helper.js'; Expected = 'test' }
        @{ Path = 'src/__tests__/a.js'; Expected = 'test' }
        @{ Path = 'test-helpers/fixture.js'; Expected = 'test' }
        @{ Path = 'scripts/Get-Thing.Tests.ps1'; Expected = 'test' }
        @{ Path = 'pkg/util_test.go'; Expected = 'test' }
        @{ Path = 'src/main/FooTest.java'; Expected = 'test' }
        @{ Path = 'src/Foo.Tests.cs'; Expected = 'test' }
        @{ Path = 'package-lock.json'; Expected = 'excluded' }
        @{ Path = 'ui/yarn.lock'; Expected = 'excluded' }
        @{ Path = 'pnpm-lock.yaml'; Expected = 'excluded' }
        @{ Path = 'dist/app.min.js'; Expected = 'excluded' }
        @{ Path = 'dist/app.min.css'; Expected = 'excluded' }
        @{ Path = 'dist/app.js.map'; Expected = 'excluded' }
        @{ Path = 'src/__snapshots__/a.test.js.snap'; Expected = 'excluded' }
        @{ Path = '.analytics/abc/summary.json'; Expected = 'skipped' }
        @{ Path = '.analytics/abc/files/src/a.js.json'; Expected = 'skipped' }
        @{ Path = 'sub/.analytics/x.json'; Expected = 'nonTest' }
    ) {
        Get-PathBucket -Path $Path | Should -Be $Expected
    }

    It 'Adds .analyticsignore globs to the built-in exclusions' {
        Get-PathBucket -Path 'docs/guide.md' -IgnoreGlob @('docs/**') | Should -Be 'excluded'
        Get-PathBucket -Path 'package-lock.json' -IgnoreGlob @('docs/**') | Should -Be 'excluded'
    }

    It 'Adds .analyticstests globs to the built-in test globs' {
        Get-PathBucket -Path 'e2e/login.feature' -TestGlob @('**/*.feature') | Should -Be 'test'
        Get-PathBucket -Path 'src/a.test.js' -TestGlob @('**/*.feature') | Should -Be 'test'
    }

    It 'Lets an exclusion win over a test glob' {
        Get-PathBucket -Path 'src/a.test.js' -IgnoreGlob @('src/**') | Should -Be 'excluded'
    }

    It 'Matches case-sensitively, as git does' {
        Get-PathBucket -Path 'src/A.TEST.js' | Should -Be 'nonTest'
    }
}

Describe 'ConvertTo-FilesBlockFromPullFile' {
    It 'Splits files and lines into non-test, test and excluded' {
        $files = @(
            @{ filename = 'src/app/a.js'; additions = 10; deletions = 2 }
            @{ filename = 'src/app/a.test.js'; additions = 5; deletions = 0 }
            @{ filename = 'package-lock.json'; additions = 100; deletions = 50 }
            @{ filename = 'docs/x.md'; additions = 4; deletions = 1 }
            @{ filename = '.analytics/abc/summary.json'; additions = 9; deletions = 9 }
            @{ filename = 'README.md'; additions = 1; deletions = 1 }
            @{ filename = 'logo.png'; additions = 0; deletions = 0 }
        )

        $block = ConvertTo-FilesBlockFromPullFile -File $files -IgnoreGlob @('docs/**')

        $block['changed'] | Should -Be 3
        $block['linesTouched'] | Should -Be 14
        $block['testFilesChanged'] | Should -Be 1
        $block['testLinesTouched'] | Should -Be 5
        $block['modulesTouched'] | Should -Be 2
        $block['excluded']['filesChanged'] | Should -Be 2
        $block['excluded']['linesTouched'] | Should -Be 155
    }

    It 'Counts a rename with no content change as a file with no lines' {
        $block = ConvertTo-FilesBlockFromPullFile -File @(@{ filename = 'src/app/b.js'; additions = 0; deletions = 0; status = 'renamed' })

        $block['changed'] | Should -Be 1
        $block['linesTouched'] | Should -Be 0
    }

    It 'Counts distinct modules once' {
        $files = @(
            @{ filename = 'src/app/a.js'; additions = 1; deletions = 0 }
            @{ filename = 'src/app/b.js'; additions = 1; deletions = 0 }
            @{ filename = 'src/lib/c.js'; additions = 1; deletions = 0 }
        )

        (ConvertTo-FilesBlockFromPullFile -File $files)['modulesTouched'] | Should -Be 2
    }

    It 'Returns zeros for no files, a null list, or entries with no filename' {
        foreach ($sample in @(@(), $null, @(@{ additions = 5 }, $null))) {
            $block = ConvertTo-FilesBlockFromPullFile -File $sample
            $block['changed'] | Should -Be 0
            $block['linesTouched'] | Should -Be 0
            $block['modulesTouched'] | Should -Be 0
            $block['excluded']['filesChanged'] | Should -Be 0
        }
    }

    It 'Treats missing or non-numeric line counts as zero' {
        $block = ConvertTo-FilesBlockFromPullFile -File @(@{ filename = 'a.js'; additions = 'x' })

        $block['changed'] | Should -Be 1
        $block['linesTouched'] | Should -Be 0
    }
}

Describe 'Copy-AllowedKey' {
    It 'Copies only the named keys that are present' {
        $copy = Copy-AllowedKey -Source @{ a = 1; b = 2; secret = 'x' } -Key @('a', 'c')

        @($copy.Keys) | Should -Be @('a')
    }

    It 'Skips null values' {
        $copy = Copy-AllowedKey -Source @{ a = $null; b = 1 } -Key @('a', 'b')

        @($copy.Keys) | Should -Be @('b')
    }

    It 'Coerces whole numbers to integers and leaves other values alone' {
        $copy = Copy-AllowedKey -Source @{ a = 5.0; b = 5.5; c = 'x'; d = @{ '$numberLong' = '1' } } -Key @('a', 'b', 'c', 'd') -IntegerKey @('a', 'b', 'c', 'd')

        $copy['a'] | Should -BeOfType [int64]
        $copy['b'] | Should -Be 5.5
        $copy['c'] | Should -Be 'x'
    }

    It 'Reads an object source' {
        (Copy-AllowedKey -Source ([pscustomobject]@{ a = 1; b = 2 }) -Key @('a'))['a'] | Should -Be 1
    }

    It 'Returns an empty result for a null source' {
        (Copy-AllowedKey -Source $null -Key @('a')).Count | Should -Be 0
    }
}

Describe 'Get-LegacyAttribution' {
    It 'Maps <Classification> to <Source>' -ForEach @(
        @{ Classification = 'Copilot-assisted'; Source = 'legacy-trailer' }
        @{ Classification = 'Human-authored'; Source = 'none' }
        @{ Classification = 'Rebase'; Source = 'none' }
        @{ Classification = 'Dependabot'; Source = 'none' }
        @{ Classification = ''; Source = 'none' }
        @{ Classification = 'copilot-assisted'; Source = 'none' }
    ) {
        $attribution = Get-LegacyAttribution -Classification $Classification

        $attribution['source'] | Should -Be $Source
        $attribution.Count | Should -Be 1
    }
}

Describe 'ConvertTo-MigratedPayload' {
    It 'Sets the v2 envelope' {
        $payload = Get-ValidPayload

        $payload['schemaVersion'] | Should -Be 2
        $payload['source'] | Should -Be 'backfill'
        $payload['prTitle'] | Should -Be 'MMO-12 Add charts'
        $payload['files']['changed'] | Should -Be 3
    }

    It 'Never carries Mongo-internal fields' {
        $keys = @((Get-ValidPayload).Keys)

        foreach ($internal in '_id', 'receivedAt', 'projectSlug', 'updateCount', 'classificationOverrides', 'complexity') {
            $keys | Should -Not -Contain $internal
        }
    }

    It 'Writes every date as an ISO-8601 UTC string' {
        $payload = Get-ValidPayload

        $payload['calculatedAt'] | Should -Be '2024-03-05T10:20:30.123Z'
        $payload['prCreatedAt'] | Should -Be '2024-03-01T09:00:00.000Z'
        $payload['prMergedAt'] | Should -Be '2024-03-05T10:00:00.000Z'
        $payload['commitBreakdown'][0]['committedAt'] | Should -Be '2024-03-02T10:00:00.000Z'
        $payload['commitBreakdown'][1]['committedAt'] | Should -Be '2024-03-03T10:00:00.000Z'
    }

    It 'Casts a numeric buildId to a string' {
        $legacy = Get-LegacyDocument
        $legacy['buildId'] = 98765

        (ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock))['buildId'] | Should -Be '98765'
    }

    It 'Omits a null, empty or missing sourceBranch' {
        foreach ($value in $null, '', '  ') {
            $legacy = Get-LegacyDocument
            $legacy['sourceBranch'] = $value
            (ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)).Contains('sourceBranch') | Should -BeFalse
        }
        $legacy = Get-LegacyDocument
        $legacy.Remove('sourceBranch')
        (ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)).Contains('sourceBranch') | Should -BeFalse
    }

    It 'Omits optional dates the legacy document lacks' {
        $legacy = Get-LegacyDocument
        $legacy.Remove('prMergedAt')
        $legacy['firstCommitAt'] = $null

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)

        $payload.Contains('prMergedAt') | Should -BeFalse
        $payload.Contains('firstCommitAt') | Should -BeFalse
    }

    It 'Maps attribution from the classification' {
        $commits = (Get-ValidPayload)['commitBreakdown']

        $commits[0]['attribution']['source'] | Should -Be 'legacy-trailer'
        $commits[1]['attribution']['source'] | Should -Be 'none'
    }

    It 'Derives Jira keys from the branch, title and counted commit subjects' {
        $payload = ConvertTo-MigratedPayload -Legacy (Get-LegacyDocument) -PrTitle 'ABC-9 Add charts' -Files (Get-FilesBlock)

        $payload['jiraKeys'] | Should -Be @('ABC-9', 'CR-7', 'MMO-12')
    }

    It 'Ignores Jira keys in subjects of excluded commits' {
        $legacy = Get-LegacyDocument
        $legacy['commitBreakdown'][1]['classification'] = 'Dependabot'

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 'Tidy' -Files (Get-FilesBlock)

        $payload['jiraKeys'] | Should -Not -Contain 'CR-7'
    }

    It 'Honours a Jira project allow-list' {
        $payload = ConvertTo-MigratedPayload -Legacy (Get-LegacyDocument) -PrTitle 'Tidy' -Files (Get-FilesBlock) -JiraProjectKey @('CR')

        $payload['jiraKeys'] | Should -Be @('CR-7')
    }

    It 'Emits an empty jiraKeys array when there are none' {
        $legacy = Get-LegacyDocument
        $legacy['sourceBranch'] = 'main'
        $legacy['commitBreakdown'][0]['subject'] = 'tidy'
        $legacy['commitBreakdown'][1]['subject'] = 'tidy'

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 'Tidy' -Files (Get-FilesBlock)

        , $payload['jiraKeys'] | Should -BeOfType [string[]]
        @($payload['jiraKeys']).Count | Should -Be 0
        (ConvertTo-Json -InputObject $payload -Depth 5 -Compress) | Should -Match '"jiraKeys":\[\]'
    }

    It 'Truncates a long title and subject to the contract limits' {
        $legacy = Get-LegacyDocument
        $legacy['commitBreakdown'][0]['subject'] = 'x' * 2000

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle ('t' * 400) -Files (Get-FilesBlock)

        $payload['prTitle'].Length | Should -Be 256
        $payload['commitBreakdown'][0]['subject'].Length | Should -Be 1024
    }

    It 'Defaults a missing subject to an empty string' {
        $legacy = Get-LegacyDocument
        $legacy['commitBreakdown'][0].Remove('subject')

        (ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock))['commitBreakdown'][0]['subject'] | Should -Be ''
    }

    It 'Drops unknown keys inside the summary, contributors and commits' {
        $legacy = Get-LegacyDocument
        $legacy['summary']['extra'] = 1
        $legacy['contributorBreakdown'][0]['email'] = 'someone@example.test'
        $legacy['commitBreakdown'][0]['body'] = 'private'

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)

        $payload['summary'].Contains('extra') | Should -BeFalse
        $payload['contributorBreakdown'][0].Contains('email') | Should -BeFalse
        $payload['commitBreakdown'][0].Contains('body') | Should -BeFalse
    }

    It 'Does not change the legacy document' {
        $legacy = Get-LegacyDocument

        $null = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)

        $legacy.Contains('_id') | Should -BeTrue
        $legacy['commitBreakdown'][0].Contains('attribution') | Should -BeFalse
    }

    It 'Throws for an unreadable root date, naming the field and not the value' {
        $legacy = Get-LegacyDocument
        $legacy['prMergedAt'] = 'tuesday-ish'

        { ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock) } | Should -Throw "*prMergedAt*"
        try { ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock) } catch { $_.Exception.Message | Should -Not -Match 'tuesday' }
    }

    It 'Throws for an unreadable commit date, naming the index' {
        $legacy = Get-LegacyDocument
        $legacy['commitBreakdown'][1]['committedAt'] = 'nope'

        { ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock) } | Should -Throw '*commitBreakdown`[1`].committedAt*'
    }

    It 'Keeps a malformed entry so validation can report it' {
        $legacy = Get-LegacyDocument
        $legacy['commitBreakdown'] = @('not-an-object')

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)

        @($payload['commitBreakdown']).Count | Should -Be 1
        @(Test-MigratedPayload -Payload $payload) | Should -Contain 'commitBreakdown[0].commit must be a string of 1 to 64 characters.'
    }

    It 'Yields empty arrays when the legacy arrays are missing' {
        $legacy = Get-LegacyDocument
        $legacy.Remove('commitBreakdown')
        $legacy.Remove('contributorBreakdown')

        $payload = ConvertTo-MigratedPayload -Legacy $legacy -PrTitle 't' -Files (Get-FilesBlock)

        @($payload['commitBreakdown']).Count | Should -Be 0
        @($payload['contributorBreakdown']).Count | Should -Be 0
    }

    It 'Builds a v1 payload with none of the v2 fields' {
        $payload = ConvertTo-MigratedPayload -Legacy (Get-LegacyDocument) -Version 1

        $payload['schemaVersion'] | Should -Be 1
        foreach ($v2 in 'source', 'prTitle', 'jiraKeys', 'files') { $payload.Contains($v2) | Should -BeFalse }
        $payload['commitBreakdown'][0].Contains('attribution') | Should -BeFalse
        @(Test-MigratedPayload -Payload $payload).Count | Should -Be 0
    }
}

Describe 'Test-MigratedPayload' {
    It 'Accepts a payload built from a well-formed legacy document' {
        @(Test-MigratedPayload -Payload (Get-ValidPayload)).Count | Should -Be 0
    }

    It 'Accepts a document that has passed through a JSON round trip' {
        $json = ConvertTo-Json -InputObject (Get-ValidPayload) -Depth 10 -Compress
        $parsed = ConvertFrom-JsonLine -Line $json

        @(Test-MigratedPayload -Payload $parsed).Count | Should -Be 0
    }

    It 'Reports <Name>' -ForEach @(
        @{ Name = 'a wrong schemaVersion'; Mutate = { param($p) $p['schemaVersion'] = 3 }; Expect = 'schemaVersion must be 1 or 2.' }
        @{ Name = 'a zero prNumber'; Mutate = { param($p) $p['prNumber'] = 0 }; Expect = 'prNumber must be an integer of 1 or more.' }
        @{ Name = 'a fractional prNumber'; Mutate = { param($p) $p['prNumber'] = 1.5 }; Expect = 'prNumber must be an integer of 1 or more.' }
        @{ Name = 'a missing repository'; Mutate = { param($p) $p.Remove('repository') }; Expect = 'repository must be a string of 1 to 512 characters.' }
        @{ Name = 'a missing targetBranch'; Mutate = { param($p) $p.Remove('targetBranch') }; Expect = 'targetBranch must be a string of 1 to 512 characters.' }
        @{ Name = 'a numeric buildId'; Mutate = { param($p) $p['buildId'] = 5 }; Expect = 'buildId must be a string of 1 to 128 characters.' }
        @{ Name = 'an over-long buildId'; Mutate = { param($p) $p['buildId'] = 'b' * 129 }; Expect = 'buildId must be a string of 1 to 128 characters.' }
        @{ Name = 'a missing calculatedAt'; Mutate = { param($p) $p.Remove('calculatedAt') }; Expect = 'calculatedAt must be an ISO-8601 date-time with an offset.' }
        @{ Name = 'a date with no offset'; Mutate = { param($p) $p['prMergedAt'] = '2024-03-05T10:00:00' }; Expect = 'prMergedAt must be an ISO-8601 date-time with an offset.' }
        @{ Name = 'a missing summary'; Mutate = { param($p) $p.Remove('summary') }; Expect = 'summary is required.' }
        @{ Name = 'a negative summary count'; Mutate = { param($p) $p['summary']['totalCommits'] = -1 }; Expect = 'summary.totalCommits must be an integer of 0 or more.' }
        @{ Name = 'a missing summary count'; Mutate = { param($p) $p['summary'].Remove('totalLinesTouched') }; Expect = 'summary.totalLinesTouched is required.' }
        @{ Name = 'a rate above 100'; Mutate = { param($p) $p['summary']['copilotAssistedRate'] = 100.5 }; Expect = 'summary.copilotAssistedRate must be a number from 0 to 100.' }
        @{ Name = 'a bad optional summary count'; Mutate = { param($p) $p['summary']['rebaseCommits'] = 'x' }; Expect = 'summary.rebaseCommits must be an integer of 0 or more.' }
        @{ Name = 'no contributors'; Mutate = { param($p) $p['contributorBreakdown'] = @() }; Expect = 'contributorBreakdown must be an array of 1 to 200 entries.' }
        @{ Name = 'too many contributors'; Mutate = { param($p) $p['contributorBreakdown'] = @(1..201 | ForEach-Object { $p['contributorBreakdown'][0] }) }; Expect = 'contributorBreakdown must be an array of 1 to 200 entries.' }
        @{ Name = 'a blank contributor'; Mutate = { param($p) $p['contributorBreakdown'][0]['contributor'] = '' }; Expect = 'contributorBreakdown[0].contributor must be a string of 1 to 256 characters.' }
        @{ Name = 'a missing contributor count'; Mutate = { param($p) $p['contributorBreakdown'][0].Remove('linesAdded') }; Expect = 'contributorBreakdown[0].linesAdded is required.' }
        @{ Name = 'a non-integer netLines'; Mutate = { param($p) $p['contributorBreakdown'][0]['netLines'] = 1.5 }; Expect = 'contributorBreakdown[0].netLines must be an integer.' }
        @{ Name = 'no commits'; Mutate = { param($p) $p['commitBreakdown'] = @() }; Expect = 'commitBreakdown must be an array of 1 to 1000 entries.' }
        @{ Name = 'too many commits'; Mutate = { param($p) $p['commitBreakdown'] = @(1..1001 | ForEach-Object { $p['commitBreakdown'][0] }) }; Expect = 'commitBreakdown must be an array of 1 to 1000 entries.' }
        @{ Name = 'an over-long commit hash'; Mutate = { param($p) $p['commitBreakdown'][0]['commit'] = 'a' * 65 }; Expect = 'commitBreakdown[0].commit must be a string of 1 to 64 characters.' }
        @{ Name = 'a missing author'; Mutate = { param($p) $p['commitBreakdown'][1].Remove('author') }; Expect = 'commitBreakdown[1].author must be a string of 1 to 256 characters.' }
        @{ Name = 'an over-long subject'; Mutate = { param($p) $p['commitBreakdown'][0]['subject'] = 's' * 1025 }; Expect = 'commitBreakdown[0].subject must be a string of at most 1024 characters.' }
        @{ Name = 'a bad commit date'; Mutate = { param($p) $p['commitBreakdown'][0]['committedAt'] = 'yesterday' }; Expect = 'commitBreakdown[0].committedAt must be an ISO-8601 date-time with an offset.' }
        @{ Name = 'an unknown classification'; Mutate = { param($p) $p['commitBreakdown'][0]['classification'] = 'copilot-assisted' }; Expect = 'commitBreakdown[0].classification must be a known classification.' }
        @{ Name = 'a negative commit count'; Mutate = { param($p) $p['commitBreakdown'][0]['linesAdded'] = -3 }; Expect = 'commitBreakdown[0].linesAdded must be an integer of 0 or more.' }
        @{ Name = 'a missing attribution'; Mutate = { param($p) $p['commitBreakdown'][0].Remove('attribution') }; Expect = 'commitBreakdown[0].attribution is required.' }
        @{ Name = 'an unknown attribution source'; Mutate = { param($p) $p['commitBreakdown'][0]['attribution'] = @{ source = 'guess' } }; Expect = 'commitBreakdown[0].attribution.source must be a known source.' }
        @{ Name = 'line counts on a non-extension attribution'; Mutate = { param($p) $p['commitBreakdown'][0]['attribution']['typedLines'] = 4 }; Expect = 'commitBreakdown[0].attribution carries keys that only the extension source may have.' }
        @{ Name = 'a wrong source'; Mutate = { param($p) $p['source'] = 'replay' }; Expect = 'source must be live or backfill.' }
        @{ Name = 'an empty prTitle'; Mutate = { param($p) $p['prTitle'] = '' }; Expect = 'prTitle must be a string of 1 to 256 characters.' }
        @{ Name = 'an over-long prTitle'; Mutate = { param($p) $p['prTitle'] = 't' * 257 }; Expect = 'prTitle must be a string of 1 to 256 characters.' }
        @{ Name = 'missing jiraKeys'; Mutate = { param($p) $p.Remove('jiraKeys') }; Expect = 'jiraKeys must be an array of at most 50 keys.' }
        @{ Name = 'too many jiraKeys'; Mutate = { param($p) $p['jiraKeys'] = @(1..51 | ForEach-Object { "MMO-$_" }) }; Expect = 'jiraKeys must be an array of at most 50 keys.' }
        @{ Name = 'a malformed jira key'; Mutate = { param($p) $p['jiraKeys'] = @('mmo-1') }; Expect = 'jiraKeys must hold only well-formed Jira keys.' }
        @{ Name = 'duplicate jira keys'; Mutate = { param($p) $p['jiraKeys'] = @('MMO-1', 'MMO-1') }; Expect = 'jiraKeys must be unique.' }
        @{ Name = 'missing files'; Mutate = { param($p) $p.Remove('files') }; Expect = 'files is required.' }
        @{ Name = 'a missing files count'; Mutate = { param($p) $p['files'].Remove('modulesTouched') }; Expect = 'files.modulesTouched is required.' }
        @{ Name = 'missing files.excluded'; Mutate = { param($p) $p['files'].Remove('excluded') }; Expect = 'files.excluded is required.' }
        @{ Name = 'a bad files.excluded count'; Mutate = { param($p) $p['files']['excluded']['filesChanged'] = -1 }; Expect = 'files.excluded.filesChanged must be an integer of 0 or more.' }
    ) {
        $payload = Get-ValidPayload
        & $Mutate $payload

        @(Test-MigratedPayload -Payload $payload) | Should -Contain $Expect
    }

    It 'Never includes a document value in a message' {
        $payload = Get-ValidPayload
        $payload['commitBreakdown'][0]['author'] = ''
        $payload['prTitle'] = ''

        (@(Test-MigratedPayload -Payload $payload) -join ' ') | Should -Not -Match 'Alex Example'
    }

    It 'Treats a payload with no schemaVersion as v1' {
        $payload = ConvertTo-MigratedPayload -Legacy (Get-LegacyDocument) -Version 1
        $payload.Remove('schemaVersion')

        @(Test-MigratedPayload -Payload $payload).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-RetryAfter' {
    It 'Reads delta-seconds' {
        ConvertFrom-RetryAfter -Value '120' | Should -Be 120
        ConvertFrom-RetryAfter -Value ' 7 ' | Should -Be 7
        ConvertFrom-RetryAfter -Value '0' | Should -Be 0
    }

    It 'Reads an HTTP-date relative to now' {
        $now = [DateTimeOffset]::new(2015, 10, 21, 7, 27, 0, [timespan]::Zero)

        ConvertFrom-RetryAfter -Value 'Wed, 21 Oct 2015 07:28:00 GMT' -Now $now | Should -Be 60
    }

    It 'Never returns a negative wait for a date in the past' {
        $now = [DateTimeOffset]::new(2015, 10, 21, 8, 0, 0, [timespan]::Zero)

        ConvertFrom-RetryAfter -Value 'Wed, 21 Oct 2015 07:28:00 GMT' -Now $now | Should -Be 0
    }

    It 'Returns null for <Name>' -ForEach @(
        @{ Name = 'null'; Value = $null }
        @{ Name = 'an empty string'; Value = '' }
        @{ Name = 'text'; Value = 'soon' }
        @{ Name = 'a negative number'; Value = '-5' }
        @{ Name = 'an over-long number'; Value = '12345678901' }
        @{ Name = 'a non-RFC-1123 date'; Value = '2015-10-21' }
    ) {
        ConvertFrom-RetryAfter -Value $Value | Should -BeNullOrEmpty
    }
}

Describe 'Get-RetryDelaySecond' {
    It 'Scales the ceiling exponentially and applies full jitter' {
        Get-RetryDelaySecond -Attempt 1 -BaseSeconds 2 -RandomValue 1.0 | Should -Be 2
        Get-RetryDelaySecond -Attempt 2 -BaseSeconds 2 -RandomValue 1.0 | Should -Be 4
        Get-RetryDelaySecond -Attempt 3 -BaseSeconds 2 -RandomValue 1.0 | Should -Be 8
        Get-RetryDelaySecond -Attempt 3 -BaseSeconds 2 -RandomValue 0.5 | Should -Be 4
        Get-RetryDelaySecond -Attempt 3 -BaseSeconds 2 -RandomValue 0.0 | Should -Be 0
    }

    It 'Caps the ceiling' {
        Get-RetryDelaySecond -Attempt 10 -BaseSeconds 2 -CapSeconds 60 -RandomValue 1.0 | Should -Be 60
    }

    It 'Honours a longer Retry-After than the jittered delay' {
        Get-RetryDelaySecond -Attempt 1 -BaseSeconds 2 -RetryAfterSeconds 30 -RandomValue 1.0 | Should -Be 30
    }

    It 'Keeps the jittered delay when it is longer than Retry-After' {
        Get-RetryDelaySecond -Attempt 4 -BaseSeconds 2 -RetryAfterSeconds 1 -RandomValue 1.0 | Should -Be 16
    }

    It 'Limits a huge Retry-After' {
        Get-RetryDelaySecond -Attempt 1 -RetryAfterSeconds 99999 -MaxRetryAfterSeconds 300 -RandomValue 0.0 | Should -Be 300
    }

    It 'Waits nothing when the base is zero' {
        Get-RetryDelaySecond -Attempt 5 -BaseSeconds 0 | Should -Be 0
    }

    It 'Stays within the ceiling for a random jitter' {
        $delays = 1..50 | ForEach-Object { Get-RetryDelaySecond -Attempt 2 -BaseSeconds 2 }
        ($delays | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 4
        ($delays | Measure-Object -Minimum).Minimum | Should -BeGreaterOrEqual 0
    }
}

Describe 'Get-GitHubRateLimitWaitSecond' {
    BeforeAll { $script:now = [DateTimeOffset]::FromUnixTimeSeconds(1700000000) }

    It 'Prefers Retry-After' {
        Get-GitHubRateLimitWaitSecond -RetryAfter '45' -RateLimitRemaining '0' -RateLimitReset '1700000500' -Now $script:now | Should -Be 45
    }

    It 'Waits until the reset when the quota is exhausted' {
        Get-GitHubRateLimitWaitSecond -RateLimitRemaining '0' -RateLimitReset '1700000100' -Now $script:now | Should -Be 101
    }

    It 'Returns null when quota remains or the headers are absent' {
        Get-GitHubRateLimitWaitSecond -RateLimitRemaining '12' -RateLimitReset '1700000100' -Now $script:now | Should -BeNullOrEmpty
        Get-GitHubRateLimitWaitSecond -Now $script:now | Should -BeNullOrEmpty
        Get-GitHubRateLimitWaitSecond -RateLimitRemaining '0' -RateLimitReset 'soon' -Now $script:now | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-IngestOutcome' {
    It 'Resolves HTTP <Status> to <Outcome>' -ForEach @(
        @{ Status = 201; Body = '{"status":"stored"}'; Outcome = 'stored'; Success = $true; Retryable = $false; Abort = $false }
        @{ Status = 201; Body = '{"status":"ignored"}'; Outcome = 'ignored'; Success = $true; Retryable = $false; Abort = $false }
        @{ Status = 200; Body = '{"status":"other"}'; Outcome = 'accepted'; Success = $true; Retryable = $false; Abort = $false }
        @{ Status = 201; Body = 'not json'; Outcome = 'accepted'; Success = $true; Retryable = $false; Abort = $false }
        @{ Status = 201; Body = ''; Outcome = 'accepted'; Success = $true; Retryable = $false; Abort = $false }
        @{ Status = 401; Body = ''; Outcome = 'auth-failed'; Success = $false; Retryable = $false; Abort = $true }
        @{ Status = 400; Body = ''; Outcome = 'rejected'; Success = $false; Retryable = $false; Abort = $false }
        @{ Status = 403; Body = ''; Outcome = 'rejected'; Success = $false; Retryable = $false; Abort = $false }
        @{ Status = 404; Body = ''; Outcome = 'rejected'; Success = $false; Retryable = $false; Abort = $false }
        @{ Status = 413; Body = ''; Outcome = 'rejected'; Success = $false; Retryable = $false; Abort = $false }
        @{ Status = 302; Body = ''; Outcome = 'rejected'; Success = $false; Retryable = $false; Abort = $false }
        @{ Status = 408; Body = ''; Outcome = 'transient-error'; Success = $false; Retryable = $true; Abort = $false }
        @{ Status = 429; Body = ''; Outcome = 'transient-error'; Success = $false; Retryable = $true; Abort = $false }
        @{ Status = 500; Body = ''; Outcome = 'transient-error'; Success = $false; Retryable = $true; Abort = $false }
        @{ Status = 502; Body = ''; Outcome = 'transient-error'; Success = $false; Retryable = $true; Abort = $false }
        @{ Status = 503; Body = ''; Outcome = 'transient-error'; Success = $false; Retryable = $true; Abort = $false }
        @{ Status = 504; Body = ''; Outcome = 'transient-error'; Success = $false; Retryable = $true; Abort = $false }
        @{ Status = 0; Body = ''; Outcome = 'transport-error'; Success = $false; Retryable = $true; Abort = $false }
    ) {
        $result = Resolve-IngestOutcome -StatusCode $Status -Body $Body

        $result.Outcome | Should -Be $Outcome
        $result.Success | Should -Be $Success
        $result.Retryable | Should -Be $Retryable
        $result.Abort | Should -Be $Abort
    }

    It 'Never echoes the response body in the reason' {
        (Resolve-IngestOutcome -StatusCode 400 -Body '{"message":"Alex Example is invalid"}').Reason | Should -Not -Match 'Alex'
    }

    It 'Gives a reason for a rejection' {
        (Resolve-IngestOutcome -StatusCode 413).Reason | Should -Match 'larger'
    }
}
