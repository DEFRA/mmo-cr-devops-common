// Profiles the restored copilot_analytics.payloads collection for the v1 -> v2 migration.
// Run: mongosh --quiet --norc <connection> --file Get-LegacyProfile.js > payloads.ndjson.profile.json
//
// Output is aggregate counts, dates, BSON types, field names and repository names only. It never
// prints a contributor, author, commit subject, branch name or pull request title (personal data).
/* global db, print, EJSON */

const DATABASE = typeof LEGACY_DB === 'string' ? LEGACY_DB : 'copilot_analytics'
const COLLECTION = typeof LEGACY_COLLECTION === 'string' ? LEGACY_COLLECTION : 'payloads'
const MAX_INGEST_BYTES = 2097152
const MAX_COMMITS = 1000
const MAX_CONTRIBUTORS = 200
const MAX_REPOSITORIES_LISTED = 500

const ROOT_FIELDS = [
  'schemaVersion',
  'prNumber',
  'repository',
  'sourceBranch',
  'targetBranch',
  'buildId',
  'calculatedAt',
  'prCreatedAt',
  'firstCommitAt',
  'lastCommitAt',
  'prMergedAt',
  'summary',
  'contributorBreakdown',
  'commitBreakdown',
  'source',
  'prTitle',
  'jiraKeys',
  'files'
]
const REQUIRED_ROOT_FIELDS = [
  'prNumber',
  'repository',
  'targetBranch',
  'buildId',
  'calculatedAt',
  'summary',
  'contributorBreakdown',
  'commitBreakdown'
]
const REQUIRED_SUMMARY_FIELDS = [
  'totalCommits',
  'copilotAssistedCommits',
  'humanAuthoredCommits',
  'copilotAssistedRate',
  'totalLinesTouched',
  'copilotAssistedLines',
  'humanAuthoredLines',
  'copilotAssistedLineRate'
]
const REQUIRED_CONTRIBUTOR_FIELDS = [
  'contributor',
  'totalCommits',
  'copilotAssisted',
  'humanAuthored',
  'linesAdded',
  'linesDeleted',
  'linesTouched',
  'netLines',
  'copilotAssistedLines',
  'humanAuthoredLines'
]
const REQUIRED_COMMIT_FIELDS = [
  'commit',
  'author',
  'subject',
  'classification',
  'filesChanged',
  'linesAdded',
  'linesDeleted',
  'linesTouched',
  'netLines'
]
const DATE_FIELDS = [
  'calculatedAt',
  'prCreatedAt',
  'firstCommitAt',
  'lastCommitAt',
  'prMergedAt'
]

const collection = db.getSiblingDB(DATABASE).getCollection(COLLECTION)
const aggregate = (pipeline) =>
  collection.aggregate(pipeline, { allowDiskUse: true }).toArray()

function iso(value) {
  return value instanceof Date ? value.toISOString() : (value ?? null)
}

function toCountMap(rows) {
  const map = {}
  for (const row of rows) {
    map[String(row._id)] = row.count
  }
  return map
}

// Counts documents by the BSON type of a field; absent fields report as "missing".
function typeCounts(path) {
  return toCountMap(
    aggregate([
      { $group: { _id: { $type: `$${path}` }, count: { $sum: 1 } } },
      { $sort: { _id: 1 } }
    ])
  )
}

// Counts how many documents lack each field, or hold null in it.
function missingCounts(fields, base = null) {
  const sum = (field) => ({
    $sum: {
      $cond: [
        { $in: [{ $type: `$${base ? base + '.' : ''}${field}` }, ['missing', 'null']] },
        1,
        0
      ]
    }
  })
  const group = { _id: null }
  for (const field of fields) {
    group[field] = sum(field)
  }
  const pipeline = base
    ? [{ $unwind: `$${base}` }, { $group: group }]
    : [{ $group: group }]
  const [row] = aggregate(pipeline)
  const result = {}
  for (const field of fields) {
    result[field] = row ? row[field] : 0
  }
  return result
}

function dateRange(field) {
  const [row] = aggregate([
    { $match: { [field]: { $type: 'date' } } },
    {
      $group: {
        _id: null,
        earliest: { $min: `$${field}` },
        latest: { $max: `$${field}` },
        count: { $sum: 1 }
      }
    }
  ])
  return row
    ? { count: row.count, earliest: iso(row.earliest), latest: iso(row.latest) }
    : { count: 0, earliest: null, latest: null }
}

function maxOf(expression) {
  const [row] = aggregate([
    { $group: { _id: null, max: { $max: expression } } }
  ])
  return row ? row.max : 0
}

function countWhere(expression) {
  const [row] = aggregate([
    { $match: { $expr: expression } },
    { $count: 'count' }
  ])
  return row ? row.count : 0
}

const arraySize = (field) => ({
  $cond: [{ $isArray: `$${field}` }, { $size: `$${field}` }, 0]
})

const totalDocuments = collection.countDocuments({})

const pairRows = aggregate([
  {
    $group: {
      _id: { repository: '$repository', prNumber: '$prNumber' },
      versions: { $sum: 1 }
    }
  },
  { $group: { _id: '$versions', pairs: { $sum: 1 } } },
  { $sort: { _id: 1 } }
])
const versionsPerPullRequest = {}
let uniquePullRequests = 0
for (const row of pairRows) {
  versionsPerPullRequest[String(row._id)] = row.pairs
  uniquePullRequests += row.pairs
}

