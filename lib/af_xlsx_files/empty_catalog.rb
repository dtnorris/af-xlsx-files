# frozen_string_literal: true

require "cgi"

module AfXlsxFiles
  # Builds the finite zero-record split representation from public mechanics.
  # No template workbook, test helper, catalog store or Git baseline is loaded.
  class EmptyCatalog
    HEADERS = [
      "ADV - ID", "Adventure Title", "Played", "Page Count", "Source Book", "Book Publisher",
      "Start Page", "End Page", "Number of Sessions", "Level Start", "Level End",
      "Combat Emphasis", "Social Interaction Emphasis", "Exploration Emphasis", "Investigation Emphasis",
      "Structural Openness", "Darkness / Horror Intensity", "Player Beginner Suitability",
      "GM Beginner Suitability", "GM Preparation Burden", "Seriousness",
      "Rules / System-Master Demand", "Tactical Complexity", "Lethality / Failure Severity",
      "Puzzle / Problem-Solving Emphasis", "Consequential Player Agency", "Fantastic Weirdness",
      "GM Improvisation Demand", "Scored"
    ].freeze

    # Publish one canonical versioned workbook with explicitly finite capacities.
    # Returns its absolute path; invalid identity/capacity/unsafe output or a
    # conflict raises ValidationError before publication. Filesystem errors propagate.
    def self.create!(path:, version:, ordinary_capacity:, large_capacity:, source_capacity:, publisher_capacity:)
      new(path:, version:, ordinary_capacity:, large_capacity:, source_capacity:, publisher_capacity:).create!
    end

    # Store explicit caller inputs without I/O; validation occurs before writing.
    def initialize(path:, version:, ordinary_capacity:, large_capacity:, source_capacity:, publisher_capacity:)
      @path = File.expand_path(path)
      @version = version
      @capacities = [ordinary_capacity, large_capacity, source_capacity, publisher_capacity]
    end

    # Validate, build and independently inspect a temporary package, then publish
    # exclusively. Returns path; conflicts refuse and temporary files are removed.
    def create!
      unless @version.is_a?(String) && /\A\d+(?:\.\d+)+\z/.match?(@version) &&
             File.basename(@path) == "5e_Adventure_Master_Catalog_#{@version}.xlsx"
        raise ValidationError, "empty catalog path must use the canonical selected version"
      end
      # The accepted fixed large-count formula ends at row 1000. Bound all
      # allocation ranges within that envelope rather than silently extending it.
      unless @capacities.zip([999, 998, 996, 996]).all? { |count, limit| count.is_a?(Integer) && count.positive? && count <= limit }
        raise ValidationError, "capacities must be positive integers within ordinary/large/source/publisher limits 999/998/996/996"
      end
      parent = File.dirname(@path)
      unless File.directory?(parent) && File.realpath(parent) == parent && !File.symlink?(@path)
        raise ValidationError, "empty catalog destination must have an existing real directory without symlink ancestors"
      end
      raise ValidationError, "empty catalog destination already exists: #{@path}" if File.exist?(@path)

      Tempfile.create([".empty-catalog-", ".xlsx"], parent) do |temporary|
        temporary.close
        File.unlink(temporary.path)
        Zip::File.open(temporary.path, create: true) do |zip|
          parts.each { |name, content| zip.get_output_stream(name) { |stream| stream.write(content) } }
          zip.each { |entry| entry.time = Time.local(2026, 1, 1) }
        end
        AmcCompatibilityCheck.validate!(candidate_path: temporary.path)
        File.chmod(0o600, temporary.path)
        File.link(temporary.path, @path)
      ensure
        File.unlink(temporary.path) if File.exist?(temporary.path)
      end
      @path
    rescue Errno::EEXIST
      raise ValidationError, "empty catalog destination already exists: #{@path}"
    end

    private

    # Return the complete mechanical package. All formula caches are derived
    # from zero records; blank slots contain no fabricated identities or scores.
    def parts
      ordinary, large, sources, publishers = @capacities
      names = ["Adventure Catalog", "AMC >100pg", "Current Books"]
      types = names.each_index.map do |index|
        %(<Override PartName="/xl/worksheets/sheet#{index + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
      end.join
      relationships = names.each_index.map do |index|
        %(<Relationship Id="rId#{index + 1}" Type="#{AmcApply::OFFICE_REL_NS}/worksheet" Target="worksheets/sheet#{index + 1}.xml"/>)
      end.join
      sheets = names.each_with_index.map { |name, index| %(<sheet name="#{CGI.escapeHTML(name)}" sheetId="#{index + 1}" r:id="rId#{index + 1}"/>) }.join
      {
        "[Content_Types].xml" => %(<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>#{types}<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>),
        "_rels/.rels" => %(<Relationships xmlns="#{AmcApply::PACKAGE_REL_NS}"><Relationship Id="rId1" Type="#{AmcApply::OFFICE_REL_NS}/officeDocument" Target="xl/workbook.xml"/></Relationships>),
        "xl/workbook.xml" => %(<workbook xmlns="#{AmcApply::MAIN_NS}" xmlns:r="#{AmcApply::OFFICE_REL_NS}"><sheets>#{sheets}</sheets></workbook>),
        "xl/_rels/workbook.xml.rels" => %(<Relationships xmlns="#{AmcApply::PACKAGE_REL_NS}">#{relationships}<Relationship Id="rId4" Type="#{AmcApply::OFFICE_REL_NS}/styles" Target="styles.xml"/></Relationships>),
        "xl/worksheets/sheet1.xml" => catalog_sheet(HEADERS, 2, ordinary),
        "xl/worksheets/sheet2.xml" => catalog_sheet([*HEADERS, ">99 pgs"], 3, large),
        "xl/worksheets/sheet3.xml" => books_sheet(sources, publishers),
        "xl/styles.xml" => styles
      }
    end

    # Return a styled finite sheet with row 1 headers and reserved large summary.
    # Inputs are validated capacities; no records or per-record formulas are seeded.
    def catalog_sheet(headers, first, capacity)
      rows = [row(1, headers.each_with_index.map { |header, index| text("#{column(index + 1)}1", header) })]
      rows << row(2, [formula("B2", "COUNTA(A3:A1000)")]) if first == 3
      (first...first + capacity).each do |number|
        rows << row(number, headers.each_with_index.map do |header, index|
          style = ["ADV - ID", "Adventure Title", "Source Book", "Book Publisher"].include?(header) ? 3 : 1
          %(<c r="#{column(index + 1)}#{number}" s="#{style}"/>)
        end)
      end
      sheet(rows)
    end

    # Return zero-cache Current Books formulas, one large summary per side, and
    # independent finite styled source/publisher slots. No identities are added.
    def books_sheet(sources, publishers)
      source_last = 4 + sources
      publisher_last = 4 + publishers
      rows = [row(1, []), row(2, [
        formula("A2", "SUM(A3:A#{source_last})"), formula("B2", "SUM(B3:B#{source_last})"),
        formula("C2", %(COUNTA(C3:C#{source_last})-COUNTIF(C3:C#{source_last},"#{BoundaryFreezeApply::SPECIAL_LARGE_LABEL}"))),
        formula("F2", "SUM(F3:F#{publisher_last})"), formula("G2", "SUM(G3:G#{publisher_last})"),
        formula("H2", %(COUNTA(H3:H#{publisher_last})-COUNTIF(H3:H#{publisher_last},"#{BoundaryFreezeApply::SPECIAL_LARGE_LABEL}")))
      ]), row(3, []), row(4, [
        formula("A4", "IF($B$2=0,0,B4/$B$2)"), formula("B4", "'AMC >100pg'!B2"),
        text("C4", BoundaryFreezeApply::SPECIAL_LARGE_LABEL), '<c r="D4"/>', formula("E4", "$B$2"),
        formula("F4", "IF($G$2=0,0,G4/$G$2)"), formula("G4", "'AMC >100pg'!B2"),
        text("H4", BoundaryFreezeApply::SPECIAL_LARGE_LABEL), formula("I4", "$G$2")
      ])]
      (5..[source_last, publisher_last].max).each do |number|
        columns = []
        columns.concat(("A".."E").to_a) if number <= source_last
        columns.concat(("F".."I").to_a) if number <= publisher_last
        rows << row(number, columns.map do |letter|
          style = %w[A F].include?(letter) ? 2 : (%w[C D H].include?(letter) ? 3 : 1)
          %(<c r="#{letter}#{number}" s="#{style}"/>)
        end)
      end
      sheet(rows)
    end

    # Return the accepted blank-template styles (general, integer, ratio, text).
    def styles
      fills = '<fills count="4">' \
              '<fill><patternFill patternType="none"/></fill>' \
              '<fill><patternFill patternType="gray125"/></fill>' \
              '<fill><patternFill patternType="solid"><fgColor rgb="FFF4CCCC"/><bgColor indexed="64"/></patternFill></fill>' \
              '<fill><patternFill patternType="solid"><fgColor rgb="FFD0E0E3"/><bgColor indexed="64"/></patternFill></fill>' \
              '</fills>'
      %(<styleSheet xmlns="#{AmcApply::MAIN_NS}"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>#{fills}<borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>)
    end

    # Wrap serialized rows in one worksheet; returns XML with no external links.
    def sheet(rows)
      %(<worksheet xmlns="#{AmcApply::MAIN_NS}"><sheetData>#{rows.join}</sheetData></worksheet>)
    end

    # Serialize an explicit row of cells; returns XML without allocating capacity.
    def row(number, cells)
      %(<row r="#{number}">#{cells.join}</row>)
    end

    # Serialize escaped text; returns XML, with no shared-string dependency.
    def text(reference, value)
      %(<c r="#{reference}" t="str"><v>#{CGI.escapeHTML(value)}</v></c>)
    end

    # Serialize a formula whose zero cache follows from the empty population.
    def formula(reference, expression)
      %(<c r="#{reference}"><f>#{CGI.escapeHTML(expression)}</f><v>0</v></c>)
    end

    # Return Excel column letters for a positive bounded header position.
    def column(number)
      letters = +""
      while number.positive?
        number -= 1
        letters.prepend((65 + number % 26).chr)
        number /= 26
      end
      letters
    end
  end
end
