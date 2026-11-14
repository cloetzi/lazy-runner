# How a finished session felt.
class Completion < Record
  # The signed-in user's: those of their sessions (see Record.per_user).
  per_user(:session_id) { Session.select(:id) }
  FEEDBACK = %w[too_easy right too_hard].freeze

  many_to_one :session

  def as_json(*)
    { finished_at:, rpe:, feedback:, note:, ended_early: }
  end

  def validate
    super
    validates_presence :finished_at
    validates_number :rpe, only_integer: true, within: 1..10, allow_nil: true
    validates_includes FEEDBACK, :feedback, allow_nil: true
  end
end
