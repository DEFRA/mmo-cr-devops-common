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
analytics dashboard. Commits are classified from the `Copilot-Assisted: true` trailer; merge,
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
    uses: DEFRA/mmo-cr-devops-common/.github/workflows/copilot-analytics.yml@main
    with:
      pr-number: ${{ inputs.pr_number || '' }}
      ingest-url: ${{ vars.COPILOT_ANALYTICS_INGEST_URL }}
    secrets:
      ingest-token: ${{ secrets.COPILOT_INGEST_TOKEN }}
```

#### Inputs

| Name         | Type   | Required | Description                                                                                                                  |
| ------------ | ------ | -------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `pr-number`  | string | No       | Pull request number for a manual backfill. Read only when the caller was triggered by `workflow_dispatch`.                    |
| `ingest-url` | string | No       | Dashboard ingest endpoint. Must be HTTPS. When empty, metrics are still collected and uploaded as an artifact but not posted. |

#### Secrets

| Name           | Required | Description                                                                          |
| -------------- | -------- | -------------------------------------------------------------------------------------- |
| `ingest-token` | No       | Shared secret sent in the `x-ingest-token` header. Required whenever `ingest-url` is set. |

#### Configuration in the consuming repository

Both values are held by the consuming repository, because a reusable workflow resolves `vars` and
`secrets` against the **caller**, never against the repository that hosts it:

| Setting                        | Kind     | Purpose                             |
| ------------------------------ | -------- | ----------------------------------- |
| `COPILOT_ANALYTICS_INGEST_URL` | Variable | Ingest endpoint for the dashboard   |
| `COPILOT_INGEST_TOKEN`         | Secret   | Authenticates the ingest request    |

Moving these to DEFRA organisation-level settings (with repository access limited to the MMO CR
repositories) would remove the per-repository setup and needs no change to any workflow file.

#### Behaviour worth knowing

- The job is `continue-on-error`, so a failure here can never block a pull request. The only place
  a dropped payload is visible is the run's job summary.
- Fork pull requests, Dependabot pull requests and closed-but-unmerged pull requests are skipped:
  they receive no secrets, so publication could not succeed.
- A consuming repository may add a `.analyticsignore` at its root to exclude noisy paths from line
  counting. Entries are gitignore-style and are **added to**, not a replacement for, the built-in
  exclusions for lockfiles, minified bundles, source maps and snapshots.
- Publication is idempotent: the consumer upserts one document per `(repository, prNumber)` and
  only replaces it when the incoming `calculatedAt` is newer, so re-runs converge rather than
  duplicate.

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
