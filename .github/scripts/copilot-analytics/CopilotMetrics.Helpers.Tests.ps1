BeforeAll {
    . (Join-Path $PSScriptRoot 'CopilotMetrics.Helpers.ps1')
}

Describe 'Get-JiraKey' {
    It 'Finds keys in the branch, title and commit messages' {
        $keys = @(Get-JiraKey -Branch 'feature/MMO-12-charts' -Title 'CR-7 Add charts' `
                -Message @("Fix axis`n`nRefs ABC-99"))

        $keys | Should -Be @('ABC-99', 'CR-7', 'MMO-12')
    }

    It 'De-duplicates and sorts keys' {
        $keys = @(Get-JiraKey -Branch 'MMO-2' -Title 'MMO-2 and MMO-10' -Message @('MMO-2'))

        $keys | Should -Be @('MMO-10', 'MMO-2')
    }

    It 'Caps the number of keys' {
        $title = (1..60 | ForEach-Object { "KEY-$_" }) -join ' '

        @(Get-JiraKey -Title $title -Maximum 50).Count | Should -Be 50
    }

    It 'Returns nothing when no key is present' {
        @(Get-JiraKey -Branch 'main' -Title 'Tidy up').Count | Should -Be 0
    }

    It 'Ignores lowercase keys without an allow-list' {
        @(Get-JiraKey -Branch 'feature/abc-123' -Title 'abc-123 fix').Count | Should -Be 0
    }

    It 'Ignores malformed keys' {
        @(Get-JiraKey -Title 'A-1 ABC-0 ABC-12345678901').Count | Should -Be 0
    }

    It 'Does not match a key embedded in a longer word' {
        @(Get-JiraKey -Title 'fooABC-12').Count | Should -Be 0
    }

    It 'Emits look-alike tokens as candidates without an allow-list' {
        @(Get-JiraKey -Title 'Move to UTF-8') | Should -Be @('UTF-8')
    }

    Context 'With an allow-list' {
        It 'Keeps only keys from the listed projects' {
            $keys = @(Get-JiraKey -Title 'MMO-1 UTF-8 CR-2' -ProjectKey @('mmo', ' CR '))

            $keys | Should -Be @('CR-2', 'MMO-1')
        }

        It 'Matches the branch case-insensitively' {
            @(Get-JiraKey -Branch 'feature/mmo-123-fix' -ProjectKey @('MMO')) | Should -Be @('MMO-123')
        }

        It 'Still matches the title case-sensitively' {
            @(Get-JiraKey -Title 'mmo-123 fix' -ProjectKey @('MMO')).Count | Should -Be 0
        }
    }
}

Describe 'Get-ModuleKey' {
    It 'Uses <Expected> for <Path>' -ForEach @(
        @{ Path = 'README.md'; Expected = '(root)' }
        @{ Path = 'docs/adr/0001.md'; Expected = 'docs' }
        @{ Path = 'src/server/index.js'; Expected = 'src/server' }
        @{ Path = 'src/index.js'; Expected = 'src' }
        @{ Path = 'packages/ui/button.js'; Expected = 'packages/ui' }
        @{ Path = 'scripts/seed.js'; Expected = 'scripts' }
    ) {
        Get-ModuleKey -Path $Path | Should -Be $Expected
    }
}

Describe 'ConvertFrom-AnalyticsSummary' {
    BeforeAll {
        function Get-SummaryJson {
            param([hashtable]$Totals = @{}, [string]$Schema = 'mmo-attribution/1')
            $base = [ordered]@{ aiCompletion = 1; aiChat = 0; aiAgent = 4; aiModified = 0; pasted = 2; typed = 3; untracked = 0 }
            foreach ($key in $Totals.Keys) { $base[$key] = $Totals[$key] }
            return ([ordered]@{ schema = $Schema; id = '0123456789ab'; totals = $base } | ConvertTo-Json -Depth 5)
        }
    }

    It 'Returns the totals of a valid summary' {
        $totals = ConvertFrom-AnalyticsSummary -Json (Get-SummaryJson)

        $totals['aiCompletion'] | Should -Be 1
        $totals['aiAgent'] | Should -Be 4
        $totals['pasted'] | Should -Be 2
    }

    It 'Rejects <Case>' -ForEach @(
        @{ Case = 'a different schema'; Json = { Get-SummaryJson -Schema 'other/1' } }
        @{ Case = 'a negative count'; Json = { Get-SummaryJson -Totals @{ typed = -1 } } }
        @{ Case = 'a fractional count'; Json = { Get-SummaryJson -Totals @{ typed = 1.5 } } }
        @{ Case = 'an oversized count'; Json = { Get-SummaryJson -Totals @{ typed = 99999999 } } }
        @{ Case = 'invalid JSON'; Json = { '{not json' } }
        @{ Case = 'an empty string'; Json = { '' } }
        @{ Case = 'a missing totals key'; Json = { '{"schema":"mmo-attribution/1","totals":{"typed":1}}' } }
        @{ Case = 'a missing totals block'; Json = { '{"schema":"mmo-attribution/1"}' } }
        @{ Case = 'a JSON array'; Json = { '[1,2]' } }
    ) {
        ConvertFrom-AnalyticsSummary -Json (& $Json) | Should -BeNullOrEmpty
    }
}

Describe 'Get-LineFingerprint' {
    It 'Hashes <Text> to <Expected>' -ForEach @(
        @{ Text = 'const a = 1'; Expected = '40ee16b9' }
        @{ Text = '    const   a = 1  '; Expected = '40ee16b9' }
        @{ Text = "const a = 1`r"; Expected = '40ee16b9' }
        @{ Text = '}'; Expected = '9845a6a3' }
        @{ Text = "return caf$([char]0xE9)"; Expected = '362dcdd1' }
        @{ Text = "`tif (x) {"; Expected = 'd63ee4ad' }
    ) {
        Get-LineFingerprint -Text $Text | Should -Be $Expected
    }

    It 'Returns null for a blank line' {
        Get-LineFingerprint -Text '   ' | Should -BeNullOrEmpty
    }

    It 'Does not treat a non-breaking space as whitespace' {
        Get-LineFingerprint -Text "a$([char]0x00A0)b" | Should -Not -Be (Get-LineFingerprint -Text 'a b')
    }
}

Describe 'ConvertFrom-AnalyticsSummary v2' {
    It 'Accepts the v2 schema' {
        $json = '{"schema":"ai-attribution/2","totals":{"aiCompletion":1,"aiChat":0,"aiAgent":0,"aiModified":0,"pasted":0,"typed":0,"untracked":0}}'

        (ConvertFrom-AnalyticsSummary -Json $json)['aiCompletion'] | Should -Be 1
    }
}

Describe 'ConvertFrom-AnalyticsUsage' {
    BeforeAll {
        function Get-UsageJson {
            param([string]$State = 'captured', [string]$Schema = 'ai-attribution/2', [string]$Model = 'gpt-5')
            return ([ordered]@{
                    schema = $Schema; signals = [ordered]@{ usage = $State }
                    usage = [ordered]@{
                        sessions = @(
                            [ordered]@{ id = 's_a'; models = @([ordered]@{ model = $Model; requests = 2; inputTokens = 100; outputTokens = 10; cacheReadTokens = 5; cacheCreationTokens = 0; reasoningTokens = 1 }) }
                            [ordered]@{ id = 's_b'; models = @([ordered]@{ model = $Model; requests = 1; inputTokens = 50; outputTokens = 5 }) }
                        )
                    }
                } | ConvertTo-Json -Depth 8)
        }
    }

    It 'Aggregates per model across sessions' {
        $usage = ConvertFrom-AnalyticsUsage -Json (Get-UsageJson)

        $usage['sessions'] | Should -Be 2
        @($usage['models']).Count | Should -Be 1
        $usage['models'][0]['requests'] | Should -Be 3
        $usage['models'][0]['inputTokens'] | Should -Be 150
        $usage['models'][0]['outputTokens'] | Should -Be 15
        $usage['models'][0]['reasoningTokens'] | Should -Be 1
    }

    It 'Sums AI credits and shared requests across sessions' {
        $json = [ordered]@{
            schema = 'ai-attribution/2'; signals = [ordered]@{ usage = 'captured' }
            usage = [ordered]@{
                sessions = @(
                    [ordered]@{ models = @([ordered]@{ model = 'gpt-5'; requests = 0.5; inputTokens = 50; outputTokens = 5; credits = 0.0125 }) }
                    [ordered]@{ models = @([ordered]@{ model = 'gpt-5'; requests = 1.33; inputTokens = 10; outputTokens = 1; credits = 0.002 }) }
                )
            }
        } | ConvertTo-Json -Depth 8

        $model = (ConvertFrom-AnalyticsUsage -Json $json)['models'][0]

        [math]::Round($model['requests'], 2) | Should -Be 1.83
        [math]::Round($model['credits'], 4) | Should -Be 0.0145
    }

    It 'Has no credits for a model that is unpriced in any session' {
        $usage = ConvertFrom-AnalyticsUsage -Json (Get-UsageJson)

        $usage['models'][0]['credits'] | Should -BeNullOrEmpty
    }

    It 'Returns nothing for <Case>' -ForEach @(
        @{ Case = 'v1'; Json = { Get-UsageJson -Schema 'mmo-attribution/1' } }
        @{ Case = 'usage that was not captured'; Json = { Get-UsageJson -State 'off' } }
        @{ Case = 'a hostile model name'; Json = { Get-UsageJson -Model '<script>' } }
        @{ Case = 'invalid JSON'; Json = { 'nope' } }
    ) {
        ConvertFrom-AnalyticsUsage -Json (& $Json) | Should -BeNullOrEmpty
    }
}

Describe 'Merge-AnalyticsUsage' {
    It 'Sums models across commits and returns null for none' {
        $one = [ordered]@{ sessions = 1; models = @([ordered]@{ model = 'm'; requests = 1; inputTokens = 10; outputTokens = 1; cacheReadTokens = 0; cacheCreationTokens = 0; reasoningTokens = 0 }) }
        $two = [ordered]@{ sessions = 2; models = @([ordered]@{ model = 'm'; requests = 2; inputTokens = 5; outputTokens = 2; cacheReadTokens = 1; cacheCreationTokens = 0; reasoningTokens = 0 }) }

        $merged = Merge-AnalyticsUsage -Usage @($one, $two)

        $merged['sessions'] | Should -Be 3
        $merged['models'][0]['inputTokens'] | Should -Be 15
        $merged['models'][0].Contains('credits') | Should -BeFalse
        Merge-AnalyticsUsage -Usage @($null) | Should -BeNullOrEmpty
    }

    It 'Sums and rounds credits across commits, and drops them when one commit is unpriced' {
        $priced = { param($c) [ordered]@{ sessions = 1; models = @([ordered]@{ model = 'm'; requests = 0.333; inputTokens = 1; outputTokens = 0; cacheReadTokens = 0; cacheCreationTokens = 0; reasoningTokens = 0; credits = $c }) } }

        $merged = Merge-AnalyticsUsage -Usage @((& $priced 0.00011), (& $priced 0.00012))
        $merged['models'][0]['credits'] | Should -Be 0.0002
        $merged['models'][0]['requests'] | Should -Be 0.67

        $mixed = Merge-AnalyticsUsage -Usage @((& $priced 0.5), (& $priced $null))
        $mixed['models'][0].Contains('credits') | Should -BeFalse
    }

    It 'Folds models beyond the cap into other' {
        $models = 1..25 | ForEach-Object { [ordered]@{ model = "m$_"; requests = 1; inputTokens = $_; outputTokens = 0; cacheReadTokens = 0; cacheCreationTokens = 0; reasoningTokens = 0 } }

        $merged = Merge-AnalyticsUsage -Usage @([ordered]@{ sessions = 1; models = $models })

        @($merged['models']).Count | Should -Be 20
        $merged['models'][-1]['model'] | Should -Be 'other'
        $merged['models'][-1]['requests'] | Should -Be 6
    }
}

Describe 'ConvertFrom-AnalyticsFileRecord and Test-AnalyticsFileRecord' {
    BeforeAll {
        function Get-RecordJson {
            param([string]$Path = 'src/a.js', [string]$Schema = 'ai-attribution-file/2', $Ai = $null)
            $doc = [ordered]@{ schema = $Schema; path = $Path; added = 3 }
            if ($null -ne $Ai) { $doc['ai'] = $Ai }
            return ($doc | ConvertTo-Json -Depth 6)
        }
        $script:ai = @(, @(1, 'a', (Get-LineFingerprint -Text 'one'), 0))
        $script:ai += , @(3, 'c', (Get-LineFingerprint -Text 'three'), 1)
    }

    It 'Parses the listed AI lines of a v2 record' {
        $record = ConvertFrom-AnalyticsFileRecord -Json (Get-RecordJson -Ai $script:ai)

        $record['Path'] | Should -Be 'src/a.js'
        $record['Ai'].Count | Should -Be 2
        $record['Ai'][1].Origin | Should -Be 'c'
        $record['Ai'][1].Modified | Should -BeTrue
    }

    It 'Has nothing to verify for a v1 record' {
        $record = ConvertFrom-AnalyticsFileRecord -Json (Get-RecordJson -Schema 'mmo-attribution-file/1')

        $record['Ai'] | Should -BeNullOrEmpty
    }

    It 'Rejects <Case>' -ForEach @(
        @{ Case = 'a traversal path'; Json = { Get-RecordJson -Path '../x.js' -Ai @(, @(1, 'a', '40ee16b9', 0)) } }
        @{ Case = 'an absolute path'; Json = { Get-RecordJson -Path '/x.js' } }
        @{ Case = 'a bad fingerprint'; Json = { Get-RecordJson -Ai @(, @(1, 'a', 'XYZ', 0)) } }
        @{ Case = 'a bad origin'; Json = { Get-RecordJson -Ai @(, @(1, 'z', '40ee16b9', 0)) } }
        @{ Case = 'a short tuple'; Json = { Get-RecordJson -Ai @(, @(1, 'a')) } }
        @{ Case = 'an unknown schema'; Json = { Get-RecordJson -Schema 'other/1' } }
        @{ Case = 'invalid JSON'; Json = { '{' } }
    ) {
        ConvertFrom-AnalyticsFileRecord -Json (& $Json) | Should -BeNullOrEmpty
    }

    It 'Verifies matching lines and reports the rest' {
        $record = ConvertFrom-AnalyticsFileRecord -Json (Get-RecordJson -Ai $script:ai)

        $ok = Test-AnalyticsFileRecord -Record $record -Lines @('one', 'two', "  three`r")
        $ok['Verified'] | Should -Be 2
        $ok['Mismatched'].Count | Should -Be 0

        $bad = Test-AnalyticsFileRecord -Record $record -Lines @('one', 'two', 'changed')
        $bad['Verified'] | Should -Be 1
        $bad['Mismatched'][0].Line | Should -Be 3

        $short = Test-AnalyticsFileRecord -Record $record -Lines @('one')
        $short['Mismatched'].Count | Should -Be 1

        (Test-AnalyticsFileRecord -Record $record -Lines $null)['Mismatched'].Count | Should -Be 2
    }
}

Describe 'Merge-AnalyticsTotal' {
    It 'Adds the totals of several summaries' {
        $a = [ordered]@{ aiCompletion = 1; aiChat = 0; aiAgent = 2; aiModified = 0; pasted = 0; typed = 1; untracked = 0 }
        $b = [ordered]@{ aiCompletion = 3; aiChat = 1; aiAgent = 0; aiModified = 1; pasted = 2; typed = 0; untracked = 4 }

        $merged = Merge-AnalyticsTotal -Summary @($a, $b)

        $merged['aiCompletion'] | Should -Be 4
        $merged['aiChat'] | Should -Be 1
        $merged['aiAgent'] | Should -Be 2
        $merged['untracked'] | Should -Be 4
    }
}

Describe 'Get-CommitAttribution' {
    BeforeAll {
        $script:totals = [ordered]@{ aiCompletion = 10; aiChat = 0; aiAgent = 20; aiModified = 2; pasted = 5; typed = 0; untracked = 0 }
    }

    It 'Maps metadata totals to extension attribution and derives typed lines' {
        $attr = Get-CommitAttribution -Classification 'Copilot-assisted' -AnalyticsTotal $script:totals -LinesAdded 50

        $attr.source | Should -Be 'extension'
        $attr.version | Should -Be 1
        $attr.aiCompletionLines | Should -Be 10
        $attr.aiChatLines | Should -Be 0
        $attr.aiAgentLines | Should -Be 20
        $attr.pastedLines | Should -Be 5
        $attr.typedLines | Should -Be 15
    }

    It 'Never reports negative typed lines' {
        (Get-CommitAttribution -Classification 'Copilot-assisted' -AnalyticsTotal $script:totals -LinesAdded 3).typedLines | Should -Be 0
    }

    It 'Attributes a trailer-classified commit without metadata to legacy-trailer' {
        (Get-CommitAttribution -Classification 'Copilot-assisted').source | Should -Be 'legacy-trailer'
    }

    It 'Infers a human-authored commit without metadata as 100 percent human' {
        $attr = Get-CommitAttribution -Classification 'Human-authored' -LinesAdded 7

        $attr.source | Should -Be 'extension'
        $attr.version | Should -Be 1
        $attr.typedLines | Should -Be 7
        $attr.aiCompletionLines | Should -Be 0
        $attr.aiAgentLines | Should -Be 0
        $attr.pastedLines | Should -Be 0
    }

    It 'Attributes <Classification> to none' -ForEach @(
        @{ Classification = 'Rebase' }
        @{ Classification = 'Dependabot' }
    ) {
        (Get-CommitAttribution -Classification $Classification -LinesAdded 9).source | Should -Be 'none'
    }

    It 'Recognises the legacy trailer' {
        Test-CopilotTrailer -Message "Add x`n`nCopilot-Assisted: true" | Should -BeTrue
        Test-CopilotTrailer -Message 'Add x' | Should -BeFalse
    }
}

Describe 'ConvertTo-GlobPattern' {
    It 'Converts <Entry> to <Expected>' -ForEach @(
        @{ Entry = 'e2e/'; Expected = 'e2e/**' }
        @{ Entry = '/fixtures/data.json'; Expected = 'fixtures/data.json' }
        @{ Entry = '*.feature'; Expected = '**/*.feature' }
    ) {
        ConvertTo-GlobPattern -Entry $Entry | Should -Be $Expected
    }

    It 'Skips blank lines and comments' {
        ConvertTo-GlobPattern -Entry '  ' | Should -BeNullOrEmpty
        ConvertTo-GlobPattern -Entry '# note' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-FilesBlock' {
    It 'Splits numstat output into test, non-test and excluded counts' {
        $test = @("10`t2`tsrc/a.test.js")
        $nonTest = @("5`t5`tsrc/server/a.js", "3`t0`tsrc/client/b.js", "-`t-`tlogo.png")
        $all = $test + $nonTest + @("900`t100`tpackage-lock.json")

        $files = ConvertTo-FilesBlock -TestLine $test -NonTestLine $nonTest -AllLine $all

        $files.changed | Should -Be 3
        $files.linesTouched | Should -Be 13
        $files.testFilesChanged | Should -Be 1
        $files.testLinesTouched | Should -Be 12
        $files.modulesTouched | Should -Be 3
        $files.excluded.filesChanged | Should -Be 1
        $files.excluded.linesTouched | Should -Be 1000
    }

    It 'Resolves renamed paths to their new location' {
        $files = ConvertTo-FilesBlock -NonTestLine @("1`t1`tsrc/{old => new}/a.js", "0`t0`tlib.js => tools/lib.js")

        $files.modulesTouched | Should -Be 2
    }

    It 'Never reports a negative excluded count' {
        $files = ConvertTo-FilesBlock -NonTestLine @("1`t1`ta.js")

        $files.excluded.filesChanged | Should -Be 0
        $files.excluded.linesTouched | Should -Be 0
    }

    It 'Returns zeros for an empty diff' {
        $files = ConvertTo-FilesBlock

        $files.changed | Should -Be 0
        $files.modulesTouched | Should -Be 0
    }
}

Describe 'Limit-Text' {
    It 'Leaves short text unchanged' {
        Limit-Text -Text 'Short' -MaximumLength 256 | Should -Be 'Short'
    }

    It 'Truncates long text to the maximum length' {
        (Limit-Text -Text ('x' * 300) -MaximumLength 256).Length | Should -Be 256
    }

    It 'Never splits a surrogate pair' {
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $result = Limit-Text -Text (('x' * 255) + $emoji) -MaximumLength 256

        $result | Should -Be ('x' * 255)
    }

    It 'Returns an empty string for null' {
        Limit-Text -Text $null -MaximumLength 10 | Should -Be ''
    }
}

Describe 'Get-IngestAuthHeader' {
    It 'Prefers the OIDC token as a bearer token' {
        $headers = Get-IngestAuthHeader -OidcToken 'jwt' -SharedToken 'secret'

        $headers['Authorization'] | Should -Be 'Bearer jwt'
        $headers.ContainsKey('x-ingest-token') | Should -BeFalse
    }

    It 'Falls back to the shared token' {
        $headers = Get-IngestAuthHeader -OidcToken '' -SharedToken 'secret'

        $headers['x-ingest-token'] | Should -Be 'secret'
        $headers.ContainsKey('Authorization') | Should -BeFalse
    }

    It 'Returns nothing when neither credential is available' {
        Get-IngestAuthHeader -OidcToken $null -SharedToken ' ' | Should -BeNullOrEmpty
    }
}
