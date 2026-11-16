# Project-state v0.2 conformance suite

This directory is the canonical fixture-based contract test for
`adventurefinder-project-state/v0.2`.

`cases.yml` is the oracle. Every named fixture under `fixtures/` must be accepted
or rejected by each project-state consumer according to its `valid` value.
Consumers use their own production parser/validator; this directory shares test
data, not implementation code.

Routine `PROJECT_STATE.yml` role promotions do not require fixture or consumer
changes when the v0.2 semantics are unchanged. When the schema or its semantics
change, update this suite first and run the workspace check:

```bash
bin/check-project-state-consumers
```

The workspace check intentionally expects the three consumer repositories to be
available as siblings under the AdventureFinder workspace root. Set
`AF_WORKSPACE_ROOT` to override that root.

Set `AF_DATA_PIPELINE_ROOT` to select the pipeline executable checkout explicitly,
including an `af-pipeline` directory. This takes precedence over the conventional
`$AF_WORKSPACE_ROOT/af-data-pipeline` location; an invalid selection never falls
back. It must be an existing absolute code directory without `.` or `..` path
segments or symlink ancestors, with executable `bin/af-data` and
`bin/check-project-state-contract` and the pipeline project-state validator.
The code root may be outside the workspace. Selecting another consumer or a
private data directory fails; `AF_DATA_PIPELINE_DATA_ROOT` does not select code.
The operator remains responsible for verifying the selected source's provenance;
these structural checks are not authentication of arbitrary executable code.
Matcher and frontier discovery remain relative to `AF_WORKSPACE_ROOT`. Neither
selector changes catalog authority or the canonical suite supplied to consumers.

Run the focused discovery regression tests with real consumer checkouts available
under `AF_WORKSPACE_ROOT` (or the catalog checkout's parent by default):

```bash
ruby test/check_project_state_consumers_test.rb
```

The tests copy tracked source files into disposable roots under `TMPDIR`; set it
to an authorized scratch directory. They retain command metadata and raw output
there for review and do not run consumer application workloads.
