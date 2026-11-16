# frozen_string_literal: true

module AfXlsxFiles
  # Deterministically materializes one validated boundary freeze into a new AMC.
  # It assigns Adventure IDs, fills only preallocated catalog/current-book cells,
  # and proves every workbook mutation in an integrity report.
  class BoundaryFreezeApply
    COMMAND_SCHEMA = "af-data-boundary-freeze-apply/v0.1"
    REPORT_SCHEMA = "af-boundary-freeze-apply-report/v0.1"
    ADV_ID_RE = /\AADV-(\d{4,})\z/
    AMC_FILENAME_RE = /\A5e_Adventure_Master_Catalog_(?<version>\d+(?:\.\d+)+)\.xlsx\z/
    SUCCESSOR_VERSION_RE = /\A\d+(?:\.\d+)+\z/
    ORDINARY_SHEET = "Adventure Catalog"
    LARGE_SHEET = "AMC >100pg"
    BOOKS_SHEET = "Current Books"
    LARGE_THRESHOLD = 100
    SPECIAL_LARGE_LABEL = ">100 page Adventures"
    MAIN_NS = AmcApply::MAIN_NS
    OFFICE_REL_NS = AmcApply::OFFICE_REL_NS
    PACKAGE_REL_NS = AmcApply::PACKAGE_REL_NS
    NS = AmcApply::NS
    ASSESSMENT_HEADERS = AmcApply::DIMENSION_HEADERS.values.freeze

    Result = Data.define(:output_path, :report_path, :report)
    SuccessorPaths = Data.define(:output_path, :report_path, :base_version, :successor_version)

    # Build and exclusively publish a successor and unchanged-schema report from bound records; invalid/conflicting/drifting inputs raise ValidationError.
    def self.apply!(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:, output_path:,
                    report_path: nil, registry_path: nil, progress: nil)
      new(
        freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:, output_path:,
        report_path:, registry_path:, progress:
      ).apply!
    end

    # Return the deterministic integrity-report path beside an explicit output workbook; no file is created.
    def self.default_report_path(output_path)
      File.expand_path(output_path).sub(/\.xlsx\z/i, "") + ".boundary-freeze-apply-report.json"
    end

    # Reconstruct allocation from actual base/freeze evidence, never from a
    # caller's integrity-report records. No output path is opened or written.
    def self.plan!(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:, registry_path: nil)
      reconstruct!(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:, registry_path:).last
    end

    # Reconstruct exact in-memory cells and plan from bound admitted records.
    # Returns [Workbook, plan]; invalid representation/bindings raise ValidationError.
    def self.reconstruct!(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:, registry_path: nil)
      validate_input!(freeze_path:, source_root:, amc_path:, artifact:, freeze_sha256:, amc_sha256:)
      publisher = publisher.to_s.strip
      raise ValidationError, "--publisher must be a nonblank string" if publisher.empty?
      planner = new(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:,
                    output_path: amc_path, report_path: nil, registry_path:, progress: nil)
      workbook = Workbook.new(amc_path)
      ordinary = workbook.sheet_by_name!(ORDINARY_SHEET)
      large = workbook.sheet_by_name!(LARGE_SHEET)
      books = workbook.sheet_by_name!(BOOKS_SHEET)
      ordinary.validate_catalog_schema!
      large.validate_catalog_schema!
      records = artifact.fetch("records")
      source_id = artifact.dig("source", "canonical_source_id")
      planner.send(:validate_global_catalog!, ordinary, large, source_id, records)
      planner.send(:validate_existing_publisher!, ordinary, large, books, source_id)
      mirrors = planner.send(:large_sheet_mirrors_ordinary?, ordinary, large)
      plan = planner.send(:build_plan, records, ordinary, large, large_sheet_mirrors_ordinary: mirrors)
      plan.each do |row|
        sheet = row.fetch("sheet") == ORDINARY_SHEET ? ordinary : large
        row["changed_cells"] = sheet.write_catalog_record!(
          row_number: row.fetch("row"), adventure_id: row.fetch("adventure_id"),
          title: row.fetch("canonical_title"), source_id:, publisher:,
          start_page: row.dig("printed_pages", "start"), end_page: row.dig("printed_pages", "end"),
          levels: row["levels"]
        )
      end
      large.refresh_large_count! unless mirrors
      current_books = books.refresh_current_books!(ordinary:, large:, source_id:, publisher:,
                                                   large_sheet_mirrors_ordinary: mirrors)
      [workbook, {"records" => plan, "changed_cells" => workbook.changed_cells, "current_books" => current_books}]
    end

    # Return canonical output/report paths for an explicitly selected version; malformed identity or missing output directory raises ValidationError.
    def self.derive_successor_paths(freeze_path:, amc_path:, successor_version:, amc_dir:, report_path: nil)
      successor_version = successor_version.to_s.strip
      unless SUCCESSOR_VERSION_RE.match?(successor_version)
        raise ValidationError, "--successor-version must contain only dot-separated numeric components (for example, 4.26)"
      end

      match = AMC_FILENAME_RE.match(File.basename(amc_path))
      unless match
        raise ValidationError,
              "--amc must use the versioned filename 5e_Adventure_Master_Catalog_VERSION.xlsx in deterministic successor mode"
      end
      base_version = match[:version]
      if successor_version == base_version
        raise ValidationError, "--successor-version must differ from base AMC version #{base_version}"
      end

      amc_dir = File.expand_path(amc_dir)
      raise ValidationError, "--amc-dir does not exist: #{amc_dir}" unless File.directory?(amc_dir)

      output_path = File.join(amc_dir, "5e_Adventure_Master_Catalog_#{successor_version}.xlsx")
      report_path ||= standard_report_path(
        freeze_path:, base_version:, successor_version:
      )
      SuccessorPaths.new(
        output_path: File.expand_path(output_path),
        report_path: File.expand_path(report_path),
        base_version:,
        successor_version:
      )
    end

    # Return the existing freeze/base/successor-derived report filename; no version or authority is inferred.
    def self.standard_report_path(freeze_path:, base_version:, successor_version:)
      basename = File.basename(freeze_path, File.extname(freeze_path))
      identity = basename.sub(/-boundary-freeze(?:-from-amc-\d+(?:\.\d+)*)?\z/, "")
      File.join(
        File.dirname(File.expand_path(freeze_path)),
        "#{identity}-boundary-freeze-apply-report-from-amc-#{base_version}-to-#{successor_version}.json"
      )
    end

    # Bind explicit representation inputs and initialize parsed/cached state; returns an instance, propagating XML/ZIP/I/O/validation errors when parsing occurs.
    def initialize(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:, output_path:,
                   report_path:, registry_path:, progress:)
      @artifact = Marshal.load(Marshal.dump(artifact))
      @freeze_sha256 = freeze_sha256
      @amc_sha256 = amc_sha256
      @freeze_path = File.expand_path(freeze_path)
      @source_root = File.expand_path(source_root)
      @amc_path = File.expand_path(amc_path)
      @publisher = publisher.to_s.strip
      @output_path = File.expand_path(output_path)
      @report_path = File.expand_path(report_path || self.class.default_report_path(@output_path))
      @registry_path = registry_path
      @progress = progress
    end

    # Build and exclusively publish a successor and unchanged-schema report from bound records; invalid/conflicting/drifting inputs raise ValidationError.
    def apply!
      validate_paths!
      raise ValidationError, "--publisher must be a nonblank string" if @publisher.empty?

      source_sha = Digest::SHA256.file(@amc_path).hexdigest
      freeze_sha = Digest::SHA256.file(@freeze_path).hexdigest
      progress("[freeze] validating boundary freeze")
      self.class.validate_input!(freeze_path: @freeze_path, source_root: @source_root,
        amc_path: @amc_path, artifact: @artifact, freeze_sha256: @freeze_sha256, amc_sha256: @amc_sha256)
      raise ValidationError, "boundary freeze changed during validation" unless stable_sha?(@freeze_path, freeze_sha)

      artifact = @artifact
      records = artifact.fetch("records")
      raise ValidationError, "boundary freeze contains no records; no successor AMC is needed" if records.empty?
      source_id = artifact.dig("source", "canonical_source_id")

      progress("[preflight] opening explicit base AMC")
      workbook = Workbook.new(@amc_path)
      ordinary = workbook.sheet_by_name!(ORDINARY_SHEET)
      large = workbook.sheet_by_name!(LARGE_SHEET)
      books = workbook.sheet_by_name!(BOOKS_SHEET)
      ordinary.validate_catalog_schema!
      large.validate_catalog_schema!
      validate_global_catalog!(ordinary, large, source_id, records)
      large_sheet_mirrors_ordinary = large_sheet_mirrors_ordinary?(ordinary, large)
      validate_existing_publisher!(ordinary, large, books, source_id)

      plan = build_plan(
        records, ordinary, large,
        large_sheet_mirrors_ordinary:
      )
      progress(
        "[preflight] #{plan.length} record(s); " \
        "#{plan.count { |row| row.fetch('sheet') == ORDINARY_SHEET }} #{ORDINARY_SHEET}, " \
        "#{plan.count { |row| row.fetch('sheet') == LARGE_SHEET }} #{LARGE_SHEET}"
      )

      plan.each do |row|
        sheet = row.fetch("sheet") == ORDINARY_SHEET ? ordinary : large
        row["changed_cells"] = sheet.write_catalog_record!(
          row_number: row.fetch("row"),
          adventure_id: row.fetch("adventure_id"),
          title: row.fetch("canonical_title"),
          source_id:,
          publisher: @publisher,
          start_page: row.dig("printed_pages", "start"),
          end_page: row.dig("printed_pages", "end"),
          levels: row["levels"]
        )
      end
      large.refresh_large_count! unless large_sheet_mirrors_ordinary
      current_books = books.refresh_current_books!(
        ordinary:, large:, source_id:, publisher: @publisher,
        large_sheet_mirrors_ordinary:
      )

      changes = workbook.changed_cells
      temp_output = temporary_path(File.dirname(@output_path), ".boundary-freeze-apply-", ".xlsx")
      temp_report = temporary_path(File.dirname(@report_path), ".boundary-freeze-apply-report-", ".json")
      begin
        progress("[write] preparing successor workbook")
        FileUtils.cp(@amc_path, temp_output)
        FileUtils.chmod(File.stat(@amc_path).mode & 0o777, temp_output)
        replace_zip_members!(temp_output, workbook.changed_xml_parts)

        progress("[verify] checking exact workbook mutations")
        verification = self.class.verify_bound!(freeze_path: @freeze_path, source_root: @source_root,
          amc_path: @amc_path, output_amc: temp_output, publisher: @publisher, artifact: @artifact,
          freeze_sha256: @freeze_sha256, amc_sha256: @amc_sha256)
        raise ValidationError, "source AMC changed during apply" unless stable_sha?(@amc_path, source_sha)
        raise ValidationError, "boundary freeze changed during apply" unless stable_sha?(@freeze_path, freeze_sha)

        self.class.validate_input!(freeze_path: @freeze_path, source_root: @source_root,
          amc_path: @amc_path, artifact: @artifact, freeze_sha256: @freeze_sha256, amc_sha256: @amc_sha256)
        output_sha = Digest::SHA256.file(temp_output).hexdigest
        report = build_report(
          artifact:, freeze_sha:, source_sha:, output_sha:, plan:, changes:,
          current_books:, verification:
        )
        File.write(temp_report, JSON.pretty_generate(report) + "\n", encoding: "UTF-8")

        progress("[publish] writing successor workbook and integrity report")
        publish_new_file!(temp_output, @output_path)
        begin
          publish_new_file!(temp_report, @report_path)
        rescue StandardError
          FileUtils.rm_f(@output_path)
          raise
        end
        progress("[publish] complete")
        Result.new(output_path: @output_path, report_path: @report_path, report:)
      ensure
        FileUtils.rm_f(temp_output)
        FileUtils.rm_f(temp_report)
      end
    rescue Zip::Error, REXML::ParseException => e
      raise ValidationError, "AMC XLSX parse failure: #{e.message}"
    rescue SystemCallError => e
      raise ValidationError, "boundary freeze apply file operation failed: #{e.message}"
    end

    # Check independently bound representation input; no editorial or operation
    # authority is inferred from this artifact. Raises ValidationError on drift.
    def self.validate_input!(freeze_path:, source_root:, amc_path:, artifact:, freeze_sha256:, amc_sha256:)
      InputBinding.validate!(freeze_path:, source_root:, amc_path:, artifact:, freeze_sha256:, amc_sha256:)
    end

    # Independently reconstruct all allowed values, formulas and styles from
    # actual base and admitted records. Returns the original verification shape;
    # supplied report records/changed-cell maps cannot authorize mutations.
    def self.verify_bound!(freeze_path:, source_root:, amc_path:, output_amc:, publisher:, artifact:, freeze_sha256:, amc_sha256:)
      publisher = publisher.to_s.strip
      expected, plan = reconstruct!(freeze_path:, source_root:, amc_path:, publisher:, artifact:, freeze_sha256:, amc_sha256:)
      verification = verify!(source_amc: amc_path, output_amc:, plan: plan.fetch("records"),
        changes: plan.fetch("changed_cells"), source_id: artifact.dig("source", "canonical_source_id"),
        publisher:, current_books: plan.fetch("current_books"))
      actual = Workbook.new(output_amc)
      expected.sheet_parts.each do |part|
        expected_sheet = expected.sheet(part)
        actual_sheet = actual.sheet(part)
        actual_cells = actual_sheet.cell_snapshots
        if expected_sheet.name == BOOKS_SHEET
          normalize_legacy_ratios!(actual_cells, expected_sheet, actual_sheet)
        end
        unless expected_sheet.cell_snapshots == actual_cells
          raise ValidationError, "boundary freeze apply differs from reconstructed cells/formulas/styles: #{part}"
        end
      end
      verification
    end

    # Normalize only the documented literal ratio alternative at a positive
    # denominator for in-memory comparison. Cache/style/other XML stays exact;
    # neither input nor historical artifact bytes are rewritten. Returns nil.
    def self.normalize_legacy_ratios!(snapshots, expected, actual)
      expected.cell_references.each do |reference|
        match = /\A([AF])([1-9]\d*)\z/.match(reference)
        next unless match
        numerator = match[1] == "A" ? "B" : "G"
        denominator = "$#{numerator}$2"
        literal = "#{numerator}#{match[2]}/#{denominator}"
        guarded = "IF(#{denominator}=0,0,#{literal})"
        next unless expected.cell_formula(expected.cell(reference)) == guarded && actual.cell_formula(actual.cell(reference)) == literal
        total = actual.cell_value("#{numerator}2")
        next unless total.is_a?(Numeric) && total.positive? && total == expected.cell_value("#{numerator}2")

        comparison = actual.cell(reference).deep_clone
        comparison.elements.find { |element| element.name == "f" }.text = guarded
        snapshots[reference] = AmcApply.canonical_element(comparison)
      end
      nil
    end
    private_class_method :normalize_legacy_ratios!

    # Compare explicit base/output using the supplied low-level mutation plan and return verification counts; unauthorized changes raise ValidationError.
    def self.verify!(source_amc:, output_amc:, plan:, changes:, source_id:, publisher:, current_books:)
      source = Workbook.new(source_amc)
      output = Workbook.new(output_amc)
      errors = []

      errors << "XLSX package member order or membership changed" unless source.entry_names == output.entry_names
      errors << "workbook sheet names/order changed" unless source.sheet_identity == output.sheet_identity

      authorized = changes.each_with_object({}) do |(part, refs), memo|
        refs.each { |ref| memo[[part, ref]] = true }
      end
      changed_parts = (source.member_hashes.keys | output.member_hashes.keys).select do |name|
        source.member_hashes[name] != output.member_hashes[name]
      end
      allowed_parts = changes.select { |_part, refs| refs.any? }.keys
      unexpected_parts = changed_parts - allowed_parts
      errors << "unexpected XLSX package members changed: #{unexpected_parts.join(', ')}" unless unexpected_parts.empty?

      source.sheet_parts.each do |part|
        before = source.sheet(part)
        after = output.sheet(part)
        unless after
          errors << "worksheet missing after apply: #{part}"
          next
        end
        errors << "worksheet structure changed outside cells: #{part}" unless before.structure_signature == after.structure_signature

        before_cells = before.cell_snapshots
        after_cells = after.cell_snapshots
        (before_cells.keys | after_cells.keys).each do |reference|
          next if before_cells[reference] == after_cells[reference]
          next if authorized[[part, reference]]

          errors << "unauthorized worksheet cell change: #{part}!#{reference}"
        end
      end

      plan.each do |record|
        sheet = output.sheet_by_name!(record.fetch("sheet"))
        row = record.fetch("row")
        expect_value(errors, sheet, "A#{row}", record.fetch("adventure_id"), record)
        expect_value(errors, sheet, "B#{row}", record.fetch("canonical_title"), record)
        expect_value(errors, sheet, "E#{row}", source_id, record)
        expect_value(errors, sheet, "F#{row}", publisher, record)
        expect_value(errors, sheet, "G#{row}", record.dig("printed_pages", "start"), record)
        expect_value(errors, sheet, "H#{row}", record.dig("printed_pages", "end"), record)
        page_count = record.dig("printed_pages", "end") - record.dig("printed_pages", "start") + 1
        expect_value(errors, sheet, "D#{row}", page_count, record)

        levels = record["levels"]
        level_start = sheet.column_for_header("Level Start")
        level_end = sheet.column_for_header("Level End")
        expect_value(errors, sheet, "#{level_start}#{row}", levels && levels.fetch("start"), record)
        expect_value(errors, sheet, "#{level_end}#{row}", levels && levels.fetch("end"), record)

        (ASSESSMENT_HEADERS - ["Level Start", "Level End"]).each do |header|
          column = sheet.column_for_header(header)
          next unless column
          cell = sheet.cell("#{column}#{row}")
          unless sheet.blank_cell?(cell) && sheet.cell_formula(cell).nil?
            errors << "unassessed scoring field is not blank: #{record.fetch('sheet')}!#{column}#{row} (#{header})"
          end
        end
      end

      books = output.sheet_by_name!(BOOKS_SHEET)
      source_row = current_books.fetch("source_row")
      publisher_row = current_books.fetch("publisher_row")
      errors << "Current Books source identity mismatch" unless books.cell_value("C#{source_row}") == source_id
      errors << "Current Books source publisher mismatch" unless books.cell_value("D#{source_row}") == publisher
      errors << "Current Books publisher identity mismatch" unless books.cell_value("H#{publisher_row}") == publisher

      raise ValidationError, "boundary freeze apply verification failed:\n- #{errors.join("\n- ")}" unless errors.empty?

      {
        "passed" => true,
        "authorized_cell_changes" => authorized.length,
        "unauthorized_cell_changes" => 0,
        "package_members_changed" => changed_parts,
        "unexpected_package_member_changes" => [],
        "records_verified" => plan.length,
        "unassessed_scoring_fields_verified_blank" => plan.length
      }
    end

    # Append a labeled written-cell mismatch to errors when the actual value differs from its expected admitted scalar.
    def self.expect_value(errors, sheet, reference, expected, record)
      actual = sheet.cell_value(reference)
      return if expected.nil? ? actual.nil? : actual == expected

      errors << "written value verification failed: #{record.fetch('sheet')}!#{reference}; expected=#{expected.inspect} actual=#{actual.inspect}"
    end

    private

    # Send a diagnostic string to the optional progress observer; its exceptions propagate and grant no authority.
    def progress(message)
      @progress&.call(message)
    end

    # Check explicit input/output/report paths and refuse conflicts or unsafe identity reuse with ValidationError before publication.
    def validate_paths!
      raise ValidationError, "boundary freeze does not exist: #{@freeze_path}" unless File.file?(@freeze_path)
      raise ValidationError, "source root does not exist: #{@source_root}" unless File.directory?(@source_root)
      raise ValidationError, "base AMC does not exist: #{@amc_path}" unless File.file?(@amc_path)
      raise ValidationError, "--output must end in .xlsx" unless @output_path.match?(/\.xlsx\z/i)
      raise ValidationError, "--report must be a different file from --output" if @report_path == @output_path
      unless File.directory?(File.dirname(@output_path))
        raise ValidationError, "output directory does not exist: #{File.dirname(@output_path)}"
      end
      unless File.directory?(File.dirname(@report_path))
        raise ValidationError, "report directory does not exist: #{File.dirname(@report_path)}"
      end
      source_identity = File.realpath(@amc_path)
      output_identity = File.join(File.realpath(File.dirname(@output_path)), File.basename(@output_path))
      raise ValidationError, "--output must be a different file from --amc" if source_identity == output_identity
      if File.basename(@output_path) == File.basename(@amc_path)
        raise ValidationError, "--output must use a new successor filename, not the base AMC filename"
      end
      raise ValidationError, "refusing to overwrite existing output workbook: #{@output_path}" if File.exist?(@output_path)
      raise ValidationError, "refusing to overwrite existing integrity report: #{@report_path}" if File.exist?(@report_path)
    end

    # Check global IDs, mirrored identities and source/title collisions across both sheets; conflicts raise ValidationError.
    def validate_global_catalog!(ordinary, large, source_id, records)
      ordinary_catalog = ordinary.catalog_records
      large_catalog = large.catalog_records

      [[ordinary, ordinary_catalog], [large, large_catalog]].each do |sheet, rows|
        duplicate_ids = rows.group_by { |row| row.fetch("adventure_id") }
                            .select { |_id, matches| matches.length > 1 }
        unless duplicate_ids.empty?
          raise ValidationError,
                "duplicate Adventure IDs within #{sheet.name}: #{duplicate_ids.keys.sort.join(', ')}"
        end
      end

      ordinary_by_id = ordinary_catalog.to_h { |row| [row.fetch("adventure_id"), row] }
      large_by_id = large_catalog.to_h { |row| [row.fetch("adventure_id"), row] }
      mirrored_ids = ordinary_by_id.keys & large_by_id.keys

      conflicting_mirrors = mirrored_ids.reject do |adventure_id|
        ordinary_row = ordinary_by_id.fetch(adventure_id)
        large_row = large_by_id.fetch(adventure_id)

        identity_matches = %w[title source_book publisher].all? do |field|
          ordinary_row[field] == large_row[field]
        end

        page_matches = ["Start Page", "End Page"].all? do |header|
          ordinary_column = ordinary.column_for_header(header)
          large_column = large.column_for_header(header)
          ordinary.cell_value("#{ordinary_column}#{ordinary_row.fetch('row')}") ==
            large.cell_value("#{large_column}#{large_row.fetch('row')}")
        end

        identity_matches && page_matches
      end

      unless conflicting_mirrors.empty?
        raise ValidationError,
              "conflicting duplicate Adventure IDs across AMC catalog sheets: #{conflicting_mirrors.sort.join(', ')}"
      end

      catalog = ordinary_catalog + large_catalog
      duplicate_titles = records.filter_map do |record|
        title = record.fetch("canonical_title")
        title if catalog.any? { |row| row["source_book"] == source_id && row["title"] == title }
      end
      unless duplicate_titles.empty?
        raise ValidationError,
              "boundary freeze would duplicate existing source/title rows: #{duplicate_titles.uniq.join(', ')}"
      end
    end

    # Compare the selected publisher against existing catalog/book bindings; conflicting publishers raise ValidationError.
    def validate_existing_publisher!(ordinary, large, books, source_id)
      catalog_publishers = (ordinary.catalog_records + large.catalog_records).filter_map do |row|
        row["publisher"] if row["source_book"] == source_id && present?(row["publisher"])
      end.uniq
      if catalog_publishers.length > 1
        raise ValidationError, "existing AMC source #{source_id.inspect} has conflicting publishers: #{catalog_publishers.join(', ')}"
      end
      if catalog_publishers.one? && catalog_publishers.first != @publisher
        raise ValidationError,
              "--publisher #{@publisher.inspect} conflicts with existing AMC publisher #{catalog_publishers.first.inspect} for #{source_id.inspect}"
      end

      book_publishers = books.rows_with_value("C", source_id).map { |row| books.cell_value("D#{row}") }.select { |value| present?(value) }.uniq
      if book_publishers.length > 1
        raise ValidationError, "Current Books has conflicting publishers for #{source_id.inspect}: #{book_publishers.join(', ')}"
      end
      if book_publishers.one? && book_publishers.first != @publisher
        raise ValidationError,
              "--publisher #{@publisher.inspect} conflicts with Current Books publisher #{book_publishers.first.inspect} for #{source_id.inspect}"
      end
    end

    # Return deterministic ID/row/parent assignments from actual base and frozen record order; capacity/parent conflicts raise ValidationError.
    def build_plan(records, ordinary, large, large_sheet_mirrors_ordinary:)
      existing = ordinary.catalog_records + large.catalog_records
      max_number = existing.map { |row| Integer(ADV_ID_RE.match(row.fetch("adventure_id"))[1], 10) }.max || 0
      assignments = records.each_with_index.to_h do |record, index|
        [record.fetch("local_key"), format("ADV-%04d", max_number + index + 1)]
      end
      existing_ids = existing.to_h { |row| [row.fetch("adventure_id"), row] }

      ordinary_count = if large_sheet_mirrors_ordinary
                         records.length
                       else
                         records.count { |record| page_count(record) < LARGE_THRESHOLD }
                       end
      large_count = records.length - ordinary_count
      ordinary_rows = ordinary.next_available_rows(ordinary_count)
      large_rows = large.next_available_rows(large_count)

      records.map do |record|
        pages = record.fetch("printed_pages")
        target = if large_sheet_mirrors_ordinary || page_count(record) < LARGE_THRESHOLD
                   ordinary
                 else
                   large
                 end
        row = target.equal?(large) ? large_rows.shift : ordinary_rows.shift
        resolved_parent = if present?(record["parent_key"])
                            assignments.fetch(record.fetch("parent_key"))
                          elsif present?(record["parent_adventure_id"])
                            parent_id = record.fetch("parent_adventure_id")
                            unless existing_ids.key?(parent_id)
                              raise ValidationError, "#{record.fetch('local_key')}: parent_adventure_id #{parent_id} does not exist in base AMC"
                            end
                            parent_id
                          end
        {
          "local_key" => record.fetch("local_key"),
          "adventure_id" => assignments.fetch(record.fetch("local_key")),
          "canonical_title" => record.fetch("canonical_title"),
          "printed_pages" => pages,
          "pdf_pages" => record["pdf_pages"],
          "levels" => record["levels"],
          "parent_key" => record["parent_key"],
          "parent_adventure_id" => record["parent_adventure_id"],
          "resolved_parent_adventure_id" => resolved_parent,
          "sheet" => target.name,
          "sheet_part" => target.part,
          "row" => row
        }.compact
      end
    end

    # Return whether every existing large record mirrors the ordinary catalog; mixed overlap raises ValidationError.
    def large_sheet_mirrors_ordinary?(ordinary, large)
      ordinary_ids = ordinary.catalog_records.to_h { |row| [row.fetch("adventure_id"), true] }
      large_rows = large.catalog_records
      return false if large_rows.empty?

      mirrored = large_rows.count { |row| ordinary_ids.key?(row.fetch("adventure_id")) }
      return false if mirrored.zero?
      return true if mirrored == large_rows.length

      raise ValidationError,
            "AMC catalog sheets mix mirrored and non-mirrored records in #{LARGE_SHEET}"
    end

    # Return inclusive printed-page length from an admitted record; required range keys must already be validated.
    def page_count(record)
      pages = record.fetch("printed_pages")
      pages.fetch("end") - pages.fetch("start") + 1
    end

    # Return the existing report schema from bound inputs, actual allocation/hashes and measured verification; no approval is inferred.
    def build_report(artifact:, freeze_sha:, source_sha:, output_sha:, plan:, changes:, current_books:, verification:)
      {
        "schema_version" => REPORT_SCHEMA,
        "command_schema_version" => COMMAND_SCHEMA,
        "status" => "complete",
        "generated_at" => Time.now.utc.iso8601,
        "boundary_freeze" => {
          "path" => File.realpath(@freeze_path),
          "sha256" => freeze_sha,
          "schema_version" => artifact.fetch("schema_version"),
          "approved_by" => artifact.dig("approval", "approved_by"),
          "approved_at" => artifact.dig("approval", "approved_at")
        },
        "source" => artifact.fetch("source").merge("book_publisher" => @publisher),
        "base_amc" => { "path" => File.realpath(@amc_path), "sha256" => source_sha },
        "output_amc" => { "path" => @output_path, "sha256" => output_sha },
        "counts" => {
          "frozen_records" => plan.length,
          "adventure_ids_assigned" => plan.length,
          "ordinary_rows_created" => plan.count { |row| row.fetch("sheet") == ORDINARY_SHEET },
          "large_rows_created" => plan.count { |row| row.fetch("sheet") == LARGE_SHEET },
          "errors" => 0
        },
        "allocation" => {
          "first_adventure_id" => plan.first.fetch("adventure_id"),
          "last_adventure_id" => plan.last.fetch("adventure_id"),
          "order" => "boundary-freeze record order"
        },
        "records" => plan,
        "current_books" => current_books,
        "changed_cells" => changes,
        "verification" => verification
      }
    end

    # Return whether an existing explicit file still matches the expected SHA-256; filesystem errors propagate.
    def stable_sha?(path, expected)
      File.file?(path) && Digest::SHA256.file(path).hexdigest == expected
    end

    # Return whether a supplied value is a nonblank string; no coercion is performed.
    def present?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    # Create and close a same-directory temporary file and return its path; filesystem errors propagate.
    def temporary_path(directory, prefix, suffix)
      tempfile = Tempfile.create([prefix, suffix], directory)
      path = tempfile.path
      tempfile.close
      path
    end

    # Publish the prepared file exclusively by hard link and unlink its temporary name; destination conflicts raise ValidationError.
    def publish_new_file!(temporary, destination)
      File.link(temporary, destination)
      File.unlink(temporary)
    rescue Errno::EEXIST
      raise ValidationError, "refusing to overwrite file created during apply: #{destination}"
    end

    # Replace only explicitly named existing ZIP members; absent required parts raise ValidationError and ZIP/I/O errors propagate.
    def replace_zip_members!(path, replacements)
      Zip::File.open(path) do |zip|
        replacements.each do |name, content|
          entry = zip.find_entry(name)
          raise ValidationError, "required XLSX package member missing: #{name}" unless entry

          zip.get_output_stream(entry) { |stream| stream.write(content) }
        end
      end
    end

    # Explicit workbook/role representation; parses caller inputs and preserves integrity, raising owner validation or native parse/I/O errors.
    class Workbook
      attr_reader :entry_names

      # Bind explicit representation inputs and initialize parsed/cached state; returns an instance, propagating XML/ZIP/I/O/validation errors when parsing occurs.
      def initialize(path)
        @path = File.expand_path(path)
        @members = {}
        @entry_names = []
        Zip::File.open(@path) do |zip|
          zip.each do |entry|
            @entry_names << entry.name
            @members[entry.name] = entry.get_input_stream.read
          end
        end
        %w[xl/workbook.xml xl/_rels/workbook.xml.rels].each do |name|
          raise ValidationError, "required XLSX package member missing: #{name}" unless @members.key?(name)
        end
        @sheet_infos = read_sheet_infos
        @sheets = {}
      end

      # Return memoized SHA-256 by package member from loaded bytes; no filesystem state is inferred.
      def member_hashes
        @member_hashes ||= @members.transform_values { |content| Digest::SHA256.hexdigest(content) }
      end

      # Return sheet names and package paths in workbook order for structural comparison.
      def sheet_identity
        @sheet_infos.map { |info| [info.fetch(:name), info.fetch(:part)] }
      end

      # Return worksheet package paths in workbook order; no sheet selection fallback occurs.
      def sheet_parts
        @sheet_infos.map { |info| info.fetch(:part) }
      end

      # Returns the named package part as a worksheet, or nil when absent.
      # Binds the workbook's style count for explicit first-insertion templates;
      # malformed worksheet/style XML raises REXML::ParseException.
      def sheet(part)
        return nil unless @members.key?(part)
        info = @sheet_infos.find { |item| item.fetch(:part) == part }
        name = info ? info.fetch(:name) : part
        @sheets[part] ||= Worksheet.new(
          name:, part:, xml: @members.fetch(part), shared_strings: shared_strings,
          style_count: (@style_count ||= @members["xl/styles.xml"] && REXML::XPath.match(
            REXML::Document.new(@members.fetch("xl/styles.xml")), "//s:cellXfs/s:xf", NS
          ).length)
        )
      end

      # Return the uniquely named worksheet; absent/ambiguous selection raises ValidationError.
      def sheet_by_name!(name)
        matches = @sheet_infos.select { |info| info.fetch(:name) == name }
        raise ValidationError, "AMC worksheet #{name.inspect} could not be identified uniquely (found #{matches.length})" unless matches.one?

        sheet(matches.first.fetch(:part))
      end

      # Return changed cell references by sheet part in deterministic row/column order.
      def changed_cells
        @sheets.values.select { |sheet| sheet.changed_refs.any? }.to_h do |sheet|
          [sheet.part, sheet.changed_refs.sort_by { |ref| [AmcApply.reference_parts(ref)[1], AmcApply.column_number(AmcApply.reference_parts(ref)[0])] }]
        end
      end

      # Return serialized XML only for changed worksheet parts; no publication occurs.
      def changed_xml_parts
        @sheets.values.select { |sheet| sheet.changed_refs.any? }.to_h { |sheet| [sheet.part, sheet.to_xml] }
      end

      private

      # Return ordered sheet names/paths resolved through workbook relationships; missing targets raise ValidationError.
      def read_sheet_infos
        workbook = REXML::Document.new(@members.fetch("xl/workbook.xml"))
        relationships = REXML::Document.new(@members.fetch("xl/_rels/workbook.xml.rels"))
        targets = {}
        REXML::XPath.each(relationships, "//pr:Relationship", NS) do |relationship|
          targets[relationship.attributes["Id"]] = relationship.attributes["Target"]
        end
        REXML::XPath.match(workbook, "//s:sheets/s:sheet", NS).map do |sheet|
          relationship_id = sheet.attributes.get_attribute_ns(OFFICE_REL_NS, "id")&.value
          target = targets[relationship_id]
          raise ValidationError, "workbook relationship missing for sheet #{sheet.attributes['name'].inspect}" unless target

          part = target.start_with?("/") ? target.delete_prefix("/") : Pathname.new(File.join("xl", target)).cleanpath.to_s
          raise ValidationError, "worksheet package member missing: #{part}" unless @members.key?(part)
          { name: sheet.attributes["name"], part: }
        end
      end

      # Return decoded shared-string values, or an empty array when the optional part is absent; XML errors propagate.
      def shared_strings
        return @shared_strings if defined?(@shared_strings)
        xml = @members["xl/sharedStrings.xml"]
        @shared_strings = if xml
                            document = REXML::Document.new(xml)
                            REXML::XPath.match(document, "//s:sst/s:si", NS).map do |item|
                              REXML::XPath.match(item, ".//s:t", NS).map { |text| text.text.to_s }.join
                            end
                          else
                            []
                          end
      end
    end

    # Explicit workbook/role representation; parses caller inputs and preserves integrity, raising owner validation or native parse/I/O errors.
    class Worksheet
      attr_reader :name, :part, :changed_refs

      # Parses one worksheet with shared strings and an optional cellXfs count.
      # The count is required only for blank first-insertion style declarations.
      # Returns a worksheet; malformed XML raises REXML::ParseException.
      def initialize(name:, part:, xml:, shared_strings:, style_count: nil)
        @name = name
        @part = part
        @document = REXML::Document.new(xml)
        @shared_strings = shared_strings
        @style_count = style_count
        @cells = nil
        @changed_refs = []
      end

      # Check all required identity/assessment headers on this catalog sheet; malformed schemas raise ValidationError.
      def validate_catalog_schema!
        required = [
          "ADV - ID", "Adventure Title", "Page Count", "Source Book", "Book Publisher",
          "Start Page", "End Page", "Level Start", "Level End", "Scored"
        ]
        required << ">99 pgs" if name == LARGE_SHEET
        missing = required.reject { |header| column_for_header(header) }
        raise ValidationError, "#{name} is missing required headers: #{missing.join(', ')}" unless missing.empty?
      end

      # Return populated ID/row/title/source/publisher records, skipping blank finite slots; malformed IDs raise ValidationError.
      def catalog_records
        id_column = column_for_header("ADV - ID") || "A"
        title_column = column_for_header("Adventure Title") || "B"
        source_column = column_for_header("Source Book") || "E"
        publisher_column = column_for_header("Book Publisher") || "F"
        rows.filter_map do |row|
          row_number = Integer(row.attributes["r"], 10)
          adventure_id = cell_value("#{id_column}#{row_number}").to_s.strip
          next unless ADV_ID_RE.match?(adventure_id)
          {
            "adventure_id" => adventure_id,
            "title" => cell_value("#{title_column}#{row_number}"),
            "source_book" => cell_value("#{source_column}#{row_number}"),
            "publisher" => cell_value("#{publisher_column}#{row_number}"),
            "row" => row_number
          }
        end
      end

      # Returns consecutive preallocated rows after canonical records. An empty
      # large sheet reserves row 2 for its count. Occupied/missing rows raise
      # ValidationError; allocation never scans ahead for a convenient blank.
      def next_available_rows(count)
        return [] if count.zero?
        last = catalog_records.map { |row| row.fetch("row") }.max || (name == LARGE_SHEET ? 2 : 1)
        (1..count).map do |offset|
          row_number = last + offset
          row = row_element(row_number)
          raise ValidationError, "#{name} has insufficient preallocated blank rows; missing row #{row_number}" unless row
          nonblank = REXML::XPath.match(row, "./s:c", NS).reject { |cell| blank_cell?(cell) && cell_formula(cell).nil? }
          unless nonblank.empty?
            refs = nonblank.map { |cell| cell.attributes["r"] }.join(", ")
            raise ValidationError, "#{name} preallocated target row #{row_number} is not blank: #{refs}"
          end
          row_number
        end
      end

      # Fill one preallocated admitted record and derive page/scored/large caches; occupied targets or missing headers raise ValidationError.
      def write_catalog_record!(row_number:, adventure_id:, title:, source_id:, publisher:, start_page:, end_page:, levels:)
        template_row = catalog_records.map { |row| row.fetch("row") }.max
        verify_assessment_targets_blank!(row_number)
        before = @changed_refs.length
        write_text_by_header!("ADV - ID", row_number, adventure_id, template_row:)
        write_text_by_header!("Adventure Title", row_number, title, template_row:)
        write_text_by_header!("Source Book", row_number, source_id, template_row:)
        write_text_by_header!("Book Publisher", row_number, publisher, template_row:)
        write_number_by_header!("Start Page", row_number, start_page, template_row:)
        write_number_by_header!("End Page", row_number, end_page, template_row:)

        page_count = end_page - start_page + 1
        start_col = column_for_header("Start Page")
        end_col = column_for_header("End Page")
        write_formula_by_header!("Page Count", row_number, "1+#{end_col}#{row_number}-#{start_col}#{row_number}", page_count, template_row:)

        first_assessment = column_for_header("Number of Sessions")
        last_assessment = column_for_header("Seriousness")
        scored = levels ? 2 : 0
        write_formula_by_header!("Scored", row_number, "COUNT(#{first_assessment}#{row_number}:#{last_assessment}#{row_number})", scored, template_row:)
        if column_for_header(">99 pgs")
          page_count_col = column_for_header("Page Count")
          write_formula_by_header!(">99 pgs", row_number, "IF(#{page_count_col}#{row_number}>99,1,0)", page_count >= LARGE_THRESHOLD ? 1 : 0, template_row:)
        end
        if column_for_header("First 100")
          id_col = column_for_header("ADV - ID")
          write_formula_by_header!("First 100", row_number, "IF(COUNTIF(AI:AI,#{id_col}#{row_number})>0,1,0)", 0, template_row:)
        end

        if levels
          write_number_by_header!("Level Start", row_number, levels.fetch("start"), template_row:)
          write_number_by_header!("Level End", row_number, levels.fetch("end"), template_row:)
        end
        @changed_refs[before..] || []
      end

      # Refresh the reserved large summary formula/cache from actual records and return its changed references.
      def refresh_large_count!
        return unless name == LARGE_SHEET
        count = catalog_records.length
        formula = cell_formula(cell("B2")) || "COUNTA(A3:A1000)"
        set_formula!("B2", formula, count)
      end

      # Insert/update source and publisher summaries from actual catalog rows and return their positions/counts; capacity/identity/style conflicts refuse.
      def refresh_current_books!(ordinary:, large:, source_id:, publisher:,
                                 large_sheet_mirrors_ordinary:)
        raise ValidationError, "expected #{BOOKS_SHEET.inspect}, got #{name.inspect}" unless name == BOOKS_SHEET

        source_special = unique_row_with_value!("C", SPECIAL_LARGE_LABEL)
        publisher_special = unique_row_with_value!("H", SPECIAL_LARGE_LABEL)

        source_rows = rows_with_nonblank("C")
        source_matches = rows_with_value("C", source_id)
        raise ValidationError, "Current Books contains duplicate source identity #{source_id.inspect}" if source_matches.length > 1
        source_added = source_matches.empty?
        source_row = source_matches.first
        if source_added
          source_row = source_rows.max + 1
          ensure_row_blank_for!(source_row, %w[A B C D E])
          template = source_rows.reject { |row| row == source_special }.max
          template ||= blank_style_template!(source_row, %w[A B C D E])
          set_text!("C#{source_row}", source_id, template_reference: "C#{template}")
          set_text!("D#{source_row}", publisher, template_reference: "D#{template}")
          set_formula!("A#{source_row}", "IF($B$2=0,0,B#{source_row}/$B$2)", 0.0, template_reference: "A#{template}")
          set_formula!("B#{source_row}", "COUNTIF('Adventure Catalog'!E:E,C#{source_row})", 0, template_reference: "B#{template}")
          set_formula!("E#{source_row}", "$B$2", 0, template_reference: "E#{template}")
        else
          existing = cell_value("D#{source_row}")
          raise ValidationError, "Current Books publisher mismatch for #{source_id.inspect}: #{existing.inspect}" unless existing == publisher
        end

        publisher_rows = rows_with_nonblank("H")
        publisher_matches = rows_with_value("H", publisher)
        raise ValidationError, "Current Books contains duplicate publisher #{publisher.inspect}" if publisher_matches.length > 1
        publisher_added = publisher_matches.empty?
        publisher_row = publisher_matches.first
        if publisher_added
          publisher_row = publisher_rows.max + 1
          ensure_row_blank_for!(publisher_row, %w[F G H I])
          template = publisher_rows.reject { |row| row == publisher_special }.max
          template ||= blank_style_template!(publisher_row, %w[F G H I])
          set_text!("H#{publisher_row}", publisher, template_reference: "H#{template}")
          set_formula!("F#{publisher_row}", "IF($G$2=0,0,G#{publisher_row}/$G$2)", 0.0, template_reference: "F#{template}")
          set_formula!("G#{publisher_row}", "COUNTIF('Adventure Catalog'!F:F,H#{publisher_row})", 0, template_reference: "G#{template}")
          set_formula!("I#{publisher_row}", "$G$2", 0, template_reference: "I#{template}")
        end

        ordinary_count = ordinary.catalog_records.length
        large_count = if large_sheet_mirrors_ordinary
                        ordinary.count_catalog_pages_at_least(LARGE_THRESHOLD)
                      else
                        large.catalog_records.length
                      end
        total = large_sheet_mirrors_ordinary ? ordinary_count : ordinary_count + large_count
        page_count_column = ordinary.column_for_header("Page Count")
        large_count_formula = if large_sheet_mirrors_ordinary
                                "COUNTIF('Adventure Catalog'!#{page_count_column}:#{page_count_column},\">=#{LARGE_THRESHOLD}\")"
                              else
                                "'AMC >100pg'!B2"
                              end

        source_rows = rows_with_nonblank("C")
        source_rows.each do |row|
          label = cell_value("C#{row}")
          count = label == SPECIAL_LARGE_LABEL ? large_count : ordinary.count_catalog_by("Source Book", label)
          formula = label == SPECIAL_LARGE_LABEL ? large_count_formula : "COUNTIF('Adventure Catalog'!E:E,C#{row})"
          set_formula!("A#{row}", cell_formula(cell("A#{row}")) || "B#{row}/$B$2", total.zero? ? 0.0 : count.fdiv(total))
          set_formula!("B#{row}", formula, count)
          set_formula!("E#{row}", "$B$2", total)
        end
        a2_formula = if large_sheet_mirrors_ordinary
                       "SUM(A3:A#{source_rows.max})-A#{source_special}"
                     else
                       cell_formula(cell("A2")) || "SUM(A3:A126)"
                     end
        set_formula!("A2", a2_formula, total.zero? ? 0.0 : 1.0)
        b2_formula = if large_sheet_mirrors_ordinary
                       "SUM(B3:B#{source_rows.max})-B#{source_special}"
                     elsif source_added
                       "SUM(B3:B#{source_rows.max})"
                     else
                       cell_formula(cell("B2")) || "SUM(B3:B#{source_rows.max})"
                     end
        c2_formula = if large_sheet_mirrors_ordinary
                       "COUNTA(C3:C#{source_rows.max})-COUNTIF(C3:C#{source_rows.max},\"#{SPECIAL_LARGE_LABEL}\")"
                     elsif source_added
                       "COUNTA(C5:C#{source_rows.max})"
                     else
                       cell_formula(cell("C2")) || "COUNTA(C5:C#{source_rows.max})"
                     end
        set_formula!("B2", b2_formula, total)
        set_formula!("C2", c2_formula, source_rows.count { |row| row != source_special })

        publisher_rows = rows_with_nonblank("H")
        publisher_rows.each do |row|
          label = cell_value("H#{row}")
          count = label == SPECIAL_LARGE_LABEL ? large_count : ordinary.count_catalog_by("Book Publisher", label)
          formula = label == SPECIAL_LARGE_LABEL ? large_count_formula : "COUNTIF('Adventure Catalog'!F:F,H#{row})"
          set_formula!("F#{row}", cell_formula(cell("F#{row}")) || "G#{row}/$G$2", total.zero? ? 0.0 : count.fdiv(total))
          set_formula!("G#{row}", formula, count)
          set_formula!("I#{row}", "$G$2", total)
        end
        f2_formula = if large_sheet_mirrors_ordinary
                       "SUM(F3:F#{publisher_rows.max})-F#{publisher_special}"
                     else
                       cell_formula(cell("F2")) || "SUM(F3:F1000)"
                     end
        set_formula!("F2", f2_formula, total.zero? ? 0.0 : 1.0)
        g2_formula = if large_sheet_mirrors_ordinary
                       "SUM(G3:G#{publisher_rows.max})-G#{publisher_special}"
                     else
                       cell_formula(cell("G2")) || "SUM(G3:G1000)"
                     end
        set_formula!("G2", g2_formula, total)
        h2_formula = if large_sheet_mirrors_ordinary
                       "COUNTA(H3:H#{publisher_rows.max})-COUNTIF(H3:H#{publisher_rows.max},\"#{SPECIAL_LARGE_LABEL}\")"
                     elsif publisher_added
                       "COUNTA(H3:H#{publisher_rows.max})-COUNTIF(H3:H#{publisher_rows.max},\"#{SPECIAL_LARGE_LABEL}\")"
                     else
                       cell_formula(cell("H2")) || "COUNTA(H3:H#{publisher_rows.max})"
                     end
        set_formula!("H2", h2_formula, publisher_rows.count { |row| row != publisher_special })

        {
          "source_row" => source_row,
          "source_added" => source_added,
          "publisher_row" => publisher_row,
          "publisher_added" => publisher_added,
          "canonical_adventure_count" => total,
          "large_adventure_count" => large_count
        }
      end

      # Return the actual catalog record count for an explicit header/value pair; ambiguous headers raise ValidationError.
      def count_catalog_by(header, value)
        column = column_for_header(header)
        catalog_records.count { |record| cell_value("#{column}#{record.fetch('row')}") == value }
      end

      # Return the actual catalog count meeting a numeric page threshold; missing schema raises ValidationError.
      def count_catalog_pages_at_least(threshold)
        page_count_column = column_for_header("Page Count")
        catalog_records.count do |record|
          value = cell_value("#{page_count_column}#{record.fetch('row')}")
          value.is_a?(Numeric) && value >= threshold
        end
      end

      # Return row numbers whose explicit column equals the selected scalar; no blank capacity is populated.
      def rows_with_value(column, value)
        rows.filter_map do |row|
          row_number = Integer(row.attributes["r"], 10)
          row_number if cell_value("#{column}#{row_number}") == value
        end
      end

      # Return row numbers with nonblank text identities in the explicit column.
      def rows_with_nonblank(column)
        rows.filter_map do |row|
          row_number = Integer(row.attributes["r"], 10)
          value = cell_value("#{column}#{row_number}")
          row_number if value.is_a?(String) && !value.strip.empty?
        end
      end

      # Return a unique column or nil for an absent header; duplicate headers raise ValidationError.
      def column_for_header(header)
        columns = header_map.fetch(header, [])
        raise ValidationError, "ambiguous header #{header.inspect} in #{name}" if columns.length > 1
        columns.first
      end

      # Return the XML cell at the explicit reference or nil when absent; malformed XML is not repaired.
      def cell(reference)
        cells[reference]
      end

      # Return the decoded scalar at an explicit reference or nil for an absent cell.
      def cell_value(reference)
        value(cell(reference))
      end

      # Return whether a cell has no value or formula; zero, -1 and nonblank text are preserved.
      def blank_cell?(cell)
        return true unless cell
        return false if cell_formula(cell)
        current = value(cell)
        current.nil? || current.to_s.empty?
      end

      # Return the cell formula text or nil; formula caches do not substitute for formulas.
      def cell_formula(cell)
        cell && REXML::XPath.first(cell, "./s:f", NS)&.text
      end

      # Return actual cell references; absent capacity is not invented.
      def cell_references
        cells.keys
      end

      # Return per-reference canonical cell snapshots for exact mutation comparison; no workbook bytes are written.
      def cell_snapshots
        cells.transform_values { |cell| AmcApply.canonical_element(cell) }
      end

      # Return worksheet XML structure with cells removed, for detecting changes outside allowed cells.
      def structure_signature
        copy = REXML::Document.new(to_xml)
        REXML::XPath.match(copy, "//s:sheetData/s:row/s:c", NS).each { |item| item.parent.delete_element(item) }
        AmcApply.canonical_element(copy.root)
      end

      # Serialize the current in-memory XML document; no destination is opened and formatter errors propagate.
      def to_xml
        AmcApply.serialize_xml(@document)
      end

      private

      # Refuse nonblank/formula assessment targets at the selected row before any in-memory record write.
      def verify_assessment_targets_blank!(row_number)
        ASSESSMENT_HEADERS.each do |header|
          column = column_for_header(header)
          next unless column
          reference = "#{column}#{row_number}"
          cell = self.cell(reference)
          next if blank_cell?(cell) && cell_formula(cell).nil?
          raise ValidationError, "#{name}!#{reference} target assessment field #{header.inspect} is not blank"
        end
      end

      # Return the sole matching summary row; absent or duplicate identities raise ValidationError.
      def unique_row_with_value!(column, value)
        matches = rows_with_value(column, value)
        raise ValidationError, "#{name} must contain exactly one #{value.inspect} row in column #{column} (found #{matches.length})" unless matches.one?
        matches.first
      end

      # Require real preallocated blank target cells/row; conflicts or exhausted explicit slots raise ValidationError.
      def ensure_row_blank_for!(row_number, columns)
        row = row_element(row_number)
        raise ValidationError, "#{name} has insufficient preallocated rows; missing row #{row_number}" unless row
        # Explicit styled slots declare each side's finite capacity. Legacy
        # populated layouts may instead preallocate whole empty rows.
        explicit_slots = columns.all? { |column| cell("#{column}5")&.attributes&.[]("s") }
        if explicit_slots && columns.any? { |column| !cell("#{column}#{row_number}") }
          raise ValidationError, "#{name} has insufficient preallocated cells at row #{row_number}"
        end
        conflicts = columns.filter_map do |column|
          reference = "#{column}#{row_number}"
          reference unless blank_cell?(cell(reference)) && cell_formula(cell(reference)).nil?
        end
        raise ValidationError, "#{name} target row #{row_number} is not blank in #{conflicts.join(', ')}" unless conflicts.empty?
      end

      # Returns the first insertion row as its own style template, only when
      # every target cell is explicitly blank and names a valid cellXfs index.
      # Preserves the declared number/base styles; missing declarations raise
      # ValidationError rather than borrowing the special large-summary style.
      def blank_style_template!(row_number, columns)
        columns.each do |column|
          reference = "#{column}#{row_number}"
          target = cell(reference)
          style = target&.attributes&.[]("s")
          unless target && blank_cell?(target) && style&.match?(/\A\d+\z/) && @style_count && style.to_i < @style_count
            raise ValidationError, "#{name}!#{reference} requires an explicitly styled blank first-insertion template"
          end
        end
        row_number
      end

      # Write admitted text using the selected header and template row; missing columns/rows raise ValidationError.
      def write_text_by_header!(header, row, value, template_row:)
        column = required_column!(header)
        set_text!("#{column}#{row}", value, template_reference: "#{column}#{template_row}")
      end

      # Write an admitted numeric field using the selected header/template; missing columns/rows raise ValidationError.
      def write_number_by_header!(header, row, value, template_row:)
        column = required_column!(header)
        set_number!("#{column}#{row}", value, template_reference: "#{column}#{template_row}")
      end

      # Write an exact derived formula/cache using the selected header/template; missing capacity/schema raises ValidationError.
      def write_formula_by_header!(header, row, formula, cache, template_row:)
        column = required_column!(header)
        set_formula!("#{column}#{row}", formula, cache, template_reference: "#{column}#{template_row}")
      end

      # Return the uniquely required header column or raise ValidationError when absent/ambiguous.
      def required_column!(header)
        column_for_header(header) || raise(ValidationError, "missing header #{header.inspect} in #{name}")
      end

      # Replace one in-memory cell payload with text and preserve template formatting; invalid/missing capacity raises ValidationError.
      def set_text!(reference, text, template_reference: nil)
        mutate_cell!(reference, template_reference:) do |cell|
          clear_payload!(cell)
          cell.attributes["t"] = "str"
          add_child!(cell, "v", text.to_s)
        end
      end

      # Replace one in-memory cell payload with its admitted number and preserve formatting; invalid/missing capacity raises ValidationError.
      def set_number!(reference, number, template_reference: nil)
        mutate_cell!(reference, template_reference:) do |cell|
          clear_payload!(cell)
          cell.attributes["t"] = "n"
          add_child!(cell, "v", number.to_s)
        end
      end

      # Set exact formula/cache in memory while preserving cell formatting; invalid/missing capacity raises ValidationError.
      def set_formula!(reference, formula, cache, template_reference: nil)
        mutate_cell!(reference, template_reference:) do |cell|
          cell.delete_attribute("t")
          cell.elements.to_a.each { |child| cell.delete_element(child) if %w[is v].include?(child.name) }
          formula_element = REXML::XPath.first(cell, "./s:f", NS)
          unless formula_element
            formula_element = prefixed_element(cell, "f")
            first = cell.elements[1]
            first ? cell.insert_before(first, formula_element) : cell.add_element(formula_element)
          end
          formula_element.text = formula
          value_element = prefixed_element(cell, "v")
          value_element.text = cache.to_s
          cell.add_element(value_element)
        end
      end

      # Yield an existing/preallocated target for mutation and track its canonical before/after change; invalid references raise ValidationError.
      def mutate_cell!(reference, template_reference: nil)
        before = cell(reference) && AmcApply.canonical_element(cell(reference))
        target = ensure_cell!(reference, template_reference:)
        yield target
        after = AmcApply.canonical_element(target)
        @changed_refs << reference if before != after && !@changed_refs.include?(reference)
        target
      end

      # Return or create a cell only in an existing row using the declared template; missing rows raise ValidationError.
      def ensure_cell!(reference, template_reference: nil)
        return cell(reference) if cell(reference)
        _column, row_number = AmcApply.reference_parts(reference)
        row = row_element(row_number)
        raise ValidationError, "worksheet row missing for #{name}!#{reference}" unless row

        template = template_reference && cell(template_reference)
        target = if template
                   clone = template.deep_clone
                   clone.elements.to_a.each { |child| clone.delete_element(child) }
                   clone.delete_attribute("t")
                   clone
                 else
                   prefixed_element(row, "c")
                 end
        target.attributes["r"] = reference
        insert_cell_sorted!(row, target)
        cells[reference] = target
        target
      end

      # Insert the supplied cell into an existing row in column order; no extra row capacity is created.
      def insert_cell_sorted!(row, target)
        target_column, = AmcApply.reference_parts(target.attributes["r"])
        following = REXML::XPath.match(row, "./s:c", NS).find do |candidate|
          candidate_column, = AmcApply.reference_parts(candidate.attributes["r"])
          AmcApply.column_number(candidate_column) > AmcApply.column_number(target_column)
        end
        following ? row.insert_before(following, target) : row.add_element(target)
      end

      # Remove value/formula/inline-string children before an authorized scalar write; formatting is preserved.
      def clear_payload!(cell)
        cell.elements.to_a.each { |child| cell.delete_element(child) if %w[f v is].include?(child.name) }
      end

      # Append a correctly prefixed XML value child and return it; no workbook publication occurs.
      def add_child!(cell, name, text)
        child = prefixed_element(cell, name)
        child.text = text
        cell.add_element(child)
      end

      # Return a new XML element with its parent prefix; no namespace/schema change is inferred.
      def prefixed_element(parent, local_name)
        prefix = parent.prefix
        REXML::Element.new(prefix && !prefix.empty? ? "#{prefix}:#{local_name}" : local_name)
      end

      # Return header text mapped to actual row-1 columns; malformed references raise ValidationError.
      def header_map
        return @header_map if @header_map
        first_row = row_element(1)
        raise ValidationError, "#{name} is missing row 1 headers" unless first_row
        @header_map = Hash.new { |hash, key| hash[key] = [] }
        REXML::XPath.each(first_row, "./s:c", NS) do |header_cell|
          text = value(header_cell)
          next if text.nil? || text.to_s.empty?
          column, = AmcApply.reference_parts(header_cell.attributes["r"])
          @header_map[text.to_s] << column
        end
        @header_map
      end

      # Return worksheet row XML elements in document order; no implicit capacity is created.
      def rows
        @rows ||= REXML::XPath.match(@document, "//s:sheetData/s:row", NS)
      end

      # Return the XML row for the explicit row number, or nil if preallocated capacity is absent.
      def row_element(row_number)
        rows.find { |row| Integer(row.attributes["r"], 10) == row_number }
      end

      # Return the worksheet reference-to-element index; duplicate references raise ValidationError where required by this parser.
      def cells
        return @cells if @cells
        elements = REXML::XPath.match(@document, "//s:sheetData/s:row/s:c", NS)
        references = elements.map { |item| item.attributes["r"] }
        duplicates = references.tally.select { |_reference, count| count > 1 }.keys
        raise ValidationError, "duplicate worksheet cell references in #{name}: #{duplicates.join(', ')}" unless duplicates.empty?
        @cells = elements.to_h { |item| [item.attributes["r"], item] }
      end

      # Return the raw v-element text or nil; shared/inline string decoding is handled separately.
      def raw_value(cell)
        cell && REXML::XPath.first(cell, "./s:v", NS)&.text
      end

      # Return the decoded string/numeric/blank scalar from a cell; malformed numeric text remains distinct from blank.
      def value(cell)
        return nil unless cell
        type = cell.attributes["t"]
        if type == "s"
          index = raw_value(cell)
          index ? @shared_strings[Integer(index, 10)] : nil
        elsif type == "inlineStr"
          REXML::XPath.match(cell, ".//s:is//s:t", NS).map { |text| text.text.to_s }.join
        elsif type == "str"
          raw_value(cell)
        elsif type.nil? || type == "n"
          AmcApply.parse_number(raw_value(cell)) || raw_value(cell)
        else
          raw_value(cell)
        end
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
