# frozen_string_literal: true

module AfXlsxFiles
  # Base error for catalog representation and construction failures.
  class Error < StandardError; end
  # Invalid, conflicting or changed input; no approval is implied by validation.
  class ValidationError < Error; end
end
