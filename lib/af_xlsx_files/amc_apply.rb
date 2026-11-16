# frozen_string_literal: true

module AfXlsxFiles
  # Workbook/XML/style helpers for accepted-value callers. This parser model
  # interprets explicit workbook bytes; workflow admission remains in PL.
  class AmcApply
    REQUIRED_FILL = "#F4CCCC"
    MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    OFFICE_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    PACKAGE_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
    NS = { "s" => MAIN_NS, "r" => OFFICE_REL_NS, "pr" => PACKAGE_REL_NS }.freeze
    ADV_ID = /\AADV-\d{4}\z/
    ADVENTURE_ID_HEADER = "ADV - ID"

    # Explicit canonical metric-to-header mapping. Levels outcomes arrive as
    # the two independent candidate keys below.
    DIMENSION_HEADERS = {
      "# of Sessions" => "Number of Sessions",
      "Number of Sessions" => "Number of Sessions",
      "Exploration Emphasis" => "Exploration Emphasis",
      "Level Start" => "Level Start",
      "Level End" => "Level End",
      "Combat Emphasis" => "Combat Emphasis",
      "Social Interaction Emphasis" => "Social Interaction Emphasis",
      "Investigation Emphasis" => "Investigation Emphasis",
      "Structural Openness" => "Structural Openness",
      "Darkness / Horror Intensity" => "Darkness / Horror Intensity",
      "Player Beginner Suitability" => "Player Beginner Suitability",
      "GM Beginner Suitability" => "GM Beginner Suitability",
      "GM Preparation Burden" => "GM Preparation Burden",
      "Seriousness" => "Seriousness",
      "Rules / System-Master Demand" => "Rules / System-Master Demand",
      "Tactical Complexity" => "Tactical Complexity",
      "Lethality / Failure Severity" => "Lethality / Failure Severity",
      "Puzzle / Problem-Solving Emphasis" => "Puzzle / Problem-Solving Emphasis",
      "Consequential Player Agency" => "Consequential Player Agency",
      "Fantastic Weirdness" => "Fantastic Weirdness",
      "GM Improvisation Demand" => "GM Improvisation Demand"
    }.freeze

    # Explicit workbook/role representation; parses caller inputs and preserves integrity, raising owner validation or native parse/I/O errors.
    class Workbook
      attr_reader :path, :styles

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
        %w[xl/workbook.xml xl/_rels/workbook.xml.rels xl/styles.xml].each do |name|
          raise ValidationError, "required XLSX package member missing: #{name}" unless @members.key?(name)
        end
        @styles = StyleTable.new(@members.fetch("xl/styles.xml"))
        @sheet_infos = read_sheet_infos
        @sheets = {}
      end

      # Return original ZIP member order for package-integrity comparison; no content is changed.
      def entry_names = @entry_names

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

      # Return the parsed worksheet for an explicit part or nil when absent; malformed XML raises parse/validation errors.
      def sheet(part)
        return nil unless @members.key?(part)

        info = @sheet_infos.find { |item| item.fetch(:part) == part }
        sheet_name = info ? info.fetch(:name) : part
        @sheets[part] ||= Worksheet.new(name: sheet_name, part:, xml: @members.fetch(part), shared_strings: shared_strings)
      end

      # Return the unique Adventure Catalog worksheet with its expected ID header; missing/ambiguous selection raises ValidationError.
      def catalog_sheet!
        matches = @sheet_infos.select { |info| info.fetch(:name) == "Adventure Catalog" }
        unless matches.one?
          raise ValidationError, "AMC catalog worksheet named \"Adventure Catalog\" could not be identified uniquely (found #{matches.length})"
        end

        candidate = sheet(matches.first.fetch(:part))
        unless candidate.catalog_header_candidate?
          raise ValidationError, "AMC catalog worksheet \"Adventure Catalog\" does not contain the expected #{ADVENTURE_ID_HEADER.inspect} header"
        end

        candidate
      end

      # Return the actual formula count across all loaded sheets; parse/schema errors propagate.
      def formula_count
        sheet_parts.sum { |part| sheet(part).cell_snapshots.values.count { |item| item["formula"] } }
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
          unless target
            raise ValidationError, "workbook relationship missing for sheet #{sheet.attributes['name'].inspect}"
          end

          part = if target.start_with?("/")
            target.delete_prefix("/")
          else
            Pathname.new(File.join("xl", target)).cleanpath.to_s
          end
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
      attr_reader :name, :part

      # Bind explicit representation inputs and initialize parsed/cached state; returns an instance, propagating XML/ZIP/I/O/validation errors when parsing occurs.
      def initialize(name:, part:, xml:, shared_strings:)
        @name = name
        @part = part
        @document = REXML::Document.new(xml)
        @shared_strings = shared_strings
        @cells = nil
      end

      # Return whether this worksheet contains the expected catalog header candidate; no mutation occurs.
      def catalog_header_candidate?
        header_candidates.any?
      end

      # Resolve required ID/dimension columns and return the worksheet; ambiguous/missing headers raise ValidationError.
      def resolve_headers!(dimensions)
        candidates = header_candidates
        raise ValidationError, "ambiguous AMC header row in #{name}" unless candidates.one?

        @header_row, @headers = candidates.first
        id_columns = @headers.fetch(ADVENTURE_ID_HEADER, [])
        unless id_columns.one?
          raise ValidationError, "ambiguous #{ADVENTURE_ID_HEADER.inspect} header in #{name}"
        end
        @id_column = id_columns.first
        dimensions.uniq.each do |dimension|
          header = DIMENSION_HEADERS.fetch(dimension)
          columns = @headers.fetch(header, [])
          raise ValidationError, "missing target dimension/header #{header.inspect} in #{name}" if columns.empty?
          unless columns.one?
            raise ValidationError, "ambiguous target dimension/header #{header.inspect} in #{name}"
          end
        end
        @dimension_columns = dimensions.uniq.to_h do |dimension|
          [dimension, @headers.fetch(DIMENSION_HEADERS.fetch(dimension)).first]
        end
        @adventure_rows = build_adventure_rows
      end

      # Check the worksheet ID index and raise ValidationError for duplicates; no writes occur.
      def validate_unique_adventure_ids!
        duplicates = @adventure_rows.select { |_id, rows| rows.length > 1 }
        return if duplicates.empty?

        details = duplicates.map { |id, rows| "#{id} (rows #{rows.join(', ')})" }.join(", ")
        raise ValidationError, "duplicate Adventure IDs in AMC worksheet: #{details}"
      end

      # Return the row for the explicit Adventure ID, or nil when absent; duplicate identities raise ValidationError.
      def row_for_adventure(adventure_id)
        rows = @adventure_rows.fetch(adventure_id, [])
        rows.one? ? rows.first : nil
      end

      # Return the uniquely mapped assessment column; unsupported or ambiguous dimensions raise ValidationError.
      def column_for_dimension(dimension)
        @dimension_columns.fetch(dimension)
      end

      # Return the XML cell at the explicit reference or nil when absent; malformed XML is not repaired.
      def cell(reference)
        cells[reference]
      end

      # Return whether a cell has no value or formula; zero, -1 and nonblank text are preserved.
      def blank_cell?(cell)
        return true unless cell
        return false if formula(cell)

        current = value(cell)
        current.nil? || current.to_s.empty?
      end

      # Return the parsed numeric cell scalar or nil for nonnumeric content; no cache is fabricated.
      def cell_numeric_value(cell)
        return nil unless cell && !formula(cell)
        return nil unless cell.attributes["t"].nil? || cell.attributes["t"] == "n"

        AmcApply.parse_number(raw_value(cell))
      end

      # Return the cell formula text or nil; formula caches do not substitute for formulas.
      def cell_formula(cell)
        formula(cell)
      end

      # Return the worksheet scalar for conflict diagnostics while preserving blank and sentinel distinctions.
      def display_value(cell)
        return nil unless cell
        current_formula = formula(cell)
        return "=#{current_formula}" if current_formula

        value(cell)
      end

      # Return the target style or a unique equivalent neighbor style; ambiguity/invalid style raises ValidationError.
      def base_style_for(reference, styles)
        existing = cell(reference)
        return Integer(existing.attributes["s"] || "0", 10) if existing

        _column, row_number = AmcApply.reference_parts(reference)
        style_ids = assessment_columns.filter_map do |column|
          peer = cell("#{column}#{row_number}")
          peer && Integer(peer.attributes["s"] || "0", 10)
        end
        signatures = style_ids.to_h { |style_id| [styles.base_signature(style_id), style_id] }
        raise ValidationError, "cannot identify formatting for absent target cell #{reference}" unless signatures.length == 1

        signatures.values.first
      rescue ArgumentError
        raise ValidationError, "invalid style index at #{reference}"
      end

      # Write the requested admitted numeric value/style in memory; invalid references or missing rows raise ValidationError.
      def write!(record)
        reference = record.fetch("cell")
        column, row_number = AmcApply.reference_parts(reference)
        row = row_element(row_number)
        raise ValidationError, "worksheet row missing for #{reference}" unless row

        target = cell(reference)
        unless target
          cell_name = row.prefix.to_s.empty? ? "c" : "#{row.prefix}:c"
          target = REXML::Element.new(cell_name)
          target.add_attribute("r", reference)
          following = REXML::XPath.match(row, "./s:c", NS).find do |candidate|
            candidate_column, = AmcApply.reference_parts(candidate.attributes["r"])
            AmcApply.column_number(candidate_column) > AmcApply.column_number(column)
          end
          following ? row.insert_before(following, target) : row.add_element(target)
          cells[reference] = target
        end
        target.attributes["s"] = record.fetch("expected_style_index").to_s
        target.elements.to_a.each do |child|
          target.delete_element(child) if %w[f v is].include?(child.name)
        end
        proposed_value = record.fetch("proposed_value")
        first_auxiliary = target.elements[1]
        if proposed_value.is_a?(String)
          target.attributes["t"] = "inlineStr"
          inline_name = target.prefix.to_s.empty? ? "is" : "#{target.prefix}:is"
          text_name = target.prefix.to_s.empty? ? "t" : "#{target.prefix}:t"
          inline_element = REXML::Element.new(inline_name)
          text_element = REXML::Element.new(text_name)
          text_element.text = proposed_value
          inline_element.add_element(text_element)
          first_auxiliary ? target.insert_before(first_auxiliary, inline_element) : target.add_element(inline_element)
        else
          target.delete_attribute("t")
          value_name = target.prefix.to_s.empty? ? "v" : "#{target.prefix}:v"
          value_element = REXML::Element.new(value_name)
          value_element.text = AmcApply.serialize_number(proposed_value)
          first_auxiliary ? target.insert_before(first_auxiliary, value_element) : target.add_element(value_element)
        end
      end

      # Return per-reference canonical cell snapshots for exact mutation comparison; no workbook bytes are written.
      def cell_snapshots
        cells.transform_values { |cell| snapshot(cell) }
      end

      # Return a cell snapshot including value/formula/style and auxiliary structure; nil represents an absent cell.
      def snapshot(cell)
        attributes = {}
        cell.attributes.each_attribute { |attribute| attributes[attribute.expanded_name] = attribute.value }
        {
          "type" => cell.attributes["t"],
          "style" => cell.attributes["s"],
          "formula" => formula(cell),
          "value" => value(cell),
          "attributes" => attributes,
          "cell_structure" => AmcApply.canonical_element(cell)
        }
      end

      # Return whether before/after snapshots preserve all non-authorized target structure.
      def written_cell_structure_preserved?(source_cell, output_cell)
        output_attributes = attribute_hash(output_cell).reject { |name, _value| %w[s t].include?(name) }
        if source_cell
          source_attributes = attribute_hash(source_cell).reject { |name, _value| %w[s t].include?(name) }
          return false unless source_attributes == output_attributes
        else
          return false unless output_attributes == { "r" => output_cell.attributes["r"] }
        end

        auxiliary_children(source_cell) == auxiliary_children(output_cell)
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

      # Return rows containing the catalog ID header for unambiguous schema selection.
      def header_candidates
        return @header_candidates if defined?(@header_candidates)

        @header_candidates = REXML::XPath.match(@document, "//s:sheetData/s:row", NS).filter_map do |row|
          headers = Hash.new { |hash, key| hash[key] = [] }
          REXML::XPath.each(row, "./s:c", NS) do |cell|
            text = value(cell)
            next if text.nil?

            column, = AmcApply.reference_parts(cell.attributes["r"])
            headers[text.to_s] << column
          end
          known_dimensions = DIMENSION_HEADERS.values.count { |header| headers.key?(header) }
          next unless headers.key?(ADVENTURE_ID_HEADER) && known_dimensions.positive?

          [Integer(row.attributes["r"], 10), headers]
        end
      end

      # Return an Adventure-ID-to-row index from actual cells; duplicate or malformed references raise ValidationError.
      def build_adventure_rows
        rows = Hash.new { |hash, key| hash[key] = [] }
        REXML::XPath.each(@document, "//s:sheetData/s:row", NS) do |row|
          row_number = Integer(row.attributes["r"], 10)
          next if row_number == @header_row

          id = value(cell("#{@id_column}#{row_number}")).to_s.strip
          rows[id] << row_number if id.match?(ADV_ID)
        end
        rows
      end

      # Return column positions for the declared dimension headers, preserving optional/missing columns.
      def assessment_columns
        @headers.values_at(*DIMENSION_HEADERS.values).flatten.compact.uniq
      end

      # Return the worksheet reference-to-element index; duplicate references raise ValidationError where required by this parser.
      def cells
        return @cells if @cells

        elements = REXML::XPath.match(@document, "//s:sheetData/s:row/s:c", NS)
        references = elements.map { |item| item.attributes["r"] }
        duplicates = references.tally.select { |_reference, count| count > 1 }.keys
        unless duplicates.empty?
          raise ValidationError, "duplicate worksheet cell references in #{name}: #{duplicates.join(', ')}"
        end

        @cells = elements.to_h { |item| [item.attributes["r"], item] }
      end

      # Return the XML row for the explicit row number, or nil if preallocated capacity is absent.
      def row_element(row_number)
        REXML::XPath.first(@document, "//s:sheetData/s:row[@r='#{row_number}']", NS)
      end

      # Return the supplied cell formula text or nil; no evaluation or cache synthesis occurs.
      def formula(cell)
        cell && REXML::XPath.first(cell, "./s:f", NS)&.text
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

      # Return the supplied XML element attributes for exact structural comparison; no mutation occurs.
      def attribute_hash(cell)
        attributes = {}
        cell.attributes.each_attribute { |attribute| attributes[attribute.expanded_name] = attribute.value }
        attributes
      end

      # Return non-value/formula child structure from a cell for unauthorized-change detection.
      def auxiliary_children(cell)
        return [] unless cell

        cell.elements.to_a.reject { |child| %w[f v is].include?(child.name) }.map do |child|
          AmcApply.canonical_element(child)
        end
      end
    end

    # Explicit workbook/role representation; parses caller inputs and preserves integrity, raising owner validation or native parse/I/O errors.
    class StyleTable
      attr_reader :appended_count

      # Bind explicit representation inputs and initialize parsed/cached state; returns an instance, propagating XML/ZIP/I/O/validation errors when parsing occurs.
      def initialize(xml)
        @document = REXML::Document.new(xml)
        @fills = REXML::XPath.match(@document, "//s:styleSheet/s:fills/s:fill", NS)
        @cell_xfs_element = REXML::XPath.first(@document, "//s:styleSheet/s:cellXfs", NS)
        raise ValidationError, "styles.xml is missing cellXfs" unless @cell_xfs_element
        @cell_xfs = REXML::XPath.match(@cell_xfs_element, "./s:xf", NS)
        red_fills = @fills.each_index.select { |index| fill_rgb_by_index(index) == REQUIRED_FILL && solid_fill?(index) }
        unless red_fills.one?
          raise ValidationError, "required solid fill #{REQUIRED_FILL} could not be identified uniquely"
        end

        @red_fill_id = red_fills.first
        @original_xf_count = @cell_xfs.length
        @appended_count = 0
      end

      # Return an existing or appended red-fill style preserving the source base signature; ambiguous/missing styles raise ValidationError.
      def red_style_for(base_style_id)
        base = @cell_xfs[base_style_id]
        raise ValidationError, "style index #{base_style_id} does not exist" unless base
        return base_style_id if Integer(base.attributes["fillId"] || "0", 10) == @red_fill_id

        signature = base_signature(base_style_id)
        matches = @cell_xfs.each_index.select do |index|
          Integer(@cell_xfs[index].attributes["fillId"] || "0", 10) == @red_fill_id && base_signature(index) == signature
        end
        raise ValidationError, "multiple #{REQUIRED_FILL} styles match source style #{base_style_id}" if matches.length > 1
        return matches.first if matches.one?

        clone = base.deep_clone
        clone.attributes["fillId"] = @red_fill_id.to_s
        clone.attributes["applyFill"] = "1"
        @cell_xfs_element.add_element(clone)
        @cell_xfs << clone
        @cell_xfs_element.attributes["count"] = @cell_xfs.length.to_s
        @appended_count += 1
        @cell_xfs.length - 1
      end

      # Return an existing or appended target-fill style preserving the source signature; invalid/ambiguous styles raise ValidationError.
      def style_for_fill(base_style_id, target_fill)
        base = @cell_xfs[base_style_id]
        raise ValidationError, "style index #{base_style_id} does not exist" unless base

        fill_ids = @fills.each_index.select do |index|
          fill_rgb_by_index(index) == target_fill && solid_fill?(index)
        end
        unless fill_ids.one?
          raise ValidationError, "required solid fill #{target_fill} could not be identified uniquely"
        end
        fill_id = fill_ids.first
        return base_style_id if Integer(base.attributes["fillId"] || "0", 10) == fill_id

        signature = base_signature(base_style_id)
        matches = @cell_xfs.each_index.select do |index|
          Integer(@cell_xfs[index].attributes["fillId"] || "0", 10) == fill_id &&
            base_signature(index) == signature
        end
        raise ValidationError, "multiple #{target_fill} styles match source style #{base_style_id}" if matches.length > 1
        return matches.first if matches.one?

        clone = base.deep_clone
        clone.attributes["fillId"] = fill_id.to_s
        clone.attributes["applyFill"] = "1"
        @cell_xfs_element.add_element(clone)
        @cell_xfs << clone
        @cell_xfs_element.attributes["count"] = @cell_xfs.length.to_s
        @appended_count += 1
        @cell_xfs.length - 1
      end

      # Return canonical style structure excluding fill-only attributes; missing style indices raise ValidationError.
      def base_signature(style_id)
        style = @cell_xfs[style_id]
        raise ValidationError, "style index #{style_id} does not exist" unless style

        AmcApply.canonical_element(style, ignored_attributes: %w[fillId applyFill])
      end

      # Return the normalized RGB fill for a style or nil for an invalid index; no style is changed.
      def fill_rgb(style_id)
        style = @cell_xfs[Integer(style_id, 10)]
        return nil unless style

        fill_rgb_by_index(Integer(style.attributes["fillId"] || "0", 10))
      rescue ArgumentError, TypeError
        nil
      end

      # Return whether the supplied style table preserves all originals and only the declared appended styles.
      def append_only_match?(other, appended)
        other_xfs = other.instance_variable_get(:@cell_xfs)
        return false unless other_xfs.length == @original_xf_count + appended
        return false unless @cell_xfs.first(@original_xf_count).each_with_index.all? do |style, index|
          AmcApply.canonical_element(style) == AmcApply.canonical_element(other_xfs[index])
        end

        source_without_xfs = REXML::Document.new(to_xml)
        output_without_xfs = REXML::Document.new(other.to_xml)
        [source_without_xfs, output_without_xfs].each do |document|
          xfs = REXML::XPath.first(document, "//s:styleSheet/s:cellXfs", NS)
          REXML::XPath.match(xfs, "./s:xf", NS).each { |child| xfs.delete_element(child) }
          xfs.delete_attribute("count")
        end
        AmcApply.canonical_element(source_without_xfs.root) == AmcApply.canonical_element(output_without_xfs.root)
      end

      # Serialize the current in-memory XML document; no destination is opened and formatter errors propagate.
      def to_xml
        AmcApply.serialize_xml(@document)
      end

      private

      # Return whether the selected fill is solid; missing pattern data yields false/nil.
      def solid_fill?(index)
        pattern = REXML::XPath.first(@fills[index], "./s:patternFill", NS)
        pattern && pattern.attributes["patternType"] == "solid"
      end

      # Return normalized fill RGB or nil when absent; alpha-prefixed RGB is reduced to six digits.
      def fill_rgb_by_index(index)
        fill = @fills[index]
        return nil unless fill
        color = REXML::XPath.first(fill, "./s:patternFill/s:fgColor", NS)
        rgb = color && color.attributes["rgb"]&.upcase
        return nil unless rgb

        rgb = rgb[-6, 6] if rgb.length == 8
        "##{rgb}"
      end
    end

    class << self
      # Return an integer/finite float for valid numeric text, otherwise nil; blank and nonnumeric sentinels are not coerced.
      def parse_number(value)
        text = value.to_s
        return nil unless text.match?(/\A-?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?\z/)
        return Integer(text, 10) unless text.match?(/[.Ee]/)

        number = Float(text)
        number.finite? ? number : nil
      rescue ArgumentError
        nil
      end

      # Return the admitted numeric value as XML scalar text; no rounding or inference occurs.
      def serialize_number(value)
        value.to_s
      end

      # Return column letters and positive row for an Excel reference; malformed references raise ValidationError.
      def reference_parts(reference)
        match = /\A([A-Z]+)([1-9]\d*)\z/.match(reference.to_s)
        raise ValidationError, "invalid worksheet cell reference #{reference.inspect}" unless match

        [match[1], Integer(match[2], 10)]
      end

      # Return the numeric position of uppercase Excel column letters; callers supply validated references.
      def column_number(column)
        column.each_byte.reduce(0) { |total, byte| (total * 26) + byte - 64 }
      end

      # Return XML text from the supplied document; formatter exceptions propagate without writing files.
      def serialize_xml(document)
        output = +""
        REXML::Formatters::Default.new.write(document, output)
        output
      end

      # Return recursive XML structure ignoring only explicitly named attributes; preserves meaningful text and child order.
      def canonical_element(element, ignored_attributes: [])
        attributes = []
        element.attributes.each_attribute do |attribute|
          next if ignored_attributes.include?(attribute.expanded_name)
          attributes << [attribute.expanded_name, attribute.value]
        end
        children = element.children.filter_map do |child|
          if child.is_a?(REXML::Element)
            canonical_element(child)
          elsif child.respond_to?(:value) && !child.value.to_s.strip.empty?
            ["#text", child.value]
          end
        end
        [element.expanded_name, attributes.sort, children]
      end
    end
  end
end
