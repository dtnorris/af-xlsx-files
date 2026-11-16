# frozen_string_literal: true

require "digest"
require "fileutils"
require "yaml"

module AfXlsxFiles
  # Explicit workbook/role representation; parses caller inputs and preserves integrity, raising owner validation or native parse/I/O errors.
  class ProjectState
    SCHEMA_VERSION = "adventurefinder-project-state/v0.2"
    ROLES = %w[catalog_head matcher_authorized_baseline production_dependency_floor].freeze
    REQUIRED_ROLE_FIELDS = %w[version filename sha256 bytes].freeze
    SHA256_RE = /\A[0-9a-f]{64}\z/
    VERSION_RE = /\A\d+(?:\.\d+)*\z/

    Role = Struct.new(:name, :version, :filename, :sha256, :bytes, :path, keyword_init: true)

    attr_reader :manifest_path

    # Bind explicit representation inputs and initialize parsed/cached state; returns an instance, propagating XML/ZIP/I/O/validation errors when parsing occurs.
    def initialize(manifest_path:)
      @manifest_path = File.expand_path(manifest_path)
      @data = nil
    end

    # Return a valid structural report or true for the bound state; invalid representation raises the owner error.
    def validate!
      data = load_data
      validate_data!(data)
      @data = data
      true
    end

    # Validate and return the explicitly named role binding; malformed state, unknown role or changed artifact raises Error.
    def resolve(role)
      validate! unless @data
      role = normalize_role(role)
      entry = @data.fetch(role)
      Role.new(
        name: role,
        version: entry.fetch("version"),
        filename: entry.fetch("filename"),
        sha256: entry.fetch("sha256"),
        bytes: entry.fetch("bytes"),
        path: artifact_path(entry.fetch("filename"))
      )
    end

    private

    # Return safely loaded string-keyed manifest data; absent, malformed or nonmapping YAML raises Error.
    def load_data
      raise Error, "missing project-state manifest: #{manifest_path}" unless File.file?(manifest_path)
      raw = YAML.safe_load_file(manifest_path, aliases: false) || {}
      raise Error, "project-state manifest must contain a mapping" unless raw.is_a?(Hash)
      stringify_keys(raw)
    rescue Psych::Exception => e
      raise Error, "invalid project-state YAML: #{e.message}"
    end

    # Validate closed v0.2 fields, all role artifacts and independent-role ceilings; violations raise Error.
    def validate_data!(data)
      allowed = ["schema_version", *ROLES]
      unknown = data.keys - allowed
      raise Error, "unknown project-state keys: #{unknown.join(', ')}" unless unknown.empty?

      schema = data["schema_version"]
      raise Error, "unsupported project-state schema #{schema.inspect}; expected #{SCHEMA_VERSION}" unless schema == SCHEMA_VERSION

      ROLES.each do |role|
        entry = data[role]
        raise Error, "missing project-state role: #{role}" unless entry.is_a?(Hash)
        validate_role!(role, entry)
      end

      head = data.fetch("catalog_head").fetch("version")
      %w[matcher_authorized_baseline production_dependency_floor].each do |role|
        version = data.fetch(role).fetch("version")
        next unless compare_versions(version, head).positive?
        raise Error, "#{role} #{version} cannot be newer than catalog_head #{head}"
      end
      true
    end

    # Validate one role entry against actual filename/version/hash/positive bytes; missing/changed artifacts raise Error.
    def validate_role!(role, entry)
      missing = REQUIRED_ROLE_FIELDS.reject { |field| entry.key?(field) }
      raise Error, "#{role} missing fields: #{missing.join(', ')}" unless missing.empty?

      unknown = entry.keys - REQUIRED_ROLE_FIELDS
      raise Error, "#{role} has unknown fields: #{unknown.join(', ')}" unless unknown.empty?

      version = entry.fetch("version").to_s
      raise Error, "#{role} has invalid version #{version.inspect}" unless VERSION_RE.match?(version)

      filename = entry.fetch("filename").to_s
      expected = canonical_filename(version)
      raise Error, "#{role} filename must be #{expected.inspect}" unless filename == expected
      raise Error, "#{role} filename must be a top-level basename" unless File.basename(filename) == filename

      sha256 = entry.fetch("sha256").to_s
      raise Error, "#{role} has invalid sha256" unless SHA256_RE.match?(sha256)

      bytes = entry.fetch("bytes")
      raise Error, "#{role} bytes must be a positive integer" unless bytes.is_a?(Integer) && bytes.positive?

      path = artifact_path(filename)
      raise Error, "#{role} artifact does not exist: #{path}" unless File.file?(path)
      actual_bytes = File.size(path)
      raise Error, "#{role} byte-size mismatch: expected #{bytes}, got #{actual_bytes}" unless actual_bytes == bytes
      actual_sha = Digest::SHA256.file(path).hexdigest
      raise Error, "#{role} SHA-256 mismatch: expected #{sha256}, got #{actual_sha}" unless actual_sha == sha256
    end

    # Return the canonical workbook basename for the supplied validated version string.
    def canonical_filename(version)
      "5e_Adventure_Master_Catalog_#{version}.xlsx"
    end

    # Return the directory containing the explicitly selected role manifest.
    def manifest_root
      File.dirname(manifest_path)
    end

    # Return the manifest-relative absolute artifact path for an already validated basename.
    def artifact_path(filename)
      File.expand_path(filename, manifest_root)
    end

    # Return an explicitly supported role name as text; unknown names raise Error.
    def normalize_role(role)
      value = role.to_s
      raise Error, "unknown project-state role #{value.inspect}; expected one of: #{ROLES.join(', ')}" unless ROLES.include?(value)
      value
    end

    # Return numeric dotted-version ordering, padding missing components with zero; inputs have validated numeric syntax.
    def compare_versions(left, right)
      a = left.to_s.split(".").map!(&:to_i)
      b = right.to_s.split(".").map!(&:to_i)
      length = [a.length, b.length].max
      (a + [0] * (length - a.length)) <=> (b + [0] * (length - b.length))
    end

    # Return a recursively string-keyed copy of YAML mappings/arrays, preserving scalar values.
    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), out| out[key.to_s] = stringify_keys(child) }
      when Array
        value.map { |child| stringify_keys(child) }
      else
        value
      end
    end

  end
end
