# frozen_string_literal: true

require "json"

# Rage's JSON log lines, with what a client can put in them escaped. Rage
# writes the request's method and path, and a message, into the line as
# they are, so a path with a quote in it (/api/sessions/a","message":"...)
# could add fields of its own, and a message carrying an error's text could
# break the line. The setup code is read from this log.
class LogFormatter < Rage::JSONFormatter
  # What ends a JSON string or has to be escaped in one.
  UNSAFE = /["\\\x00-\x1f\x7f]/

  def call(severity, timestamp, progname, message)
    final = Fiber[:__rage_logger_final]
    env = final.is_a?(Hash) && final[:env]
    unless env && %w[REQUEST_METHOD PATH_INFO].any? { unsafe?(env[it]) }
      # Rage writes any message as its to_s.
      return super(severity, timestamp, progname, message.nil? ? nil : safe(message.to_s))
    end

    # The request's own env stays as it was: the line is written from a copy.
    Fiber[:__rage_logger_final] = final.merge(env: env.merge(%w[REQUEST_METHOD PATH_INFO].to_h { [it, safe(env[it])] }))
    begin
      super
    ensure
      Fiber[:__rage_logger_final] = final
    end
  end

  private

  # Whether the text can't go into the line as it is: it has a character
  # JSON escapes, or isn't UTF-8 (the server hands the path over as bytes).
  def unsafe?(value)
    return false unless value.is_a?(String)

    text = utf8(value)
    !text.valid_encoding? || text.match?(UNSAFE)
  end

  # The text as it reads inside a JSON string, quotes left off, with bytes
  # that aren't UTF-8 replaced.
  def safe(value)
    return value unless unsafe?(value)

    JSON.generate(utf8(value).scrub)[1...-1]
  end

  def utf8(value) = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
end
