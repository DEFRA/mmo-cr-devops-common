# mmo-cr-devops-common

Shared CI/CD assets for the MMO Catch Recording services: reusable GitHub Actions workflows and
the scripts they depend on. Consuming repositories call these workflows rather than copying the
implementation, so a fix or improvement lands everywhere at once.

- [Reusable workflows](#reusable-workflows)
  - [Copilot Analytics](#copilot-analytics)
- [Versioning](#versioning)
- [Licence](#licence)

## Reusable workflows

### Copilot Analytics

`.github/workflows/copilot-analytics.yml`

Measures how much of a pull request was Copilot-assisted and publishes the result to the Copilot
analytics dashboard. Each commit is classified in this order: metadata written by the DEFRA AI
Attribution extension under `.analytics/` (any AI line means Copilot-assisted), then the legacy
`Copilot-Assisted: true` trailer, then human-authored. Merge,
rebase and Dependabot commits are reported but excluded from every rate.

The implementation lives here; the scripts it runs are in
[`.github/scripts/copilot-analytics/`](.github/scripts/copilot-analytics/).

#### Usage

```yaml
name: Copilot Analytics

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize, ready_for_review, closed]
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'Pull request number to collect analytics for'
        required: true
        type: string

permissions:
  contents: read
  pull-requests: read

jobs:
  collect-and-publish:
    permissions:
      contents: read
      pull-requests: read
      # Required for OIDC ingest: the dashboard verifies a short-lived GitHub token.
      id-token: write
    uses: DEFRA/mmo-cr-devops-common/.github/workflows/copilot-analytics.yml@main
    with:
      pr-number: ${{ inputs.pr_number || '' }}
      ingest-url: ${{ vars.COPILOT_ANALYTICS_INGEST_URL }}
```

#### Inputs

| Name         | Type   | Required | Description                                                                                                                  |
| ------------ | ------ | -------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `pr-number`         | string | No       | Pull request number for a manual backfill. Read only when the caller was triggered by `workflow_dispatch`.                    |
| `ingest-url`        | string | No       | Dashboard ingest endpoint. Must be HTTPS. When empty, metrics are still collected and uploaded as an artifact but not posted. |
| `jira-project-keys` | string | No       | Comma-separated Jira project keys (for example `MMO,CR`). When set, only keys in these projects are emitted.                  |
| `ingest-audience`   | string | No       | Audience of the OIDC token sent to the dashboard. Default `mmo-cr-copilot-dashboard`; must match the dashboard's `INGEST_OIDC_AUDIENCE`. |

Authentication: the calling job must grant `id-token: write`. Every publish attempt requests a
fresh GitHub Actions OIDC token and sends it as `Authorization: Bearer`. The dashboard checks the
DEFRA organisation, this workflow, the event and that the payload's repository is the caller's and
is mapped to a project. There is no shared secret and nothing to store in the repository. Without
`id-token: write` the run publishes nothing and says so in its job summary.

#### Secrets

| Name           | Required | Description                                                                          |
| -------------- | -------- | ------------------------------------------------------------------------------------ |
| `ingest-token` | No       | Deprecated and ignored. Still declared so existing callers do not fail; remove it.   |

#### Configuration in the consuming repository

The ingest URL is held by the consuming repository, because a reusable workflow resolves `vars`
against the **caller**, never against the repository that hosts it:

| Setting                        | Kind     | Purpose                           |
| ------------------------------ | -------- | --------------------------------- |
| `COPILOT_ANALYTICS_INGEST_URL` | Variable | Ingest endpoint for the dashboard |

Moving this to a DEFRA organisation-level variable (with repository access limited to the MMO CR
repositories) would remove the per-repository setup and needs no change to any workflow file.

#### Behaviour worth knowing

- The job is `continue-on-error`, so a failure here can never block a pull request. The only place
  a dropped payload is visible is the run's job summary.
- Fork pull requests, Dependabot pull requests and closed-but-unmerged pull requests are skipped:
  they receive no secrets, so publication could not succeed.
- A consuming repository may add a `.analyticsignore` at its root to exclude noisy paths from line
  counting. Entries are gitignore-style and are **added to**, not a replacement for, the built-in
  exclusions for lockfiles, minified bundles, source maps and snapshots.
- `.analytics/**` (written by the DEFRA AI Attribution extension) is always excluded from line
  counts. Only summaries a commit **adds** count for that commit. A valid summary is authoritative:
  the `Copilot-Assisted: true` trailer is ignored on that commit, so a summary with no AI lines
  makes it human-authored. Without a valid summary (none, or invalid) the commit falls back to the
  trailer, then to human-authored.
- Format v2 metadata is **verified**: every AI line a commit's file records list is checked against
  the committed code by recomputing its fingerprint (`Get-LineFingerprint`, the same hash as the
  extension). A line that no longer matches is subtracted from the AI totals, so it falls back to
  human-authored, and a `::warning::` annotation says how many. Format v1 records, records over
  1 MB and commits with more than 200 file records are not verified and use the summary totals.
- When a v2 summary carries Copilot usage (`signals.usage: captured`), the commit's `attribution`
  gains a `usage` block with, per model, request and token counts and the GitHub AI credits the
  extension recorded. Requests can be fractional (2 decimals) when a Copilot request was shared
  between repositories; credits have 4 decimals and are left out for a model with any unpriced
  usage. Only counts are read.
- Publication is idempotent: the consumer upserts one document per `(repository, prNumber)` and
  only replaces it when the incoming `calculatedAt` is newer, so re-runs converge rather than
  duplicate.

#### Payload contract v2

The collector emits `schemaVersion: 2`, defined in the backend's
[ADR 0001](https://github.com/DEFRA/mmo-cr-copilot-backend/blob/main/docs/adr/0001-payload-contract-v2.md).
On top of v1 it adds:

| Field                        | Content                                                                                                     |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `source`                     | `live` for pull request events, `backfill` for a manual `workflow_dispatch` run.                            |
| `prTitle`                    | The pull request title, truncated to 256 characters.                                                        |
| `jiraKeys`                   | Candidate Jira issue keys from the branch name, title and counted commit messages. At most 50.              |
| `files`                      | Net PR diff (merge-base to head) split into non-test, test and excluded files and lines, plus module count. |
| `commitBreakdown[].attribution` | `extension` when the commit adds `.analytics` metadata, or inferred 100% human when a human-authored commit has none; `legacy-trailer` for a historical `Copilot-Assisted: true` trailer; `none` for rebase, merge and Dependabot commits. An `extension` entry may carry `usage`: `{ models: [{ model, requests, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens, credits? }], sessions, commitsWithUsage }`. |

- **Jira keys.** Without `jira-project-keys`, every well-formed key (such as `MMO-123`) is emitted as a
  candidate and the backend filters later. With it, only listed projects are kept and the branch
  name is also matched case-insensitively (`feature/mmo-123`). Commit bodies are scanned but never
  sent.
- **Test files.** Built-in globs cover common conventions (`*.test.*`, `*.spec.*`, `test/`,
  `tests/`, `__tests__/`, `test-helpers/`, `*.Tests.ps1`, `*_test.*`, `*Test.java`, `*Tests.cs`). A
  consuming repository may add a `.analyticstests` file at its root, in the same format as
  `.analyticsignore`, to add more.
- **Modules.** A module is the first path segment, or the first two when the first is a container
  folder (`src`, `packages`, `apps`, `services`, `libs`, `lib`, `modules`). This rule is provisional.

The scripts are tested with Pester and PSScriptAnalyzer by
[`copilot-analytics-tests.yml`](.github/workflows/copilot-analytics-tests.yml). To run them
locally:

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path .github/scripts/copilot-analytics -Output Detailed"
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path .github/scripts/copilot-analytics -Recurse -Settings .github/scripts/copilot-analytics/PSScriptAnalyzerSettings.psd1"
```

### Copilot Analytics Backfill

`copilot-analytics-backfill.yml` re-collects every pull request merged since a date and publishes
each with `source: 'backfill'`, one second apart. The job summary lists each pull request and its
result. Re-runs are safe: the backend keeps an existing live merged record and ignores the
backfill for that pull request.

```yaml
name: Copilot Analytics Backfill

on:
  workflow_dispatch:
    inputs:
      since:
        description: Merged on or after (YYYY-MM-DD)
        required: true
      max-prs:
        description: Maximum pull requests
        default: '500'

jobs:
  backfill:
    permissions:
      contents: read
      pull-requests: read
      id-token: write
    uses: DEFRA/mmo-cr-devops-common/.github/workflows/copilot-analytics-backfill.yml@main
    with:
      since: ${{ inputs.since }}
      max-prs: ${{ fromJSON(inputs.max-prs) }}
      ingest-url: ${{ vars.COPILOT_ANALYTICS_INGEST_URL }}
```

| Input               | Type   | Required | Description                                                         |
| :------------------ | :----- | :------- | :------------------------------------------------------------------ |
| `since`             | string | Yes      | Pull requests merged on or after this date (`YYYY-MM-DD`).          |
| `max-prs`           | number | No       | Upper limit on pull requests processed, 1 to 1000. Default `500`.   |
| `ingest-url`        | string | No       | Dashboard ingest endpoint. When empty, nothing is published.        |
| `jira-project-keys` | string | No       | Comma-separated Jira project keys, as for the per-PR workflow.      |
| `ingest-audience`   | string | No       | OIDC audience, default `mmo-cr-copilot-dashboard`.                  |

### Copilot Analytics Survival

`.github/workflows/copilot-analytics-survival.yml` measures how much AI-written code is still in the
code base a number of days after a pull request merged, and publishes one record per pull request to
the dashboard's `POST /api/ingest/survival` (backend ADR 0007, dashboard ADR 0005). It feeds the
21-day AI code churn and AI code durability metrics.

For each pull request merged `window-days` ago (within `lookback-days`, so a missed run catches up)
it finds the commits the pull request put on the default branch (merge, squash or rebase merge),
rebuilds the fingerprints of their AI lines from `.analytics` metadata (format v1 or v2), and uses
`git blame -w -M` at the merge and at the measurement commit to count the lines still present.
Pull requests without metadata are skipped. Lines moved to another file after the merge count as not
surviving. Records are idempotent: the backend replaces one only with a newer measurement.

```yaml
name: Copilot Analytics Survival

on:
  schedule:
    - cron: '17 3 * * *'
  workflow_dispatch:
    inputs:
      pr-number:
        description: Measure one pull request (0 measures all due)
        default: '0'

jobs:
  survival:
    permissions:
      contents: read
      pull-requests: read
      id-token: write
    uses: DEFRA/mmo-cr-devops-common/.github/workflows/copilot-analytics-survival.yml@main
    with:
      pr-number: ${{ fromJSON(inputs.pr-number || '0') }}
      ingest-url: ${{ vars.COPILOT_ANALYTICS_SURVIVAL_URL }}
```

| Input             | Type   | Required | Description                                                                          |
| :---------------- | :----- | :------- | :----------------------------------------------------------------------------------- |
| `window-days`     | number | No       | Days after the merge at which survival is measured (7, 14, 21 or 30). Default `21`.  |
| `lookback-days`   | number | No       | Days of merges to consider each run. Default `7`.                                    |
| `pr-number`       | number | No       | Measure one pull request instead of listing. `0` lists. Default `0`.                 |
| `ingest-url`      | string | No       | Survival endpoint, for example `https://host/api/ingest/survival`. Empty: no publish. |
| `ingest-audience` | string | No       | OIDC audience, default `mmo-cr-copilot-dashboard`.                                   |

The dashboard accepts only an OIDC token from this workflow, on `schedule` or `workflow_dispatch`;
there is no shared-secret fallback. The job is `continue-on-error` and uploads the records as an
artifact.

## Versioning

Workflows are referenced at `@main`. Changes here take effect immediately in every consuming
repository, so treat this repository as production. Consumers that need to insulate themselves can
pin to a commit SHA instead.

## Licence

THIS INFORMATION IS LICENSED UNDER THE CONDITIONS OF THE OPEN GOVERNMENT LICENCE found at:

<http://www.nationalarchives.gov.uk/doc/open-government-licence/version/3>

The following attribution statement MUST be cited in your products and applications when using this
information.

> Contains public sector information licensed under the Open Government license v3

### About the licence

The Open Government Licence (OGL) was developed by the Controller of Her Majesty's Stationery Office
(HMSO) to enable information providers in the public sector to license the use and re-use of their
information under a common open licence.

It is designed to encourage use and re-use of information freely and flexibly, with only a few
conditions.
