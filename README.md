# af-xlsx-files

Public catalog representation and finite construction library, API `0.1`.
This first extraction implements the catalog-owner boundary selected by the
AdventureFinder target architecture v0.1; operative editorial meaning remains
with `af-specification-md`, and approval/workflow policy remains with PL.

Load `lib/af_xlsx_files.rb` using Ruby 3.2+ with rubyzip and rexml already
available. No pipeline, private data root, workbook template or test helper is
loaded. Both existing workbook/parser models are retained deliberately.
The original stub's MIT license is preserved.

## Public inputs and results

`AfXlsxFiles::ProjectState.new(manifest_path:).validate!` checks the complete
closed PROJECT_STATE v0.2 manifest and all three artifacts. `resolve(role)`
requires an explicitly named role and returns its name/version/filename/hash/
positive byte size/path. Independent roles cannot exceed `catalog_head`.
Consumers choose explicit artifacts and frozen inputs before their documented
role default; there is no filename/timestamp discovery. The preserved
[v0.2 oracle](contracts/project-state/v0.2/README.md) defines read conformance.
Guarded writes are internal to the pipeline's reviewed adoption workflow. The
owner locks the physical catalog directory, checks reviewed repository, manifest
and workbook identities, imports exclusively and atomically replaces the
manifest with a transition affecting only `catalog_head`. The pipeline supplies
and revalidates admission under that same lock. Standalone consumers use the
read and construction APIs above.

`AfXlsxFiles::EmptyCatalog.create!(path:, version:, ordinary_capacity:,
large_capacity:, source_capacity:, publisher_capacity:)` returns the absolute
path of an exclusively published zero-record canonical XLSX. The selected path
must be `5e_Adventure_Master_Catalog_VERSION.xlsx` in an existing real directory
without symlink ancestors. All capacities are explicit positive integers, bounded
by the accepted row-1000 formula envelope: 999 ordinary, 998 large, and 996 each
for sources/publishers. Capacity is finite; source and publisher slots are
independent. Conflicts never overwrite. The workbook retains required sheets,
headers, styles/package relationships, ordinary row 2, large row 3 and reserved
summary, exact guarded ratios and zero-derived summary caches. Identities and
assessments start blank; per-record formulas are constructed only on insertion.
The result does not initialize Git, adopt catalog roles or qualify scoring.

`AfXlsxFiles::BoundaryFreezeApply.plan!` and `.apply!` require explicit
`freeze_path:`, `source_root:`, `amc_path:`, `publisher:`, `artifact:`,
`freeze_sha256:` and `amc_sha256:`. `artifact` is the actual admitted
`af-boundary-freeze/v0.1` mapping. XL compares it with bound YAML bytes, verifies
the base and source file bindings, validates record representation and reconstructs
allocation from both sheets in frozen order. PL must first validate registry/
source meaning, editorial/freeze approval, operation and successor authorization.
XL's byte/representation checks do not approve those decisions.

`plan!` returns `records`, `changed_cells` and `current_books` without writing.
`apply!` additionally requires `output_path:`, accepts optional `report_path:`,
`registry_path:` (retained compatibility metadata) and `progress:`, and returns
the existing `Result(output_path, report_path, report)` with unchanged report
schemas. Direct output keeps caller-selected naming; PL staging retains its
`staged-` namespace. Conflicts and incomplete publications refuse. Only finite
preallocated cells are consumed, including legacy populated layouts; there is
one forward allocator. Existing first/second insertion styles and untouched
records/package members are preserved.

`verify_bound!(...same bound inputs..., output_amc:)` reconstructs the allowed
cells/formulas/styles and independently verifies the output. Saved report
records, caller-supplied changed-cell lists or PASS flags cannot authorize a
mutation. Historical literal ratios remain accepted only as their exact
documented guard alternative with a positive denominator and identical cache/style;
verification never rewrites those artifacts. `verify!` remains the low-level compatibility comparator for existing
PL helper callers; approval-sensitive replay uses `verify_bound!`.

`AfXlsxFiles::AmcCompatibilityCheck.check(candidate_path:, base_path: nil)`
returns the existing structural report; `.validate!` raises on failure. XL
checks representation and blank new assessment cells. It accepts no release
summary or approval callback. PL composes its real scored-new-ID, release and
frontier validators with the structural helpers before permitting those values.
`AmcApply::{Workbook,Worksheet,StyleTable}` and numeric/XML helpers are the
retained accepted-value parser model; accepted-value application/finalization
workflows remain in PL.

Invalid role/manifests raise `AfXlsxFiles::Error`; invalid/conflicting/changed
construction or structure raises `ValidationError < Error`. Filesystem and
dependency-load errors may propagate as documented by the specific entry point.
PL translates owner errors to its named pipeline exceptions at workflow entry
points, preserving existing rescues and serialized failure receipt identities.
Receipts/workbooks remain unaccepted until the separately authorized PL workflow.

## Checks and integration

```sh
ruby test/catalog_test.rb --seed 52478
bin/check-project-state-contract --suite contracts/project-state/v0.2
bin/check-project-state-consumers
```

The workspace checker uses this versioned content-free suite, without a live
manifest. `AF_WORKSPACE_ROOT` selects existing consumer checkouts;
`AF_DATA_PIPELINE_ROOT` explicitly selects PL under the original fail-closed
discovery rules. Consumers retain their own production parsers. Matcher locked
dependency failures remain failures, independently of owner conformance.

Apply the owner before PL. PL selects an absolute `AF_XLSX_FILES_ROOT`, or the
library on Ruby's load path; an invalid explicit selection never falls back.
Use exact loaded-feature paths and hashes to establish the selected code.
Installed identity, application, host gates and acceptance belong to the operator.
Keep both candidates for recovery; switching code does not reverse adopted data.

Complete large-only manual review, full FP large-sheet export, all-caller
adoption, real Git initialization, data-store rename and publication remain deferred.
The first real FP witness covers only its documented ordinary-sheet reader.