const repositoryRows = aggregate([
  {
    $group: {
      _id: '$repository',
      documents: { $sum: 1 },
      pullRequests: { $addToSet: '$prNumber' }
    }
  },
  {
    $project: {
      documents: 1,
      pullRequests: { $size: '$pullRequests' }
    }
  },
  { $sort: { documents: -1, _id: 1 } }
])
const REPOSITORY_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\/[A-Za-z0-9._-]{1,100}$/
const repositories = repositoryRows
  .slice(0, MAX_REPOSITORIES_LISTED)
  .map((row) => ({
    repository:
      typeof row._id === 'string'
        ? row._id.slice(0, 100)
        : `<${typeof row._id}>`,
    wellFormed: typeof row._id === 'string' && REPOSITORY_NAME.test(row._id),
    documents: row.documents,
    pullRequests: row.pullRequests
  }))

const presentKeys = {}
for (const row of aggregate([
  { $project: { keys: { $map: { input: { $objectToArray: '$$ROOT' }, as: 'kv', in: '$$kv.k' } } } },
  { $unwind: '$keys' },
  { $group: { _id: '$keys', count: { $sum: 1 } } },
  { $sort: { _id: 1 } }
])) {
  presentKeys[row._id] = row.count
}

const sizeRow = aggregate([
  {
    $group: {
      _id: null,
      maxBytes: { $max: { $bsonSize: '$$ROOT' } },
      averageBytes: { $avg: { $bsonSize: '$$ROOT' } }
    }
  }
])[0]

const commitClassifications = toCountMap(
  aggregate([
    { $unwind: '$commitBreakdown' },
    {
      $group: {
        _id: { $ifNull: ['$commitBreakdown.classification', 'missing'] },
        count: { $sum: 1 }
      }
    },
    { $sort: { _id: 1 } }
  ])
)

const [commitTotals] = aggregate([
  { $unwind: '$commitBreakdown' },
  {
    $group: {
      _id: null,
      commits: { $sum: 1 },
      withAttribution: {
        $sum: {
          $cond: [
            { $ne: [{ $type: '$commitBreakdown.attribution' }, 'missing'] },
            1,
            0
          ]
        }
      },
      subjectOver1024: {
        $sum: {
          $cond: [
            {
              $and: [
                { $eq: [{ $type: '$commitBreakdown.subject' }, 'string'] },
                { $gt: [{ $strLenCP: '$commitBreakdown.subject' }, 1024] }
              ]
            },
            1,
            0
          ]
        }
      },
      authorOver256: {
        $sum: {
          $cond: [
            {
              $and: [
                { $eq: [{ $type: '$commitBreakdown.author' }, 'string'] },
                { $gt: [{ $strLenCP: '$commitBreakdown.author' }, 256] }
              ]
            },
            1,
            0
          ]
        }
      }
    }
  }
])

const commitFieldTypes = {}
for (const field of ['committedAt', 'commit', 'linesTouched', 'netLines']) {
  commitFieldTypes[field] = toCountMap(
    aggregate([
      { $unwind: '$commitBreakdown' },
      {
        $group: {
          _id: { $type: `$commitBreakdown.${field}` },
          count: { $sum: 1 }
        }
      },
      { $sort: { _id: 1 } }
    ])
  )
}

const dates = {}
for (const field of DATE_FIELDS) {
  dates[field] = dateRange(field)
}

const rootTypes = {}
for (const field of ROOT_FIELDS) {
  rootTypes[field] = typeCounts(field)
}

const profile = {
  generatedAt: new Date().toISOString(),
  database: DATABASE,
  collection: COLLECTION,
  documents: totalDocuments,
  uniquePullRequests,
  versionsPerPullRequest,
  schemaVersions: toCountMap(
    aggregate([
      { $group: { _id: { $ifNull: ['$schemaVersion', 'absent'] }, count: { $sum: 1 } } },
      { $sort: { _id: 1 } }
    ])
  ),
  dates,
  rootFieldTypes: rootTypes,
  missingRequired: {
    root: missingCounts(REQUIRED_ROOT_FIELDS),
    summary: missingCounts(REQUIRED_SUMMARY_FIELDS, 'summary'),
    contributorBreakdown: missingCounts(
      REQUIRED_CONTRIBUTOR_FIELDS,
      'contributorBreakdown'
    ),
    commitBreakdown: missingCounts(REQUIRED_COMMIT_FIELDS, 'commitBreakdown')
  },
  commits: {
    total: commitTotals ? commitTotals.commits : 0,
    classifications: commitClassifications,
    withAttribution: commitTotals ? commitTotals.withAttribution : 0,
    subjectOver1024Characters: commitTotals ? commitTotals.subjectOver1024 : 0,
    authorOver256Characters: commitTotals ? commitTotals.authorOver256 : 0,
    fieldTypes: commitFieldTypes
  },
  limits: {
    maxCommitsInADocument: maxOf(arraySize('commitBreakdown')),
    documentsOverCommitLimit: countWhere({
      $gt: [arraySize('commitBreakdown'), MAX_COMMITS]
    }),
    maxContributorsInADocument: maxOf(arraySize('contributorBreakdown')),
    documentsOverContributorLimit: countWhere({
      $gt: [arraySize('contributorBreakdown'), MAX_CONTRIBUTORS]
    }),
    maxBsonBytes: sizeRow ? sizeRow.maxBytes : 0,
    averageBsonBytes: sizeRow ? Math.round(sizeRow.averageBytes) : 0,
    documentsOverIngestLimit: countWhere({
      $gt: [{ $bsonSize: '$$ROOT' }, MAX_INGEST_BYTES]
    })
  },
  fieldsPresent: presentKeys,
  repositories: {
    distinct: repositoryRows.length,
    malformedNames: repositories.filter((r) => !r.wellFormed).length,
    listed: repositories
  }
}

print(EJSON.stringify(profile, null, 2, { relaxed: true }))
