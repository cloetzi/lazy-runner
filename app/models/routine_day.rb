# A day of a routine the user changed: `confirmed` ("I'm going"), `skipped`
# ("Not this week"), or `moved` to another day, where it is tentative again
# (a confirmed or skipped day may have been moved first, and keeps
# `moved_to`). Days
# nobody changed are not stored: RoutineCalendar works them out from the
# routine. A workout routine's confirmed day is a planned session instead
# (`sessions.routine_id` + `routine_date`), so it is not stored here.
#
# The user's through its routine, as a set log is through its session.
class RoutineDay < Record
  STATUSES = %w[confirmed skipped moved].freeze

  per_user(:routine_id) { Routine.select(:id) }
  many_to_one :routine

  def validate
    super
    validates_presence %i[routine_id date status]
    validates_includes STATUSES, :status
    errors.add(:moved_to, "can't be blank") if status == "moved" && moved_to.nil?
  end
end
