# The Coach tab in one read: the goals that anchor it (and proposals
# waiting), the current status and focus, the open concerns, the latest of
# the journal, and the week around `today` as a plain list of what is on it.
# No totals or scores: the coach, person or agent, judges from these.
class CoachBoard
  # The latest journal entries the board shows; GET /api/coach/notes pages
  # through the rest.
  LATEST = 10

  def initialize(today: Time.zone.today)
    @today = today
  end

  # Monday to Sunday of today's week.
  def week = (@today - (@today.cwday - 1))..(@today - (@today.cwday - 7))

  # The newest note of a kind (status or focus), or nil.
  def current(kind)
    @current ||= {}
    @current.key?(kind) ? @current[kind] : (@current[kind] = notes.of_kind(kind).newest_first.first)
  end

  def open_concerns = notes.open_concerns.newest_first.all

  def goals = Goal.active.in_order.all
  def proposals = Goal.proposed.order(:id).all
  # Proposals the user turned down, which an agent doesn't propose again.
  def dismissed = Goal.dismissed.order(:id).all

  def week_sessions = Session.summarized.where(date: week).in_order.all
  def week_activities = Activity.where(date: week).in_order.all
  # The routines with days this week, and those days, read against the
  # board's today.
  def week_routines = @week_routines ||= RoutineCalendar.new(week, today: @today)
  def week_notes = notes.on_days(week).all

  # The journal: every note but the current status and focus and the open
  # concerns (shown above it), newest first. The status and focus they
  # replaced, and the concerns resolved, are here.
  def journal_notes = notes.journal.newest_first

  def journal = latest_journal.first

  # The journal's latest entries, and the `before` of its next page (nil
  # when there is none), as GET /api/coach/notes?journal=true pages it.
  def latest_journal
    @latest_journal ||= begin
      page = journal_notes.limit(LATEST + 1).all
      page.size > LATEST ? [page.first(LATEST), page[LATEST - 1].id] : [page, nil]
    end
  end

  def as_json(*)
    {
      today: @today.iso8601,
      goals:, proposals:,
      status: with_replaced("status"),
      focus: with_replaced("focus"),
      concerns: open_concerns,
      notes: journal,
      notes_before: latest_journal.last,
      week: {
        from: week.begin.iso8601, to: week.end.iso8601,
        sessions: week_sessions, activities: week_activities, notes: week_notes,
        routines: week_routines.routines, routine_days: week_routines.days
      }
    }
  end

  private

  def notes = CoachNote.eager(:activity, session: :workout)

  # The current note of a kind, naming the one before it (the one it replaced).
  def with_replaced(kind)
    latest = current(kind) or return
    before = CoachNote.of_kind(kind).where { id < latest.id }.newest_first.first
    latest.as_json.merge(replaces: before && { id: before.id, created_at: before.created_at })
  end
end
