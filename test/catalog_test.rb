# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/af_xlsx_files"

# Exercises public owner mechanics with PL absent; no workflow authority or
# real Git store is supplied by these content-free representation fixtures.
class CatalogTest < Minitest::Test
  # Check the canonical nine positive/negative cases through XL's real validator.
  def test_canonical_role_oracle
    suite = File.expand_path("../contracts/project-state/v0.2", __dir__)
    cases = YAML.safe_load_file(File.join(suite, "cases.yml")).fetch("cases")
    assert_equal 9, cases.length
    cases.each do |name, expectation|
      state = AfXlsxFiles::ProjectState.new(manifest_path: File.join(suite, "fixtures", name, "PROJECT_STATE.yml"))
      if expectation.fetch("valid")
        assert state.validate!
        AfXlsxFiles::ProjectState::ROLES.each { |role| assert_equal role, state.resolve(role).name }
      else
        assert_raises(AfXlsxFiles::Error, name) { state.validate! }
      end
    end
    refute AfXlsxFiles::ProjectState.public_instance_methods.include?(:promote!)
    refute AfXlsxFiles::ProjectState.private_instance_methods.include?(:write_atomic!)
  end

  # Inspect exact empty parts, explicit capacities/styles, guards and blank cells.
  def test_public_empty_representation
    Dir.mktmpdir("xl-empty-", File.realpath(Dir.tmpdir)) do |root|
      path = empty(root)
      workbook = AfXlsxFiles::BoundaryFreezeApply::Workbook.new(path)
      assert_equal ["Adventure Catalog", "AMC >100pg", "Current Books"], workbook.sheet_identity.map(&:first)
      [["Adventure Catalog", 2], ["AMC >100pg", 3]].each do |name, first|
        sheet = workbook.sheet_by_name!(name)
        assert_empty sheet.catalog_records
        assert_equal [first, first + 1], sheet.next_available_rows(2)
        assert_raises(AfXlsxFiles::ValidationError) { sheet.next_available_rows(5) }
        assert_equal "3", sheet.cell("A#{first}").attributes["s"]
        assert_nil sheet.cell_value("L#{first}")
      end
      books = workbook.sheet_by_name!("Current Books")
      assert_equal [4], books.rows_with_nonblank("C")
      assert_equal [4], books.rows_with_nonblank("H")
      assert_equal "IF($B$2=0,0,B4/$B$2)", books.cell_formula(books.cell("A4"))
      assert_equal "IF($G$2=0,0,G4/$G$2)", books.cell_formula(books.cell("F4"))
      assert_equal 0, books.cell_value("B2")
      assert_equal 0, workbook.sheet_by_name!("AMC >100pg").cell_value("B2")
      assert_equal "PASS", AfXlsxFiles::AmcCompatibilityCheck.validate!(candidate_path: path).fetch("status")
      Zip::File.open(path) do |zip|
        assert_equal 8, zip.entries.length
        assert_includes zip.read("[Content_Types].xml"), '/xl/styles.xml'
        assert_includes zip.read("xl/_rels/workbook.xml.rels"), 'Target="styles.xml"'
      end
      replica_root = File.join(root, "replica")
      Dir.mkdir(replica_root)
      assert_equal Digest::SHA256.file(path).hexdigest, Digest::SHA256.file(empty(replica_root)).hexdigest
    end
  end

  def test_empty_catalog_supports_release_fill_transitions
    Dir.mktmpdir("xl-release-fills-", File.realpath(Dir.tmpdir)) do |root|
      path = empty(root)
      styles = AfXlsxFiles::AmcApply::Workbook.new(path).styles
      numeric_style = 1
      review_style = styles.red_style_for(numeric_style)
      accepted_style = styles.style_for_fill(review_style, "#D0E0E3")

      assert_equal "#F4CCCC", styles.fill_rgb(review_style.to_s)
      assert_equal "#D0E0E3", styles.fill_rgb(accepted_style.to_s)
      assert_equal styles.base_signature(numeric_style), styles.base_signature(review_style)
      assert_equal styles.base_signature(numeric_style), styles.base_signature(accepted_style)
    end
  end

  # Invalid capacity/identity, existing destinations and symlink ancestors refuse.
  def test_empty_refusals_publish_nothing
    Dir.mktmpdir("xl-empty-refusal-", File.realpath(Dir.tmpdir)) do |root|
      [0, -1, 1.0, nil, 1000].each do |invalid|
        assert_raises(AfXlsxFiles::ValidationError) { empty(root, ordinary_capacity: invalid) }
        assert_empty Dir.children(root)
      end
      assert_raises(AfXlsxFiles::ValidationError) { empty(root, version: "bad") }
      path = empty(root)
      original = Digest::SHA256.file(path).hexdigest
      assert_raises(AfXlsxFiles::ValidationError) { empty(root) }
      assert_equal original, Digest::SHA256.file(path).hexdigest
      link = File.join(root, "linked")
      File.symlink(root, link)
      assert_raises(AfXlsxFiles::ValidationError) { empty(link) }
    end
  end

  # Read scalar sentinels through the standalone parser without normalizing them
  # to blank, then refuse construction into the occupied finite assessment slot.
  def test_blank_zero_negative_and_uncertain_are_distinct
    Dir.mktmpdir("xl-scalars-", File.realpath(Dir.tmpdir)) do |root|
      base = empty(root)
      Zip::File.open(base) do |zip|
        part = "xl/worksheets/sheet1.xml"
        document = REXML::Document.new(zip.read(part))
        {"L2" => 0, "M2" => -1, "J2" => "Uncertain"}.each do |reference, value|
          cell = REXML::XPath.first(document, "//s:c[@r='#{reference}']", AfXlsxFiles::AmcApply::NS)
          cell.attributes["t"] = value.is_a?(String) ? "str" : "n"
          cell.add_element("v").text = value.to_s
        end
        zip.get_output_stream(part) { |stream| stream.write(document.to_s) }
      end
      sheet = AfXlsxFiles::BoundaryFreezeApply::Workbook.new(base).sheet_by_name!("Adventure Catalog")
      assert_equal [0, -1, "Uncertain", nil], %w[L2 M2 J2 K2].map { |reference| sheet.cell_value(reference) }
      %w[L2 M2 J2].each { |reference| refute sheet.blank_cell?(sheet.cell(reference)) }
      assert sheet.blank_cell?(sheet.cell("K2"))
      input = mechanical_input(root, base, [2])
      assert_raises(AfXlsxFiles::ValidationError) { AfXlsxFiles::BoundaryFreezeApply.plan!(**input) }
    end
  end

  # The one kernel allocates in frozen order across sheets, preserves prior
  # records on second insertion, and independently verifies exact mutated cells.
  def test_plan_construct_second_insertion_and_integrity
    Dir.mktmpdir("xl-kernel-", File.realpath(Dir.tmpdir)) do |root|
      base = empty(root)
      input = mechanical_input(root, base, [100, 2])
      plan = AfXlsxFiles::BoundaryFreezeApply.plan!(**input)
      assert_equal %w[ADV-0001 ADV-0002], plan.fetch("records").map { |record| record.fetch("adventure_id") }
      assert_equal [["AMC >100pg", 3], ["Adventure Catalog", 2]], plan.fetch("records").map { |record| record.values_at("sheet", "row") }
      output = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
      result = AfXlsxFiles::BoundaryFreezeApply.apply!(**input, output_path: output)
      assert_equal plan.fetch("records"), result.report.fetch("records")
      assert AfXlsxFiles::BoundaryFreezeApply.verify_bound!(**input.except(:registry_path), output_amc: output).fetch("passed")
      assert_equal "PASS", AfXlsxFiles::AmcCompatibilityCheck.validate!(candidate_path: output, base_path: base).fetch("status")
      Zip::File.open(output) do |zip|
        part = "xl/worksheets/sheet3.xml"
        xml = zip.read(part).sub("IF($B$2=0,0,B5/$B$2)", "B5/$B$2")
        zip.get_output_stream(part) { |stream| stream.write(xml) }
      end
      historical_sha = Digest::SHA256.file(output).hexdigest
      assert AfXlsxFiles::BoundaryFreezeApply.verify_bound!(**input.except(:registry_path), output_amc: output).fetch("passed")
      assert_equal historical_sha, Digest::SHA256.file(output).hexdigest
      second = mechanical_input(root, output, [3, 101], suffix: "second")
      second_output = File.join(root, "5e_Adventure_Master_Catalog_0.3.xlsx")
      next_result = AfXlsxFiles::BoundaryFreezeApply.apply!(**second, output_path: second_output)
      assert_equal %w[ADV-0003 ADV-0004], next_result.report.fetch("records").map { |record| record.fetch("adventure_id") }
      assert_equal "PASS", AfXlsxFiles::AmcCompatibilityCheck.validate!(candidate_path: second_output, base_path: output).fetch("status")
      before = AfXlsxFiles::BoundaryFreezeApply::Workbook.new(output)
      after = AfXlsxFiles::BoundaryFreezeApply::Workbook.new(second_output)
      ["Adventure Catalog", "AMC >100pg"].each do |name|
        original = before.sheet_by_name!(name)
        target = after.sheet_by_name!(name)
        original.catalog_records.each do |record|
          original.cell_snapshots.each do |reference, value|
            next unless AfXlsxFiles::AmcApply.reference_parts(reference).last == record.fetch("row")
            assert_equal value, target.cell_snapshots.fetch(reference)
          end
        end
      end
      # Alter an otherwise authorized cell's formula while retaining its cache.
      Zip::File.open(output) do |zip|
        part = "xl/worksheets/sheet1.xml"
        xml = zip.read(part).sub("COUNT(I2:U2)", "SUM(I2:U2)")
        zip.get_output_stream(part) { |stream| stream.write(xml) }
      end
      assert_raises(AfXlsxFiles::ValidationError) { AfXlsxFiles::BoundaryFreezeApply.verify_bound!(**input.except(:registry_path), output_amc: output) }
    end
  end

  # Changed bound evidence and source-side exhaustion refuse before output.
  def test_changed_bindings_and_independent_capacity
    Dir.mktmpdir("xl-bindings-", File.realpath(Dir.tmpdir)) do |root|
      base = empty(root, source_capacity: 1, publisher_capacity: 2)
      input = mechanical_input(root, base, [2])
      original = File.binread(input.fetch(:freeze_path))
      File.write(input.fetch(:freeze_path), original + "# changed\n")
      assert_raises(AfXlsxFiles::ValidationError) { AfXlsxFiles::BoundaryFreezeApply.plan!(**input) }
      File.binwrite(input.fetch(:freeze_path), original)
      output = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
      AfXlsxFiles::BoundaryFreezeApply.apply!(**input, output_path: output)
      second = mechanical_input(root, output, [2], suffix: "second")
      refused = File.join(root, "refused.xlsx")
      assert_raises(AfXlsxFiles::ValidationError) { AfXlsxFiles::BoundaryFreezeApply.apply!(**second, output_path: refused) }
      refute File.exist?(refused)
      refute File.exist?(AfXlsxFiles::BoundaryFreezeApply.default_report_path(refused))
    end
  end

  # Plan, publish and independently verify with the identical padded input.
  # Normalization must cover catalog cells and Current Books reconstruction.
  def test_padded_publisher_uses_identical_plan_apply_and_verify_inputs
    Dir.mktmpdir("xl-publisher-", File.realpath(Dir.tmpdir)) do |root|
      input = mechanical_input(root, empty(root), [100, 2]).merge(publisher: "  Mechanical Publisher \t")
      plan = AfXlsxFiles::BoundaryFreezeApply.plan!(**input)
      output = File.join(root, "5e_Adventure_Master_Catalog_0.2.xlsx")
      result = AfXlsxFiles::BoundaryFreezeApply.apply!(**input, output_path: output)
      %w[records changed_cells current_books].each do |key|
        assert_equal plan.fetch(key), result.report.fetch(key)
      end
      assert_equal "Mechanical Publisher", result.report.dig("source", "book_publisher")
      assert AfXlsxFiles::BoundaryFreezeApply.verify_bound!(**input, output_amc: output).fetch("passed")
      assert_raises(AfXlsxFiles::ValidationError) do
        AfXlsxFiles::BoundaryFreezeApply.verify_bound!(**input.merge(publisher: "Different Publisher"), output_amc: output)
      end
    end
  end

  private

  # Construct only a mechanical empty public representation; returns its path.
  def empty(root, **overrides)
    AfXlsxFiles::EmptyCatalog.create!(**{path: File.join(root, "5e_Adventure_Master_Catalog_0.1.xlsx"),
      version: "0.1", ordinary_capacity: 4, large_capacity: 4, source_capacity: 2, publisher_capacity: 2}.merge(overrides))
  end

  # Supply explicitly bound mechanical kernel inputs, not PL approval evidence.
  # Returns kwargs; source/records contain existing content-free markers only.
  def mechanical_input(root, base, lengths, suffix: "first")
    source = File.join(root, "source-#{suffix}")
    Dir.mkdir(source)
    File.write(File.join(source, "mechanical.md"), (1..lengths.max).map { |page| "<!-- Printed Page #{page} -->\n#{page}\n" }.join)
    registry = File.join(source, "source_registry.yml")
    source_id = suffix == "first" ? "Mechanical Source" : "Second Mechanical Source"
    File.write(registry, YAML.dump("schema_version" => "adventurefinder-source-registry/v0.1", "sources" => {source_id => {"file" => "mechanical.md"}}))
    artifact = {"schema_version" => "af-boundary-freeze/v0.1", "state" => "frozen",
      "source" => {"canonical_source_id" => source_id, "registry_filename" => File.basename(registry),
        "registry_sha256" => Digest::SHA256.file(registry).hexdigest,
        "markdown_files" => [{"filename" => "mechanical.md", "sha256" => Digest::SHA256.file(File.join(source, "mechanical.md")).hexdigest}]},
      "base_amc" => {"filename" => File.basename(base), "sha256" => Digest::SHA256.file(base).hexdigest},
      "approval" => {"approved_by" => "Mechanical reviewer", "approved_at" => "2026-10-08T01:00:00Z"},
      "records" => lengths.each_with_index.map { |length, index| {"local_key" => "record-#{index}", "canonical_title" => "Mechanical Record #{index}",
        "printed_pages" => {"start" => 1, "end" => length}, "levels" => nil, "editorial_rationale" => "Mechanical test decision.", "state" => "frozen"} }}
    freeze = File.join(root, "frozen-#{suffix}.yml")
    File.write(freeze, YAML.dump(artifact))
    {freeze_path: freeze, source_root: source, amc_path: base, artifact:,
      freeze_sha256: Digest::SHA256.file(freeze).hexdigest, amc_sha256: Digest::SHA256.file(base).hexdigest,
      publisher: suffix == "first" ? "Mechanical Publisher" : "Second Mechanical Publisher"}
  end
end
