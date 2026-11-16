# frozen_string_literal: true

# What the app refuses, as against a bug: a record that isn't there, a
# change only the user may make, a session no longer planned. Each kind says
# how the API answers it (`refuses_with :conflict`), and the MCP tools give
# its message back as a tool error, so a new one is named once, where it is
# raised. (Errors that carry a record's or a list's field errors, such as
# WorkoutStructure::Invalid, keep handlers of their own.)
class Refusal < StandardError
  class << self
    # The HTTP status and the error code (config/openapi_components.yml)
    # the API answers with; a subclass inherits its parent's.
    def refuses_with(status, code = status.to_s)
      @status = status
      @code = code
    end

    def status = @status || superclass.status
    def code = @code || superclass.code
  end

  refuses_with :conflict

  # More of the error's shape, beside its code and message (a not_found's
  # `resource` and `id`).
  def details = {}
end
