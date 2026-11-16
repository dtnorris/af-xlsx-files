# frozen_string_literal: true

require "digest"
require "pathname"
require "rexml/document"
require "rexml/xpath"
require "set"
require "zip"
require_relative "error"
require_relative "amc_apply"
require_relative "boundary_freeze_apply"

module AfXlsxFiles
  # Read-only preflight for pipeline AMC integrity and static scoring-catalog
  # column requirements. This deliberately does not
  # promote matcher_authorized_baseline; matcher promotion remains independent.
  class AmcCompatibilityCheck
    REPORT_SCHEMA = "af-amc-cross-consumer-compatibility/v0.1"
    ADV_ID_RE = /\AADV-\d{4,}\z/
    SPECIAL_LARGE_LABEL = BoundaryFreezeApply::SPECIAL_LARGE_LABEL

    REQUIRED_IDENTITY_HEADERS = [
      "ADV - ID", "Adventure Title", "Page Count", "Source Book", "Book Publisher",
      "Start Page", "End Page", "Level Start", "Level End", "Scored"
    ].freeze

    # Existing required AMC assessment columns. This shape is a static pipeline
    # compatibility requirement, not an orchestration qualification contract.
    # Deferred dimensions remain optional, but if present
    # they participate in blank-field validation for newly introduced IDs.
    REQUIRED_SCORE_HEADERS = [
      "Number of Sessions",
      "Exploration Emphasis",
      "GM Preparation Burden",
      "Combat Emphasis",
      "Social Interaction Emphasis",
      "Investigation Emphasis",
      "Structural Openness",
      "Darkness / Horror Intensity",
      "Player Beginner Suitability",
      "GM Beginner Suitability",
      "Seriousness"
    ].freeze

    # Historical API alias only; AFIO is retired and is not a validated consumer.
    AFIO_SCORE_HEADERS = REQUIRED_SCORE_HEADERS

    DEFERRED_SCORE_HEADERS = [
      "Rules / System-Master Demand",
      "Tactical Complexity",
      "Lethality / Failure Severity",
      "Puzzle / Problem-Solving Emphasis",
      "Consequential Player Agency",
      "Fantastic Weirdness",
      "GM Improvisation Demand"
    ].freeze

    MIRROR_VALUE_HEADERS = [
      "Adventure Title", "Page Count", "Source Book", "Book Publisher",
      "Start Page", "End Page", "Level Start", "Level End"
    ].freeze

    # Inspect explicit candidate/base workbooks and return the structural report; malformed XLSX is reported as FAIL.
    def self.check(candidate_path:, base_path: nil)
      new(candidate_path:, base_path:).check
    end

    # Return a valid structural report or true for the bound state; invalid representation raises the owner error.
    def self.validate!(candidate_path:, base_path: nil)
      report = check(candidate_path:, base_path:)
      return report if report.fetch("status") == "PASS"

      detail = report.fetch("errors").map { |error| "- #{error}" }.join("\n")
      raise ValidationError, "AMC cross-consumer compatibility failed:\n#{detail}"
    end

    # Bind explicit representation inputs and initialize parsed/cached state; returns an instance, propagating XML/ZIP/I/O/validation errors when parsing occurs.
    def initialize(candidate_path:, base_path: nil)
      @candidate_path = File.expand_path(candidate_path)
      @base_path = base_path && File.expand_path(base_path)
    end

    # Inspect explicit candidate/base workbooks and return the structural report; malformed XLSX is reported as FAIL.
    def check
      errors = []
      unless File.file?(@candidate_path)
        return report(errors: ["candidate workbook does not exist: #{@candidate_path}"])
      end
      if @base_path && !File.file?(@base_path)
        return report(errors: ["comparison workbook does not exist: #{@base_path}"])
      end
      scored_authorization = nil

      workbook = BoundaryFreezeApply::Workbook.new(@candidate_path)
      ordinary = fetch_sheet(workbook, BoundaryFreezeApply::ORDINARY_SHEET, errors)
      large = fetch_sheet(workbook, BoundaryFreezeApply::LARGE_SHEET, errors)
      books = fetch_sheet(workbook, BoundaryFreezeApply::BOOKS_SHEET, errors)
      return report(errors:) unless ordinary && large && books

      required_columns = {}
      [ordinary, large].each do |sheet|
        required = REQUIRED_IDENTITY_HEADERS + REQUIRED_SCORE_HEADERS
        required << ">99 pgs" if sheet.name == BoundaryFreezeApply::LARGE_SHEET
        required_columns[sheet.name] = resolve_columns(sheet, required, errors)
      end
      return report(errors:) if errors.any? { |error| error.include?("missing required header") || error.include?("ambiguous header") }

      ordinary_rows = catalog_rows(ordinary, required_columns.fetch(ordinary.name), errors)
      large_rows = catalog_rows(large, required_columns.fetch(large.name), errors)
      ordinary_by_id = unique_index(ordinary.name, ordinary_rows, errors)
      large_by_id = unique_index(large.name, large_rows, errors)

      mirror_mode = mirror_mode(ordinary, large, books, ordinary_by_id, large_by_id, errors)
      candidate_ids = (ordinary_by_id.keys | large_by_id.keys).sort
      base_ids = @base_path ? base_ids(errors) : []
      added_ids = candidate_ids - base_ids

      validate_catalog_rows(ordinary, ordinary_rows, required_columns.fetch(ordinary.name), added_ids, scored_authorization, errors)
      validate_catalog_rows(large, large_rows, required_columns.fetch(large.name), added_ids, scored_authorization, errors)
      validate_added_placement(ordinary, large, ordinary_by_id, large_by_id, added_ids, mirror_mode, errors)
      validate_large_summary(large, large_rows, errors)
      validate_current_books(books, ordinary, large, ordinary_rows, large_rows, mirror_mode, errors)

      report(
        errors:,
        mirror_mode:,
        canonical_count: candidate_ids.length,
        added_ids:,
        scored_authorization:
      )
    rescue Zip::Error, REXML::ParseException, KeyError, ArgumentError => e
      report(errors: ["candidate XLSX could not be validated: #{e.message}"])
    end

    private

    # Return the existing report mapping from measured artifacts, computed counts and collected errors; no approval is granted.
    def report(errors:, mirror_mode: nil, canonical_count: nil, added_ids: [], scored_authorization: nil)
      {
        "schema_version" => REPORT_SCHEMA,
        "status" => errors.empty? ? "PASS" : "FAIL",
        "candidate" => artifact(@candidate_path),
        "against" => @base_path && artifact(@base_path),
        "consumer_contracts" => [
          "af-data-pipeline boundary/dossier/apply",
          "af-cli-scoring-utility Adventure Catalog column requirements (static)"
        ],
        "afw_execution_compatibility" => "not validated by this static workbook gate",
        "matcher_authorized_baseline" => "not promoted or validated by this gate",
        "mirror_mode" => mirror_mode,
        "canonical_adventure_count" => canonical_count,
        "added_adventure_ids" => added_ids,
        "scored_new_id_authorization" => scored_authorization&.summary,
        "errors" => errors
      }.compact
    end

    # Return path/hash/size for an existing explicit artifact, or its path if absent; filesystem errors propagate.
    def artifact(path)
      return {"path" => path} unless path && File.file?(path)
      {
        "path" => path,
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => File.size(path)
      }
    end

    # Return the uniquely named sheet, or append its validation failure to errors and return nil.
    def fetch_sheet(workbook, name, errors)
      workbook.sheet_by_name!(name)
    rescue ValidationError => e
      errors << e.message
      nil
    end

    # Return the header-to-column map, appending missing or ambiguous header failures to errors.
    def resolve_columns(sheet, headers, errors)
      headers.each_with_object({}) do |header, out|
        column = sheet.column_for_header(header)
        if column
          out[header] = column
        else
          errors << "#{sheet.name}: missing required header #{header.inspect}"
        end
      rescue ValidationError => e
        errors << "#{sheet.name}: ambiguous header #{header.inspect} (#{e.message})"
      end
    end

    # Return sorted unique populated row numbers below the header from the supplied worksheet references.
    def row_numbers(sheet)
      sheet.cell_references.filter_map do |reference|
        _column, row = AmcApply.reference_parts(reference)
        row if row > 1
      end.uniq.sort
    end

    # Return ID/row mappings from explicit columns, collecting malformed ID errors and skipping blank capacity.
    def catalog_rows(sheet, columns, errors)
      id_column = columns.fetch("ADV - ID")
      row_numbers(sheet).filter_map do |row|
        id = sheet.cell_value("#{id_column}#{row}").to_s.strip
        next if id.empty?

        unless ADV_ID_RE.match?(id)
          errors << "#{sheet.name}!#{id_column}#{row}: invalid Adventure ID #{id.inspect}"
          next
        end

        {"adventure_id" => id, "row" => row}
      end
    end

    # Return records indexed by ID and append duplicate-ID diagnostics to errors; rows remain unchanged.
    def unique_index(sheet_name, rows, errors)
      duplicates = rows.group_by { |record| record.fetch("adventure_id") }
                       .select { |_id, matches| matches.length > 1 }
      duplicates.each do |id, matches|
        errors << "#{sheet_name}: duplicate Adventure ID #{id} at rows #{matches.map { |record| record.fetch('row') }.join(', ')}"
      end
      rows.to_h { |record| [record.fetch("adventure_id"), record] }
    end

    # Return unique IDs across both bound base sheets, collecting read/parse/schema errors instead of accepting missing evidence.
    def base_ids(errors)
      workbook = BoundaryFreezeApply::Workbook.new(@base_path)
      ordinary = fetch_sheet(workbook, BoundaryFreezeApply::ORDINARY_SHEET, errors)
      large = fetch_sheet(workbook, BoundaryFreezeApply::LARGE_SHEET, errors)
      return [] unless ordinary && large

      ids = [ordinary, large].flat_map do |sheet|
        id_column = sheet.column_for_header("ADV - ID")
        next [] unless id_column
        row_numbers(sheet).filter_map do |row|
          id = sheet.cell_value("#{id_column}#{row}").to_s.strip
          id if ADV_ID_RE.match?(id)
        end
      end
      ids.uniq
    rescue Zip::Error, REXML::ParseException, ValidationError => e
      errors << "comparison workbook could not be read: #{e.message}"
      []
    end

    # Return split/mirrored/mixed layout from both sheets and summaries, collecting inconsistent identity errors.
    def mirror_mode(ordinary, large, books, ordinary_by_id, large_by_id, errors)
      large_ids = large_by_id.keys
      return empty_large_mode(ordinary, books, errors) if large_ids.empty?

      overlap = large_ids & ordinary_by_id.keys
      mode = if overlap.empty?
               "split"
             elsif overlap.length == large_ids.length
               "mirrored"
             else
               errors << "#{BoundaryFreezeApply::LARGE_SHEET}: mixed mirrored and non-mirrored Adventure IDs"
               "mixed"
             end

      overlap.each do |id|
        left = ordinary_by_id.fetch(id)
        right = large_by_id.fetch(id)
        MIRROR_VALUE_HEADERS.each do |header|
          left_value = value_by_header(ordinary, left.fetch("row"), header)
          right_value = value_by_header(large, right.fetch("row"), header)
          next if left_value == right_value

          errors << "mirrored #{id} differs for #{header}: Adventure Catalog=#{left_value.inspect} AMC >100pg=#{right_value.inspect}"
        end
      end
      mode
    end

    # Return the empty large-sheet layout from exact summary formulas, or mixed with an explanatory error.
    def empty_large_mode(ordinary, books, errors)
      source_rows = books.rows_with_nonblank("C")
      publisher_rows = books.rows_with_nonblank("H")
      source_special = source_rows.find { |row| books.cell_value("C#{row}") == SPECIAL_LARGE_LABEL }
      publisher_special = publisher_rows.find { |row| books.cell_value("H#{row}") == SPECIAL_LARGE_LABEL }
      return "mixed" unless source_special && publisher_special

      formulas = [books.cell_formula(books.cell("B#{source_special}")), books.cell_formula(books.cell("G#{publisher_special}"))]
        .map { |value| normalize_formula(value) }
      split = normalize_formula("'AMC >100pg'!B2")
      page_count_column = ordinary.column_for_header("Page Count")
      mirrored = normalize_formula("COUNTIF('Adventure Catalog'!#{page_count_column}:#{page_count_column},\">=#{BoundaryFreezeApply::LARGE_THRESHOLD}\")")
      return "split" if formulas.all? { |formula| formula == split }
      return "mirrored" if formulas.all? { |formula| formula == mirrored }

      errors << "Current Books cannot prove whether the empty large-adventure sheet is split or mirrored"
      "mixed"
    end

    # Check supplied rows against identity/page/new-row representation requirements; append errors without changing cells.
    def validate_catalog_rows(sheet, rows, columns, added_ids, scored_authorization, errors)
      rows.each do |record|
        id = record.fetch("adventure_id")
        row = record.fetch("row")

        ["Adventure Title", "Source Book", "Book Publisher"].each do |header|
          value = sheet.cell_value("#{columns.fetch(header)}#{row}").to_s.strip
          errors << "#{sheet.name} #{id}: #{header} must be nonblank" if value.empty?
        end

        start_page = integer_value(sheet.cell_value("#{columns.fetch('Start Page')}#{row}"))
        end_page = integer_value(sheet.cell_value("#{columns.fetch('End Page')}#{row}"))
        if !start_page&.positive? || !end_page&.positive? || end_page < start_page
          errors << "#{sheet.name} #{id}: invalid Start Page / End Page"
          next
        end

        expected_pages = end_page - start_page + 1
        page_count = integer_value(sheet.cell_value("#{columns.fetch('Page Count')}#{row}"))
        unless page_count == expected_pages
          errors << "#{sheet.name} #{id}: Page Count cache #{page_count.inspect} does not equal #{expected_pages} from Start/End Page"
        end
        if sheet.name == BoundaryFreezeApply::LARGE_SHEET && expected_pages < BoundaryFreezeApply::LARGE_THRESHOLD
          errors << "#{sheet.name} #{id}: #{expected_pages} pages is below the >=#{BoundaryFreezeApply::LARGE_THRESHOLD}-page threshold"
        end

        next unless added_ids.include?(id)

        validate_new_row_formulas(sheet, row, id, columns, expected_pages, scored_authorization, errors)
        validate_new_row_blank_fields(sheet, row, id, scored_authorization, errors)
      end
    end

    # Check page/scored/large formulas and derived caches for a newly allocated row; append exact representation errors.
    def validate_new_row_formulas(sheet, row, id, columns, expected_pages, scored_authorization, errors)
      start_column = columns.fetch("Start Page")
      end_column = columns.fetch("End Page")
      page_count_column = columns.fetch("Page Count")
      page_cell = sheet.cell("#{page_count_column}#{row}")
      expected_page_formula = "1+#{end_column}#{row}-#{start_column}#{row}"
      unless normalize_formula(sheet.cell_formula(page_cell)) == normalize_formula(expected_page_formula)
        errors << "#{sheet.name} #{id}: new Page Count must use formula #{expected_page_formula}"
      end

      first = sheet.column_for_header("Number of Sessions")
      last = sheet.column_for_header("Seriousness")
      scored_column = columns.fetch("Scored")
      scored_cell = sheet.cell("#{scored_column}#{row}")
      expected_scored_formula = "COUNT(#{first}#{row}:#{last}#{row})"
      unless normalize_formula(sheet.cell_formula(scored_cell)) == normalize_formula(expected_scored_formula)
        errors << "#{sheet.name} #{id}: new Scored must use formula #{expected_scored_formula}"
      end

      expected_scored = headers_between(sheet, row, "Number of Sessions", "Seriousness").count do |value|
        value.is_a?(Numeric)
      end
      actual_scored = integer_value(sheet.cell_value("#{scored_column}#{row}"))
      unless actual_scored == expected_scored
        errors << "#{sheet.name} #{id}: Scored cache #{actual_scored.inspect} does not equal #{expected_scored}"
      end

      return unless sheet.name == BoundaryFreezeApply::LARGE_SHEET

      large_column = columns.fetch(">99 pgs")
      large_cell = sheet.cell("#{large_column}#{row}")
      expected_large_formula = "IF(#{page_count_column}#{row}>99,1,0)"
      unless normalize_formula(sheet.cell_formula(large_cell)) == normalize_formula(expected_large_formula)
        errors << "#{sheet.name} #{id}: >99 pgs must use formula #{expected_large_formula}"
      end
      actual_large = integer_value(sheet.cell_value("#{large_column}#{row}"))
      errors << "#{sheet.name} #{id}: >99 pgs cache must be 1" unless actual_large == 1 && expected_pages >= 100
    end

    # Check new assessment blanks and paired whole-number Levels; append representation errors without authorizing scores.
    def validate_new_row_blank_fields(sheet, row, id, scored_authorization, errors)
      (REQUIRED_SCORE_HEADERS + DEFERRED_SCORE_HEADERS.select { |header| safe_column(sheet, header) }).uniq.each do |header|
        column = safe_column(sheet, header)
        next unless column
        cell = sheet.cell("#{column}#{row}")
        next if sheet.blank_cell?(cell) && sheet.cell_formula(cell).nil?


        errors << "#{sheet.name} #{id}: unassessed production field #{header.inspect} must be blank"
      end

      left = safe_column(sheet, "Level Start")
      right = safe_column(sheet, "Level End")
      start_value = left && sheet.cell_value("#{left}#{row}")
      end_value = right && sheet.cell_value("#{right}#{row}")
      start_blank = blank?(start_value)
      end_blank = blank?(end_value)
      if start_blank != end_blank
        errors << "#{sheet.name} #{id}: Level Start and Level End must both be blank or both populated"
        return
      end
      return if start_blank

      start_level = integer_value(start_value)
      end_level = integer_value(end_value)
      unless start_level && end_level && (1..20).cover?(start_level) && (1..20).cover?(end_level) && end_level >= start_level
        errors << "#{sheet.name} #{id}: populated Levels must be whole numbers 1-20 with Level End >= Level Start"
      end
    end

    # Check each added ID against the declared split/mirrored page threshold; append placement errors.
    def validate_added_placement(ordinary_sheet, large_sheet, ordinary_by_id, large_by_id, added_ids, mirror_mode, errors)
      added_ids.each do |id|
        ordinary_record = ordinary_by_id[id]
        large_record = large_by_id[id]
        record = ordinary_record || large_record
        next unless record

        # Page count has already been checked against Start/End. Use whichever
        # copy exists to determine the canonical size class.
        sheet = ordinary_record ? ordinary_sheet : large_sheet
        page_count = integer_value(value_by_header(sheet, record.fetch("row"), "Page Count"))
        next unless page_count

        if page_count >= BoundaryFreezeApply::LARGE_THRESHOLD
          if mirror_mode == "mirrored" && (!ordinary_record || large_record)
            errors << "new >=#{BoundaryFreezeApply::LARGE_THRESHOLD}-page #{id} must live only in #{BoundaryFreezeApply::ORDINARY_SHEET} when #{BoundaryFreezeApply::LARGE_SHEET} is a legacy mirror"
          elsif mirror_mode == "split" && (ordinary_record || !large_record)
            errors << "new >=#{BoundaryFreezeApply::LARGE_THRESHOLD}-page #{id} must live only in #{BoundaryFreezeApply::LARGE_SHEET} for split layout"
          end
        elsif large_record
          errors << "new <#{BoundaryFreezeApply::LARGE_THRESHOLD}-page #{id} must not appear in #{BoundaryFreezeApply::LARGE_SHEET}"
        elsif !ordinary_record
          errors << "new <#{BoundaryFreezeApply::LARGE_THRESHOLD}-page #{id} must appear in #{BoundaryFreezeApply::ORDINARY_SHEET}"
        end
      end
    end

    # Check reserved large-sheet count formula and actual count cache; append summary errors.
    def validate_large_summary(large, large_rows, errors)
      formula = normalize_formula(large.cell_formula(large.cell("B2")))
      errors << "#{large.name}!B2 must contain a count formula" if formula.empty?
      cached = integer_value(large.cell_value("B2"))
      unless cached == large_rows.length
        errors << "#{large.name}!B2 cached count #{cached.inspect} does not equal #{large_rows.length} large adventures"
      end
    end

    # Check source/publisher summaries against both catalog sheets; append count/formula/cache/identity errors.
    def validate_current_books(books, ordinary, large, ordinary_rows, large_rows, mirror_mode, errors)
      source_rows = books.rows_with_nonblank("C")
      publisher_rows = books.rows_with_nonblank("H")
      source_special = unique_special_row(books, "C", source_rows, errors)
      publisher_special = unique_special_row(books, "H", publisher_rows, errors)
      return unless source_special && publisher_special

      ordinary_ids = ordinary_rows.map { |row| row.fetch("adventure_id") }.to_set
      large_ids = large_rows.map { |row| row.fetch("adventure_id") }.to_set
      canonical_count = (ordinary_ids | large_ids).length

      expected_scalar(books, "B2", canonical_count, errors, "canonical adventure total")
      expected_scalar(books, "G2", canonical_count, errors, "canonical publisher total")
      expected_scalar(books, "C2", source_rows.count { |row| row != source_special }, errors, "source identity count")
      expected_scalar(books, "H2", publisher_rows.count { |row| row != publisher_special }, errors, "publisher identity count")

      live_large_count = if mirror_mode == "mirrored"
                           count_pages_at_least(ordinary, ordinary_rows, BoundaryFreezeApply::LARGE_THRESHOLD)
                         else
                           large_rows.length
                         end
      page_count_column = ordinary.column_for_header("Page Count")
      live_large_formula = if mirror_mode == "mirrored"
                             "COUNTIF('Adventure Catalog'!#{page_count_column}:#{page_count_column},\">=#{BoundaryFreezeApply::LARGE_THRESHOLD}\")"
                           else
                             "'AMC >100pg'!B2"
                           end

      source_rows.each do |row|
        label = books.cell_value("C#{row}")
        expected = label == SPECIAL_LARGE_LABEL ? live_large_count : count_by(ordinary, ordinary_rows, "Source Book", label)
        expected_formula = label == SPECIAL_LARGE_LABEL ? live_large_formula : "COUNTIF('Adventure Catalog'!E:E,C#{row})"
        expected_formula_cell(books, "B#{row}", expected_formula, expected, errors)
        expected_ratio_cell(books, "A#{row}", "B#{row}", "$B$2", expected, canonical_count, errors)
        expected_formula_cell(books, "E#{row}", "$B$2", canonical_count, errors)

        next if label == SPECIAL_LARGE_LABEL
        publisher = books.cell_value("D#{row}").to_s.strip
        errors << "Current Books C#{row}=#{label.inspect} has blank publisher in D#{row}" if publisher.empty?
        catalog_publishers = publishers_for_source(ordinary, large, ordinary_rows, large_rows, label)
        if catalog_publishers.length > 1
          errors << "Current Books source #{label.inspect} has conflicting catalog publishers: #{catalog_publishers.join(', ')}"
        elsif catalog_publishers.one? && catalog_publishers.first != publisher
          errors << "Current Books source #{label.inspect} publisher #{publisher.inspect} does not match catalog #{catalog_publishers.first.inspect}"
        end
      end

      publisher_rows.each do |row|
        label = books.cell_value("H#{row}")
        expected = label == SPECIAL_LARGE_LABEL ? live_large_count : count_by(ordinary, ordinary_rows, "Book Publisher", label)
        expected_formula = label == SPECIAL_LARGE_LABEL ? live_large_formula : "COUNTIF('Adventure Catalog'!F:F,H#{row})"
        expected_formula_cell(books, "G#{row}", expected_formula, expected, errors)
        expected_ratio_cell(books, "F#{row}", "G#{row}", "$G$2", expected, canonical_count, errors)
        expected_formula_cell(books, "I#{row}", "$G$2", canonical_count, errors)
      end

      return unless mirror_mode == "mirrored"

      max_source = source_rows.max
      max_publisher = publisher_rows.max
      expected_formula_cell(books, "B2", "SUM(B3:B#{max_source})-B#{source_special}", canonical_count, errors)
      expected_formula_cell(books, "C2", "COUNTA(C3:C#{max_source})-COUNTIF(C3:C#{max_source},\"#{SPECIAL_LARGE_LABEL}\")", source_rows.count { |row| row != source_special }, errors)
      expected_formula_cell(books, "G2", "SUM(G3:G#{max_publisher})-G#{publisher_special}", canonical_count, errors)
      expected_formula_cell(books, "H2", "COUNTA(H3:H#{max_publisher})-COUNTIF(H3:H#{max_publisher},\"#{SPECIAL_LARGE_LABEL}\")", publisher_rows.count { |row| row != publisher_special }, errors)
    end

    # Return the sole reserved summary row or nil after appending a missing/duplicate summary error.
    def unique_special_row(books, column, rows, errors)
      matches = rows.select { |row| books.cell_value("#{column}#{row}") == SPECIAL_LARGE_LABEL }
      if matches.length != 1
        errors << "Current Books must contain exactly one #{SPECIAL_LARGE_LABEL.inspect} row in column #{column} (found #{matches.length})"
        return nil
      end
      matches.first
    end

    # Return the number of supplied catalog rows with the selected header value; malformed headers raise ValidationError.
    def count_by(sheet, rows, header, value)
      column = sheet.column_for_header(header)
      rows.count { |record| sheet.cell_value("#{column}#{record.fetch('row')}") == value }
    end

    # Return the number of supplied rows meeting the numeric page threshold; malformed headers raise ValidationError.
    def count_pages_at_least(sheet, rows, threshold)
      page_count_column = sheet.column_for_header("Page Count")
      rows.count do |record|
        value = integer_value(sheet.cell_value("#{page_count_column}#{record.fetch('row')}"))
        value && value >= threshold
      end
    end

    # Return distinct publishers for the explicit source across both supplied catalog populations.
    def publishers_for_source(ordinary, large, ordinary_rows, large_rows, source)
      [[ordinary, ordinary_rows], [large, large_rows]].flat_map do |sheet, rows|
        source_column = sheet.column_for_header("Source Book")
        publisher_column = sheet.column_for_header("Book Publisher")
        rows.filter_map do |record|
          row = record.fetch("row")
          next unless sheet.cell_value("#{source_column}#{row}") == source
          value = sheet.cell_value("#{publisher_column}#{row}").to_s.strip
          value unless value.empty?
        end
      end.uniq
    end

    # Compare an actual cell scalar with its expected value and append a labeled mismatch; no writes occur.
    def expected_scalar(sheet, reference, expected, errors, label)
      actual = integer_value(sheet.cell_value(reference))
      errors << "#{sheet.name}!#{reference} #{label} #{actual.inspect} does not equal #{expected}" unless actual == expected
    end

    # Checks a ratio's exact formula and numeric cache from actual record counts.
    # Empty catalogs require the zero guard; populated legacy ratios remain
    # valid. Appends errors rather than evaluating arbitrary spreadsheet code.
    def expected_ratio_cell(sheet, reference, numerator, denominator, count, total, errors)
      guarded = "IF(#{denominator}=0,0,#{numerator}/#{denominator})"
      formula = normalize_formula(sheet.cell_formula(sheet.cell(reference)))
      expected = total.zero? || formula == normalize_formula(guarded) ? guarded : "#{numerator}/#{denominator}"
      cache = total.zero? ? 0.0 : count.fdiv(total)
      expected_formula_cell(sheet, reference, expected, cache, errors, numeric: true)
    end

    # Check a cell against the selected formula/cache, appending exact or numeric mismatch diagnostics.
    def expected_formula_cell(sheet, reference, expected_formula, expected_cache, errors, numeric: false)
      cell = sheet.cell(reference)
      actual_formula = normalize_formula(sheet.cell_formula(cell))
      unless actual_formula == normalize_formula(expected_formula)
        errors << "#{sheet.name}!#{reference} formula #{actual_formula.inspect} does not equal #{expected_formula.inspect}"
      end
      actual = sheet.cell_value(reference)
      cache_matches = if numeric
                        actual.is_a?(Numeric) && (actual.to_f - expected_cache.to_f).abs < 1e-9
                      else
                        integer_value(actual) == integer_value(expected_cache)
                      end
      errors << "#{sheet.name}!#{reference} cached value #{actual.inspect} does not equal #{expected_cache.inspect}" unless cache_matches
    end

    # Return the supplied row values between the two required headers; missing headers raise ValidationError.
    def headers_between(sheet, row, first_header, last_header)
      first = sheet.column_for_header(first_header)
      last = sheet.column_for_header(last_header)
      first_number = AmcApply.column_number(first)
      last_number = AmcApply.column_number(last)
      (first_number..last_number).map do |number|
        column = column_letters(number)
        sheet.cell_value("#{column}#{row}")
      end
    end

    # Return Excel column letters for a positive numeric column position; no workbook is accessed.
    def column_letters(number)
      value = number
      letters = +""
      while value.positive?
        value -= 1
        letters.prepend((65 + (value % 26)).chr)
        value /= 26
      end
      letters
    end

    # Return the selected row/header scalar, or nil for an absent column; ambiguous headers raise ValidationError.
    def value_by_header(sheet, row, header)
      column = safe_column(sheet, header)
      column && sheet.cell_value("#{column}#{row}")
    end

    # Return a unique header column or nil if missing/ambiguous, for optional representation checks.
    def safe_column(sheet, header)
      sheet.column_for_header(header)
    rescue ValidationError
      nil
    end

    # Return formula text normalized for structural comparison; nil becomes an empty string.
    def normalize_formula(value)
      value.to_s.gsub(/\s+/, "").sub(/\A=/, "")
    end

    # Return an exact whole-number value or nil when the scalar is not a valid integer representation.
    def integer_value(value)
      case value
      when Integer then value
      when Float then value.finite? && value == value.to_i ? value.to_i : nil
      when String
        stripped = value.strip
        stripped.match?(/\A-?\d+\z/) ? stripped.to_i : nil
      end
    end

    # Return whether the supplied scalar is nil or empty text; numeric zero and negative sentinels stay distinct.
    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
