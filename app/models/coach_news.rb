# frozen_string_literal: true

# What agents did since the user last looked at Coach, for the
# "Since you last looked" card and the dot on the Coach tab: the changes they
# made to the plan (not taken back), the notes they wrote, the goals they
# proposed and the activities they copied. "Since" is when the user last
# marked it seen (`users.coach_seen_at`), else the last two weeks.
class CoachNews
  DEFAULT_DAYS = 14

  attr_reader :since

  # `today` is the device's, which undo counts from; the two weeks are the
  # server's, as GET /api/me counts them.
  def initialize(user, today: Current.today)
    @today = today
    @since = user.coach_seen_at || (@today - DEFAULT_DAYS).in_time_zone.to_time
  end

  # How many things are news: the dot's count.
  def count = [changes, notes, goals, activities].sum(&:count)

  def as_json(*)
    changes = self.changes.eager(:session).all
    lookup = PlanChange::Lookup.new(changes, today: @today, sessions: changes.filter_map(&:session))
    notes = self.notes.all
    goals = self.goals.all
    copied = self.copied
    newest = [*changes, *notes, *goals].map(&:created_at) + copied.map { it[:created_at] }
    {
      # To the microsecond, so marking it seen up to it covers the newest.
      since:, latest: newest.max&.iso8601(6),
      changes: changes.map { it.as_json(lookup:) },
      notes:, goals:,
      activities: copied
    }
  end

  # The activities agents copied, by the agent: how many, their first and
  # last day, and where they came from.
  def copied
    sources = activities.exclude(source: nil).distinct.select_map(%i[agent_name source]).group_by(&:first)
    # Aggregates come back untyped on SQLite: dates and times as text.
    activities.group(:agent_name).order(:agent_name)
      .select(:agent_name) { [count.function.*.as(:count), min(:date).as(:from), max(:date).as(:to), max(:created_at).as(:newest)] }
      .naked.all.map do |row|
      {
        agent_name: row[:agent_name], count: row[:count], from: row[:from].to_s, to: row[:to].to_s,
        sources: (sources[row[:agent_name]] || []).map(&:last).sort, created_at: Activity.db.to_application_timestamp(row[:newest])
      }
    end
  end

  # Each newest first.
  def changes = PlanChange.by_agent.not_undone.where(made_since).newest_first
  def notes = CoachNote.by_agent.where(made_since).newest_first.eager(:replies)
  def goals = Goal.proposed.where(created_by: "llm").where(made_since).order(Sequel.desc(:id))
  def activities = Activity.where(created_by: "llm").where(made_since)

  private

  def made_since = Sequel[:created_at] > @since # rubocop:disable Naming/PredicateMethod -- a Sequel condition
end
