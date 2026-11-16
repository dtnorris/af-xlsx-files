# frozen_string_literal: true

module AfXlsxFiles
  # Checks representation and byte bindings independently of PL. This does not
  # validate editorial approval, registry meaning or operation authorization.
  module InputBinding
    module_function

    # Validate concrete frozen input against actual bytes. Returns true; raises
    # ValidationError for malformed/drifting representation or missing bindings.
    def validate!(freeze_path:, source_root:, amc_path:, artifact:, freeze_sha256:, amc_sha256:)
      bound_file!(freeze_path, freeze_sha256, "boundary freeze")
      bound_file!(amc_path, amc_sha256, "base AMC")
      actual = YAML.safe_load_file(freeze_path, aliases: false)
      unless actual == artifact && artifact.is_a?(Hash) &&
             artifact.keys.sort == %w[approval base_amc records schema_version source state] &&
             artifact["schema_version"] == "af-boundary-freeze/v0.1" && artifact["state"] == "frozen"
        raise ValidationError, "admitted representation differs from bound boundary freeze"
      end
      unless artifact["base_amc"] == {"filename" => File.basename(amc_path), "sha256" => amc_sha256}
        raise ValidationError, "admitted base AMC binding does not match actual base"
      end
      source = artifact.fetch("source")
      unless source.is_a?(Hash) && source.keys.sort == %w[canonical_source_id markdown_files registry_filename registry_sha256] && nonblank?(source["canonical_source_id"])
        raise ValidationError, "invalid source representation binding"
      end
      bound_source!(source_root, source["registry_filename"], source["registry_sha256"])
      markdown = source["markdown_files"]
      unless markdown.is_a?(Array) && !markdown.empty? && markdown.all? { |item| item.is_a?(Hash) && item.keys.sort == %w[filename sha256] } && markdown.map { |item| item["filename"] }.uniq.length == markdown.length
        raise ValidationError, "invalid Markdown representation bindings"
      end
      markdown.each { |item| bound_source!(source_root, item["filename"], item["sha256"]) }
      validate_records!(artifact["records"])
      true
    rescue Psych::Exception, SystemCallError => error
      raise ValidationError, "construction input binding failed: #{error.message}"
    end

    # Check relative bound bytes without interpreting source registry policy.
    # Returns nil; escaping roots, invalid paths or changed bytes raise ValidationError.
    def bound_source!(root, filename, sha256)
      unless nonblank?(filename) && !Pathname.new(filename).absolute?
        raise ValidationError, "source binding filename must be relative"
      end
      real_root = File.realpath(root)
      path = File.realpath(File.expand_path(filename, real_root))
      raise ValidationError, "source binding escapes selected root" unless path.start_with?(real_root + File::SEPARATOR)
      bound_file!(path, sha256, "source #{filename}")
    end

    # Require a positive regular file and exact SHA-256. Returns nil or raises
    # ValidationError; no filename or timestamp discovery is performed.
    def bound_file!(path, expected, label)
      unless expected.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(expected) &&
             File.file?(path) && File.size(path).positive? && Digest::SHA256.file(path).hexdigest == expected
        raise ValidationError, "#{label} bytes do not match admitted binding"
      end
    end

    # Validate finite ordered record representation and parent references.
    # Returns nil; bad pages, duplicate keys, cycles or malformed fields refuse.
    def validate_records!(records)
      raise ValidationError, "records must be an array" unless records.is_a?(Array)
      allowed = %w[local_key canonical_title printed_pages pdf_pages parent_key parent_adventure_id levels editorial_rationale state]
      required = %w[local_key canonical_title printed_pages editorial_rationale state]
      by_key = {}
      records.each do |record|
        unless record.is_a?(Hash) && (record.keys - allowed).empty? && (required - record.keys).empty? &&
               nonblank?(record["local_key"]) && nonblank?(record["canonical_title"]) && record["state"] == "frozen"
          raise ValidationError, "invalid construction record representation"
        end
        key = record.fetch("local_key")
        raise ValidationError, "duplicate construction local_key #{key.inspect}" if by_key.key?(key)
        by_key[key] = record
        span!(record["printed_pages"])
        span!(record["pdf_pages"]) if record["pdf_pages"]
        span!(record["levels"]) if record["levels"]
        %w[parent_key parent_adventure_id].each do |field|
          raise ValidationError, "invalid #{field}" if record[field] && !nonblank?(record[field])
        end
        if record["parent_key"] && record["parent_adventure_id"]
          raise ValidationError, "record cannot select both parent references"
        end
        if record["parent_adventure_id"] && !/\AADV-\d{4,}\z/.match?(record["parent_adventure_id"])
          raise ValidationError, "invalid parent_adventure_id"
        end
      end
      by_key.each_key do |key|
        visited = Set.new
        while key
          raise ValidationError, "unknown or cyclic construction parent_key" if !by_key.key?(key) || !visited.add?(key)
          key = by_key.fetch(key)["parent_key"]
        end
      end
    end

    # Require whole positive ordered endpoints; returns nil or raises ValidationError.
    def span!(span)
      unless span.is_a?(Hash) && span.keys.sort == %w[end start] &&
             span.values.all? { |value| value.is_a?(Integer) && value.positive? } && span["end"] >= span["start"]
        raise ValidationError, "construction range must have ordered positive integer endpoints"
      end
    end

    # Return whether a value is a nonblank string; no conversion or I/O.
    def nonblank?(value)
      value.is_a?(String) && !value.strip.empty?
    end
  end
end
