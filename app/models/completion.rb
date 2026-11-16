# frozen_string_literal: true

# How a finished session felt.
class Completion < Record
  # The signed-in user's: those of their sessions (see Record.per_user).
  per_user(:session_id) { Session.select(:id) }
  FEEDBACK = %w[too_easy right too_hard].freeze
  MAX_NOTE = 2000

  many_to_one :session

  def as_json(*)
    { finished_at:, rpe:, feedback:, note:, ended_early: }
  end

  # An agent may finish a session; how a finish felt, once it is there, is
  # the user's to change.
  def before_save
    Record.user_only!("only the user changes how a finished session felt, in the app") unless new?
    super
  end

  def validate
    super
    validates_presence :finished_at
    validates_number :rpe, only_integer: true, within: 1..10, allow_nil: true
    validates_includes FEEDBACK, :feedback, allow_nil: true
    # Checked when written, so a longer note kept from before still saves.
    return unless new? || column_changed?(:note)

    validates_max_length MAX_NOTE, :note, allow_nil: true, message: "is longer than #{MAX_NOTE} characters"
  end
end
