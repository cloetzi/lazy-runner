# frozen_string_literal: true

# A run, ride, hike or any other sport, as it happened: logged by hand in the
# app, or sent by a script or an agent with the numbers its source gave.
# Nothing derived is kept (no pace, load or score): only the user, or a
# coach they ask, judges how it went.
#
# `date` is the sender's own day the activity started on, never worked out
# from `started_at` in the server's time zone, and never later than the
# sender's today. Distances and climb are in metres, times in seconds; the
# distance unit setting only changes how they are shown. `sport` is free
# text, kept trimmed and lowercase; the PWA gives the words it knows an icon.
#
# One that came from somewhere else is known by `source` + `external_id`
# (within its user): sending the pair again updates it (see `log!`). One
# made in the app is known by its `client_ref`, so a retried create finds it.
class Activity < Record
  per_user
  include AgentSigned

  # What a client may send for an activity.
  FIELDS = %i[date started_at sport title moving_seconds elapsed_seconds distance_m climb_m avg_hr max_hr rpe note source external_id
              routine_id routine_date].freeze
  # What a change may touch: where it came from stays.
  CHANGEABLE = (FIELDS - %i[source external_id]).freeze
  NUMBERS = %i[moving_seconds elapsed_seconds distance_m climb_m avg_hr max_hr].freeze
  # The person's own: an entry resent from its source fills them only while
  # they are empty, so an import never overwrites what the person wrote.
  PERSONAL = %i[rpe note].freeze
  CREATORS = %w[manual llm].freeze
  # The most activities logged in one request.
  BATCH_LIMIT = 500
  MAX_LENGTHS = { sport: 40, title: 200, source: 100, external_id: 200, client_ref: 100, note: 2000 }.freeze

  # One entry of a list that can't be logged; nothing of the list was.
  # `fields` names it by its place in the list: "activities[3].distance_m".
  class EntryInvalid < StandardError
    attr_reader :index, :fields

    def initialize(index, fields, messages)
      @index = index
      @fields = fields.transform_keys { |field| field == :base ? "activities[#{index}]" : "activities[#{index}].#{field}" }
      super("activities[#{index}]: #{messages.join(", ")}")
    end
  end

  dataset_module do
    # By day, then by when each started (as logged when no start was given).
    order :in_order, :date, Sequel.function(:coalesce, :started_at, :created_at), :id

    def of_sport(sport) = where(sport: Activity.sport(sport))
  end

  # "Trail  Run ", "TrailRun" or "trail_run" as kept: "trail run". Another
  # app's sport names (TrailRun, mountain_bike) become plain words, so they
  # read, and match, as typed ones do.
  def self.sport(text)
    return text unless text.is_a?(String)

    text.gsub(/([a-z])([A-Z])/, '\1 \2').tr("_", " ").strip.downcase.gsub(/\s+/, " ")
  end

  # Logs one activity, from a Hash of FIELDS (and `client_ref`), and answers
  # it with what happened: :created, :updated, :known for a `client_ref`
  # seen before, or :kept for the user's own activity that an agent's entry
  # names (both answered unchanged).
  #
  # An entry whose `source` + `external_id` the user already has updates
  # that activity: the fields it sends are written, the ones it leaves out
  # (or sends as null) are kept, and `rpe` and `note` only while empty.
  # `today` is the sender's, which `date` may not be after.
  # `known` is a Known of the activities already looked up, which a list
  # passes so each entry needn't be looked up on its own.
  def self.log!(entry, today: Current.today, created_by: "manual", known: nil)
    attempts = 0
    begin
      db.transaction(savepoint: true) { upsert(fields(entry), today:, created_by:, known:) }
    rescue Sequel::UniqueConstraintViolation
      # A concurrent write of the same pair or client_ref got there first:
      # the second look, at the database, finds it.
      attempts += 1
      known = nil
      retry if attempts == 1
      raise
    end
  end

  # The activities a list of entries names, read in a query or two up front:
  # by `client_ref`, and by `source` + `external_id`. One logged from the
  # list is added, so a later entry naming it finds it.
  class Known
    def initialize(entries)
      refs = entries.filter_map { it[:client_ref] if it[:client_ref].is_a?(String) }.uniq
      pairs = entries.select { it[:source].is_a?(String) && it[:external_id].is_a?(String) }
      sources = pairs.group_by { it[:source] }.map { |source, list| { source:, external_id: list.map { it[:external_id] }.uniq } }
      # One object a row, whichever key finds it, so a change made through
      # one is seen through the other.
      rows = {}
      read = ->(dataset) { dataset.all.map { rows[it.id] ||= it } }
      @by_ref = refs.empty? ? {} : read.call(Activity.where(client_ref: refs)).to_h { [it.client_ref, it] }
      @by_pair = sources.empty? ? {} : read.call(Activity.where(Sequel.|(*sources))).to_h { [[it.source, it.external_id], it] }
    end

    def by_ref(ref) = @by_ref[ref]
    def by_pair(source, external_id) = @by_pair[[source, external_id]]

    def add(activity)
      @by_ref[activity.client_ref] = activity if activity.client_ref
      @by_pair[[activity.source, activity.external_id]] = activity if activity.source && activity.external_id
    end
  end

  # Logs a list of activities, all or nothing, answering each in the order
  # given with what happened to it, as `log!` does. An entry that appears twice (the same source and external_id) is
  # logged once, the later one's fields winning. Raises EntryInvalid for the
  # first entry that can't be logged.
  def self.log_all!(entries, today: Current.today, created_by: "manual")
    raise ArgumentError, "log at most #{BATCH_LIMIT} activities at once" if entries.size > BATCH_LIMIT

    # Each pair's entries merged, in the order its first one came, which a
    # problem names it by.
    merged = {}
    keys = entries.each_with_index.map do |entry, index|
      unless entry.is_a?(Hash)
        merged[index] = { invalid: true, index: }
        next index
      end

      entry = fields(entry)
      source, external_id = entry.values_at(:source, :external_id)
      key = source.is_a?(String) && external_id.is_a?(String) ? [source, external_id] : index
      first = merged[key]
      merged[key] = first ? first.merge(entry: first[:entry].merge(entry.compact)) : { entry:, index: }
      key
    end

    db.transaction do
      known = Known.new(merged.values.filter_map { it[:entry] unless it[:invalid] })
      logged = merged.transform_values do |item|
        raise EntryInvalid.new(item[:index], { base: ["must be an object"] }, ["must be an object"]) if item[:invalid]

        log!(item[:entry], today:, created_by:, known:)
      rescue Sequel::ValidationFailed => error
        raise EntryInvalid.new(item[:index], error.errors.to_h, error.errors.full_messages)
      end
      keys.map { logged.fetch(it) }
    end
  end

  # The FIELDS (and client_ref) of a Hash with String or Symbol keys, the
  # keys it is looked up by as text, trimmed, as they are kept. Any other
  # value for them (a list, an object) stays as sent, for validation to
  # refuse.
  def self.fields(entry)
    fields = entry.to_h.transform_keys(&:to_sym).slice(*FIELDS, :client_ref)
    %i[source external_id client_ref].each do |key|
      value = fields[key]
      # An id sent as a whole Float (18234567890.0) is that Integer's.
      value = value.to_i if value.is_a?(Float) && value.finite? && value == value.floor
      fields[key] = value.to_s.strip.presence if value.is_a?(String) || value.is_a?(Integer)
    end
    fields
  end

  def self.upsert(entry, today:, created_by:, known: nil)
    ref = entry[:client_ref]
    if ref.is_a?(String) && (seen = known ? known.by_ref(ref) : first(client_ref: ref))
      return [seen, :known]
    end

    source, external_id = entry.values_at(:source, :external_id)
    if source.is_a?(String) && external_id.is_a?(String)
      match = known ? known.by_pair(source, external_id) : first(source:, external_id:)
    end
    unless match
      created = create(**entry.slice(*FIELDS), client_ref: ref, created_by:, today:)
      known&.add(created)
      return [created, :created]
    end
    # The user's own (logged by hand, or by a sync before tokens wrote as
    # agents): an agent leaves it as it is, and the rest of a list goes on.
    return [match, :kept] if Current.agent_name && match.created_by != "llm"

    match.today = today
    changes = entry.slice(*CHANGEABLE).compact
    PERSONAL.each { changes.delete(it) if match[it].present? }
    match.set(changes)
    match.save_changes
    [match, :updated]
  end
  private_class_method :upsert

  # The day `date` may not be after: the sender's (see
  # Current.today), unless set to another day.
  attr_writer :today

  def today
    @today || Current.today
  end

  # A start as ISO 8601 text (or a Time); other text is refused rather than
  # guessed at.
  def started_at=(value)
    @started_at_unread = nil
    if value.is_a?(String)
      text = value.strip
      value = if text.empty?
                nil
              else
                begin
                  Time.iso8601(text)
                rescue StandardError
                  (@started_at_unread = text)
                end
              end
    end
    super(@started_at_unread ? nil : value)
  end

  def as_json(*)
    {
      id:, date: date.iso8601, started_at:, sport:, title:,
      moving_seconds:, elapsed_seconds:, distance_m:, climb_m:, avg_hr:, max_hr:,
      rpe:, note:, source:, external_id:, client_ref:, created_by:, agent_name:,
      routine_id:, routine_date: routine_date&.iso8601, created_at:, updated_at:
    }
  end

  def before_validation
    self.sport = Activity.sport(sport)
    %i[title note source external_id client_ref].each do |column|
      value = self[column]
      self[column] = value.strip.presence if value.is_a?(String)
    end
    # A start reported ahead of the server's clock happened just now.
    self.started_at = Time.now if started_at.is_a?(Time) && started_at > Time.now
    super
  end

  # What the user logged is theirs: an agent changes or deletes only the
  # activities it logged.
  def before_save
    theirs! unless new?
    super
  end

  def before_destroy
    theirs!
    super
  end

  def theirs!
    Record.user_only!("activity #{id} is the user's; an agent changes only the ones it logged") unless initial_value(:created_by) == "llm"
  end

  def validate
    super
    validates_presence %i[date sport]
    validates_includes CREATORS, :created_by
    validates_number(*NUMBERS, only_integer: true, at_least: 0, allow_nil: true)
    validates_number :rpe, only_integer: true, within: 1..10, allow_nil: true
    MAX_LENGTHS.each do |column, length|
      validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters"
    end
    errors.add(:started_at, "must be a time as ISO 8601") if @started_at_unread
    errors.add(:source, "can't be blank when external_id is given") if external_id.present? && source.blank?
    errors.add(:date, "must not be after today") if date.is_a?(Date) && (new? || column_changed?(:date)) && date > today
    routine_day_own if new? || column_changed?(:routine_id) || column_changed?(:routine_date)
  end

  private

  # Linked by hand to a day of one of the user's sport routines that shows
  # on or before its date, which no other activity fulfils: another user's
  # routine is not found.
  def routine_day_own
    return errors.add(:routine_date, "can't be blank with a routine") if routine_id && routine_date.nil?
    return errors.add(:routine_id, "can't be blank with a routine date") if routine_id.nil? && !routine_date.nil?
    return if routine_id.nil?

    routine = Record.id(routine_id) && Routine.with_pk(Record.id(routine_id))
    return errors.add(:routine_id, "is not found") unless routine
    return errors.add(:routine_id, "is a workout routine; its session fulfils it") if routine.workout_id
    return errors.add(:routine_date, "is not a day of the routine") unless routine_date.is_a?(Date) && routine.day?(routine_date)

    shows_on = RoutineDay.first(routine_id: routine.id, date: routine_date)&.moved_to || routine_date
    if date.is_a?(Date) && shows_on > date
      return errors.add(:routine_date, "shows on #{shows_on.iso8601}, after the activity; move the day first")
    end

    taken = Activity.where(routine_id: routine.id, routine_date:).exclude(id:)
    errors.add(:routine_date, "already has an activity linked") unless taken.empty?
  end
end
