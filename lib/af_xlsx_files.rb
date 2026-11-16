# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rexml/document"
require "rexml/formatters/default"
require "rexml/xpath"
require "set"
require "tempfile"
require "time"
require "yaml"
require "zip"

# Public representation and finite construction owner; no workflow admission or
# catalog promotion API. Runtime/parse/filesystem errors retain their classes.
module AfXlsxFiles
  API_VERSION = "0.1"
end

require_relative "af_xlsx_files/error"
require_relative "af_xlsx_files/project_state"
require_relative "af_xlsx_files/amc_apply"
require_relative "af_xlsx_files/input_binding"
require_relative "af_xlsx_files/boundary_freeze_apply"
require_relative "af_xlsx_files/amc_compatibility_check"
require_relative "af_xlsx_files/empty_catalog"
