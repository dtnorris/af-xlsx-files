# af-xlsx-files

`af-xlsx-files` is the Ruby library that reads and builds Excel catalogs for [Adventure Finder](https://github.com/dtnorris/adventure-finder). Use it to create an empty adventure catalog, find the workbook your library has accepted, or check how a proposed update would change that workbook.

The workbook format lives here. The [specification](https://github.com/dtnorris/af-specification-md) defines what the catalog fields mean, and the [pipeline](https://github.com/dtnorris/af-pipeline) manages review and adoption.

## Create your first catalog

From this checkout, use Ruby 3.2 or later and Bundler. Install the gems from the [Gemfile](Gemfile), then run:

```sh
bundle install
bundle exec ruby -Ilib -raf_xlsx_files -rtmpdir <<'RUBY'
directory = File.realpath(Dir.mktmpdir("af-catalog-"))
puts AfXlsxFiles::EmptyCatalog.create!(
  path: File.join(directory, "5e_Adventure_Master_Catalog_0.1.xlsx"),
  version: "0.1", ordinary_capacity: 4, large_capacity: 4,
  source_capacity: 2, publisher_capacity: 2
)
RUBY
```

Open the printed path in Excel. You’ll find three worksheets: **Adventure Catalog**, **AMC >100pg**, and **Current Books**. The workbook starts with zero adventures, room for four ordinary and four large adventures, and two slots each for sources and publishers. The example uses a fresh temporary directory and needs no private repository.

## Use your own adventure library

For the full Adventure Finder workflow, create a private repository named `af-xlsx-files-data` in your own account or organization. Keep your catalog workbooks and `PROJECT_STATE.yml` in that checkout. The manifest’s `catalog_head` identifies the accepted workbook by filename, version, byte size, and SHA-256. Creating a workbook alone does not adopt it. See [Adventure Finder’s private repository setup](https://github.com/dtnorris/adventure-finder#set-up-your-own-private-repositories).

To try the lookup before you have a private catalog, run this against the included public fixture:

```sh
bundle exec ruby -Ilib -raf_xlsx_files -e '
  state = AfXlsxFiles::ProjectState.new(manifest_path: ARGV.fetch(0))
  state.validate!
  puts state.resolve("catalog_head").filename
' contracts/project-state/v0.2/fixtures/valid-distinct-roles/PROJECT_STATE.yml
```

It prints `5e_Adventure_Master_Catalog_2.0.xlsx`. The fixture uses tiny placeholder files to test manifest bindings. To look up your own workbook, pass the path to your private `PROJECT_STATE.yml` as the final argument.

## Public inputs and results

The public API is version `0.1`. Load [`af_xlsx_files`](lib/af_xlsx_files.rb) with this checkout’s `lib` directory on Ruby’s load path.

| What you want to do | Ruby entry point | Result |
| --- | --- | --- |
| Create a workbook | [`EmptyCatalog.create!`](lib/af_xlsx_files/empty_catalog.rb) | Absolute path to a new, zero-record workbook. An occupied destination is refused. |
| Find an accepted workbook | [`ProjectState#validate!` and `#resolve`](lib/af_xlsx_files/project_state.rb) | Validates all three role bindings. Resolving a named role returns its version, filename, path, byte size, and SHA-256. |
| Preview or apply an approved boundary freeze | [`BoundaryFreezeApply.plan!` and `.apply!`](lib/af_xlsx_files/boundary_freeze_apply.rb) | A plan reports records, changed cells, and current books. Applying writes a separate workbook and returns its path and report. |
| Verify a proposed workbook | [`BoundaryFreezeApply.verify_bound!`](lib/af_xlsx_files/boundary_freeze_apply.rb) | Reconstructs the permitted changes from the bound inputs and checks the candidate against them. |
| Check workbook compatibility | [`AmcCompatibilityCheck.check` and `.validate!`](lib/af_xlsx_files/amc_compatibility_check.rb) | Returns a structural report or raises on validation failure. |

**Construction.** Choose a new `5e_Adventure_Master_Catalog_VERSION.xlsx` path in an existing real directory without symlink ancestors. Set all four capacities explicitly. The formula limits are 999 ordinary adventures, 998 large adventures, 996 sources, and 996 publishers.

**Catalog roles.** The v0.2 manifest binds `catalog_head`, `matcher_authorized_baseline`, and `production_dependency_floor`. A consumer selects the role it needs. The matcher baseline and production floor can refer to earlier versions. See the [project-state contract and fixtures](contracts/project-state/v0.2/README.md).

**Approval and adoption.** For a boundary update, the pipeline supplies the approved freeze, source root, base workbook, publisher, admitted artifact, and expected freeze and workbook hashes. This library checks those inputs and the resulting workbook. The pipeline owns editorial approval, scoring and release checks, and guarded adoption of a new `catalog_head`. A successful structural check is only one step in that workflow.

## Checks and integration

Run these from this checkout after installing the bundle:

```sh
bundle exec ruby test/catalog_test.rb --seed 52478
bundle exec bin/check-project-state-contract --suite contracts/project-state/v0.2
```

To check the same fixtures against the pipeline, matcher, and Frontier Pack, run `bin/check-project-state-consumers` with those consumer checkouts available. `AF_WORKSPACE_ROOT` selects their workspace. `AF_DATA_PIPELINE_ROOT` selects the pipeline code checkout explicitly. In the other direction, the pipeline can use `AF_XLSX_FILES_ROOT` to select this library by absolute path.

[MIT License](LICENSE)
