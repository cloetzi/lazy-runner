# frozen_string_literal: true

# What the user says about a day, for the coach to read beside a watch's
# numbers: the night that ended that morning (as Garmin dates sleep and
# overnight HRV) and how they felt that day. Each group is optional and
# written whole; nothing is derived from them.
#
# The API and the MCP tools name a group's fields as they read in it
# (`night: { sleep, drinks, tags, note }`, `day: { feeling, stress, sore,
# sore_areas, ill, note }`); FIELDS maps them to the columns.
#
# The user writes a group whole and clears it. An agent only fills fields
# left empty (`fill!`), today or up to AGENT_DAYS_BACK days back, and never
# changes or clears what the user logged.
class CheckIn < Record
  per_user
  json_columns night_tags: [], sore_areas: []

  GROUPS = %w[night day].freeze
  # A group's fields as the API names them, and their columns.
  FIELDS = {
    "night" => { sleep: :sleep, drinks: :drinks, tags: :night_tags, note: :night_note },
    "day" => { feeling: :feeling, stress: :stress, sore: :sore, sore_areas: :sore_areas, ill: :ill, note: :day_note }
  }.freeze
  # The column that says who logged a group.
  BY = { "night" => :night_by, "day" => :day_by }.freeze
  CHOICES = {
    sleep: %w[poor ok good],
    drinks: %w[none 1-2 3+],
    feeling: %w[rough ok good],
    stress: %w[low normal high],
    sore: %w[no a_bit a_lot]
  }.freeze
  NIGHT_TAGS = %w[late_to_bed ate_late travelling woke_a_lot].freeze
  SORE_AREAS = %w[knees calves achilles shins hamstrings hips back other].freeze
  # A group's value when nothing was said.
  EMPTY = { night_tags: [], sore_areas: [], ill: false }.freeze
  NOTE_LENGTH = 500
  # How far back an agent may log what the user told it.
  AGENT_DAYS_BACK = 7

  dataset_module do
    order :in_order, :date
  end

  # The day `date` may not be after: the sender's (see Current.today),
  # unless set to another day.
  attr_writer :today

  def today
    @today || Current.today
  end

  # The user's check-in on a day, or a new one for it.
  def self.on(date) = first(date:) || new(date:)

  # Writes one group of a day whole, from a Hash of its fields as the API
  # names them (strings or symbols): a field left out is cleared. A group
  # with nothing in it is cleared, and a day with neither group goes.
  # Answers the check-in, or nil when the day has none left.
  def self.write!(date, group, fields, today: Current.today)
    group = group!(group)
    db.transaction(savepoint: true) do
      check_in = on(date!(date))
      check_in.today = today
      check_in.write_group(group, fields)
      check_in.keep_or_delete
    end
  end

  # Clears one group of a day. Answers what is left, or nil.
  def self.clear!(date, group, today: Current.today)
    write!(date, group, {}, today:)
  end

  # An agent's write: the fields it sends fill those still empty, in either
  # group, and the rest are kept as they are. Answers the check-in (or nil
  # when nothing was sent), the fields filled and the fields kept, each as
  # "night.sleep".
  def self.fill!(date, night: nil, day: nil, today: Current.today)
    date = date!(date)
    if date < today - AGENT_DAYS_BACK
      raise Problem, "a check-in can be logged from #{(today - AGENT_DAYS_BACK).iso8601} to today, #{today.iso8601}"
    end

    db.transaction(savepoint: true) do
      check_in = on(date)
      check_in.today = today
      filled, kept = check_in.fill_groups({ "night" => night, "day" => day })
      [check_in.keep_or_delete, filled, kept]
    end
  end

  # The arguments can't be read as a check-in.
  class Problem < Refusal
    refuses_with :unprocessable_content, "invalid"
  end

  def self.group!(group)
    group = group.to_s
    GROUPS.include?(group) ? group : raise(Problem, "group must be night or day")
  end

  def self.date!(value)
    DateRange.date(value, :date)
  rescue DateRange::Invalid => error
    raise Problem, error.message
  end
  private_class_method :date!

  def empty?(group) = FIELDS.fetch(group).values.all? { blank_value?(it) }

  def write_group(group, fields)
    fields = known_fields(group, fields)
    # What the user logged is theirs.
    if self[BY.fetch(group)] == "manual"
      Record.user_only!("the #{group} of #{date.iso8601} is the user's; an agent only fills what is empty")
    end

    FIELDS.fetch(group).each { |name, column| put(column, normal(column, fields[name])) }
    signed(group, Current.agent_name ? "llm" : "manual")
  end

  def fill_groups(groups)
    filled = []
    kept = []
    groups.each do |group, fields|
      next if fields.nil?

      fields = known_fields(group, fields)
      before = empty?(group)
      fields.each do |name, value|
        column = FIELDS.fetch(group).fetch(name)
        value = normal(column, value)
        next if blank_value_for?(column, value)

        if blank_value?(column)
          put(column, value)
          filled << "#{group}.#{name}"
        else
          kept << "#{group}.#{name}"
        end
      end
      signed(group, "llm") if before && !empty?(group)
    end
    if filled.any?
      self.agent_name = Current.agent_name
      self.agent_at = Time.now
    end
    [filled, kept]
  end

  # Saves the check-in, or deletes it when both groups are empty.
  def keep_or_delete
    if GROUPS.all? { empty?(it) }
      # A value that couldn't be read leaves the group empty, but is still wrong.
      raise Sequel::ValidationFailed, self if @ill_unread && !valid?

      destroy unless new?
      return nil
    end
    new? ? save : save_changes
    self
  end

  def group_json(group)
    return nil if empty?(group)

    FIELDS.fetch(group).to_h { |name, column| [name, get(column)] }.merge(logged_by: self[BY.fetch(group)])
  end

  def as_json(*)
    { date: date.iso8601, night: group_json("night"), day: group_json("day"), agent_name:, agent_at:, updated_at: }
  end

  def validate
    super
    validates_presence :date
    CHOICES.each { |column, values| validates_includes values, column, allow_nil: true, message: "must be one of #{values.join(", ")}" }
    errors.add(:ill, "must be true or false") if @ill_unread
    { night_tags: NIGHT_TAGS, sore_areas: SORE_AREAS }.each do |column, values|
      list = get(column)
      next if list.is_a?(Array) && (list - values).empty?

      errors.add(column, "must be a list of #{values.join(", ")}")
    end
    %i[night_note day_note].each do |column|
      validates_max_length NOTE_LENGTH, column, allow_nil: true, message: "is longer than #{NOTE_LENGTH} characters"
    end
    errors.add(:date, "must not be after today") if date.is_a?(Date) && date > today
  end

  private

  # A group's fields by symbol, refusing one it doesn't have.
  def known_fields(group, fields)
    fields = fields.to_h.transform_keys(&:to_sym)
    unknown = fields.keys - FIELDS.fetch(group).keys
    raise Problem, "#{group} has no #{unknown.join(", ")}; it takes #{FIELDS.fetch(group).keys.join(", ")}" if unknown.any?

    fields
  end

  def signed(group, by)
    self[BY.fetch(group)] = empty?(group) ? nil : by
  end

  # Text trimmed (blank is nil), a list without repeats, `ill` false when
  # left out. Anything else is kept as sent, for validation to refuse.
  def normal(column, value)
    if column == :ill && !(value.nil? || value == true || value == false)
      @ill_unread = true
      return false
    end

    case value
    when nil then EMPTY.fetch(column, nil)
    when String then value.strip.presence || EMPTY.fetch(column, nil)
    when Array then value.map { it.is_a?(String) ? it.strip : it }.uniq
    else value
    end
  end

  def blank_value?(column) = blank_value_for?(column, get(column))

  # A column as the model reads it: the lists parsed, not their JSON.
  def get(column) = public_send(column)
  def put(column, value) = public_send(:"#{column}=", value)

  def blank_value_for?(column, value)
    value.nil? || value == EMPTY.fetch(column, :none)
  end
end
