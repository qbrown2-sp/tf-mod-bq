# I4B integration test

Verifies that an external table's `hivePartitioningOptions.requirePartitionFilter` survives the
trip through the [I4B framework](https://github.com/cbsi-dto/i4b) and reaches the planned
`google_bigquery_table` resource.

## Why this test exists

Terraform silently discards object attributes that are absent from a declared object type. Before
the fix this test guards, `external_tables[*].hive_partitioning_options` was typed as
`object({mode, source_uri_prefix})`, so a caller passing `require_partition_filter = true` had it
dropped with **no error** — and `terraform validate` succeeded either way. The only way to observe
the bug is to plan and inspect the resulting resource, which is what this test does.

## Running it

```bash
test/i4b/run.sh
```

Requires `bash >= 5`, `terraform`, and the I4B prerequisites (`gcloud`, `tree`, `yq`, `jq`,
`curl`, coreutils). No GCP credentials are needed: the test provisions a dataset under a
project that does not exist, so I4B finds nothing to import and the plan makes no API calls.

To confirm the test actually detects the regression, point it at the pre-fix module:

```bash
MODULE_SOURCE="git::https://github.com/cbsi-dto/tf-mod-bq.git?ref=a8777b2eedfd3847d852b16282c0fd4897db08c1" \
  test/i4b/run.sh    # expected: FAIL
```

## How it works

1. Builds a throwaway DDL repo and clones I4B into it.
2. Uses `i4b-helper init-project` and `i4b-helper provision-dataset`, as the I4B README
   prescribes, to generate the real directory and symlink layout.
3. Rewrites I4B's `tf-mod-bq` module `source` to point at this checkout, so the test always
   exercises the working tree rather than a pinned revision.
4. Enables I4B's external-table passthrough, which upstream ships commented out with the note
   *"not supported yet by google module"* — this module's `require_partition_filter` support is
   what that comment refers to. The test asserts the passthrough is present afterwards, so it
   cannot silently degrade into a no-op if the upstream block changes shape.
5. Plans, and asserts `require_partition_filter = true` appears in `hive_partitioning_options`.

`I4B_REF` pins the I4B revision under test; it defaults to the commit `data-warehouse-ddl`
currently uses.

## Why this is not a pull-request check

This repository is public; `cbsi-dto/i4b` is internal and behind SAML SSO. A `pull_request` run
cannot clone I4B: `GITHUB_TOKEN` is scoped to this repository, and pull requests from forks are
given no secrets at all. Handing a token that can read an internal repository to a public
repository's CI would be a poor trade, so the workflow is `workflow_dispatch` only and the test is
expected to be run locally, or in the CI of a private repository that can already reach I4B
(I4B itself, or `data-warehouse-ddl`).
