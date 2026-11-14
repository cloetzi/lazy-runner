# What every model shares: Sequel::Model with the plugins the app leans on,
# validation messages worded as the API has always given them ("Reps must be
# greater than 0"), and a lookup by id that names what it looked for.
#
# An anonymous subclass first, so Sequel doesn't look for a `records` table;
# reopened below as a plain class, so its constants (NotFound, MESSAGES)
# resolve here and a model can't shadow them by defining its own.
Record = Class.new(Sequel::Model)

class Record
  # A value that can't be typecast (reps: "ten") stays as given, for the
  # validations to name, instead of raising on assignment. after_validation
  # refuses whatever no validation named.
  self.raise_on_typecast_failure = false

  plugin :timestamps, update_on_create: true
  plugin :validation_helpers
  # Checks only some writes run, such as a workout being ready to run.
  plugin :validation_contexts
  # What changed in a save, for hooks that act on a change.
  plugin :dirty
  # An association read on one record of a list loads it for the whole list.
  plugin :tactical_eager_loading
  # `eager` holds for first, with_pk and each too, not only for all.
  plugin :eager_each
  plugin :association_dependencies
  # A new record starts with the column defaults, as a row inserted without
  # them would.
  plugin :defaults_setter
  # find_or_new: the record matching, else a new one with those values.
  plugin :update_or_create

  # Asked for by id, and there is none. One class for every model: rescue
  # Record::NotFound.
  class NotFound < StandardError
    attr_reader :resource, :id

    def initialize(model, id, message = "#{model} #{id} not found")
      @resource = model.to_s.underscore
      @id = id
      super(message)
    end
  end

  # Errors as people read them: "Reps must be greater than 0", and a
  # problem with the whole record (`:base`) on its own.
  class Errors < Sequel::Model::Errors
    def full_message(attribute, message)
      return message if attribute == :base

      "#{attribute.to_s.delete_suffix("_id").tr("_", " ").capitalize} #{message}"
    end
  end

  # The validation_helpers messages the API words as it always has.
  MESSAGES = {
    presence: "can't be blank",
    includes: "is not included in the list",
    unique: "has already been taken",
    format: "is invalid"
  }.freeze

  # The strings a boolean column reads as false, as the API has always taken
  # them; any other string is true and an empty one is nil.
  FALSE_STRINGS = %w[0 f false off].freeze

  # An id as a client may send it: an Integer, or text that is one ("9", not
  # "9.0" or " 9"); nil otherwise.
  def self.id(value) = value.is_a?(Integer) ? value : Integer(value.to_s, 10, exception: false)

  def self.boolean(value)
    return value unless value.is_a?(String) || value.is_a?(Symbol)
    return if value.empty?

    !FALSE_STRINGS.include?(value.to_s.downcase)
  end

  dataset_module do
    # The record with this id, raising NotFound, so a client hears what was
    # missing.
    def find!(id)
      key = Record.id(id)
      (key && with_pk(key)) || raise(NotFound.new(model, id))
    end
  end

  # A model of one user's records. Every query on it is the signed-in
  # user's (Current.user!), whatever builds it: the model's dataset keeps to
  # `user_id = <the signed-in user>`, worked out each time a query runs, and
  # raises Current::Missing when nobody is signed in, so a query that forgot
  # whose records it wants fails rather than reading everyone's. Opting out
  # is explicit: `everyone` for maintenance across users (the seed loader),
  # `of(user_id)` for a given user's.
  #
  # A table that belongs to a user through its parent names the column that
  # links it, and gives the parent's ids in a block: blocks are the user's
  # when their workout_id is among `Workout.select(:id)`, the user's
  # workouts. The block runs as each query is made, as the user is read,
  # so no SQL is kept with one user's id in it. A new record with a user_id is the signed-in
  # user's unless it says whose; one set through an association keyed by
  # the user (`session.workout = workout`) takes it from the other side.
  # Associations between two of a user's tables are keyed by user_id too, as
  # their composite foreign keys are
  # (db/migrate/20261102000003_scope_data_by_user.rb).
  def self.per_user(parent_key = nil, &parents)
    column = Sequel[table_name][:user_id]
    filter =
      if parent_key
        Sequel::SQL::BooleanExpression.new(:IN, Sequel[table_name][parent_key], Sequel.delay(&parents))
      else
        { column => Sequel.delay { Current.user!.id } }
      end
    set_dataset(dataset.where(filter))
    define_singleton_method(:everyone) { dataset.unfiltered }
    define_singleton_method(:of) { |user_id| dataset.unfiltered.where(column => user_id) } if columns.include?(:user_id)
    include PerUser if columns.include?(:user_id)
  end

  # What an agent writes (`created_by: llm`) carries its name: the name of
  # the API token it connected with (Current.agent_name, set for a token's
  # request or MCP call), so the app shows one name for it everywhere (#247).
  # A row written without a token has none, and the app shows its default.
  module AgentSigned
    def before_create
      self.agent_name ||= Current.agent_name if created_by == "llm"
      super
    end
  end

  module PerUser
    def before_validation
      self.user_id ||= Current.user!.id if new?
      super
    end

    # A record is saved or deleted only by its own user: code that works on
    # someone else's records runs as them (`Current.set(user:)`), so one
    # operation never mixes two users' data.
    def before_save
      own_user!
      super
    end

    def before_destroy
      own_user!
      super
    end

    # Its own row, within its user: an update, delete or refresh names its user_id.
    def this = @this ||= model.instance_dataset.unfiltered.where(pk_hash.merge(Sequel[model.table_name][:user_id] => user_id))

    private

    def own_user!
      return if user_id == Current.user!.id

      raise Current::Mismatch, "this #{model} is another user's"
    end
  end

  # JSON columns, read and written as Ruby values: `defaults` maps each to
  # what a new record starts with. A value changed in place (an array
  # appended to) is saved too.
  def self.json_columns(defaults)
    plugin :serialization, :json, *defaults.keys
    plugin :serialization_modification_detection
    defaults.each { |column, value| default_values[column] = JSON.generate(value) unless value.nil? }
  end

  # For a many_to_many with association_pks: setting the ids writes the join
  # rows only when they change (so an unchanged record stays unsaved), and
  # forgets the loaded records, so the next read sees the new ones.
  def self.pks_setter(association, pks = :"#{association}_pks")
    define_method(:"#{pks}=") do |ids|
      next if !new? && ids.map(&:to_i).sort == public_send(pks).sort

      super(ids)
      associations.delete(association)
    end
  end

  # A row deleted since it was loaded (another device erased the session)
  # is not found, as a lookup a moment later would say.
  %i[save delete destroy refresh].each do |method|
    define_method(method) do |*args, **opts, &block|
      super(*args, **opts, &block)
    rescue Sequel::NoExistingObject
      raise NotFound.new(self.class, pk)
    end
  end

  # Writes `changes` straight to the row: no validation, no hooks, no
  # timestamps. For bookkeeping such as a day's numbering.
  def update_columns(changes)
    this.update(changes)
    changes.each { |column, value| values[column] = value }
    self
  end

  # Whether a save would write `column`, JSON columns included (dirty's
  # column_changed? sees only columns set through their setter).
  def changing?(column) = changed_columns.include?(column)

  # Raises Sequel::ValidationFailed unless valid, in `context` when given
  # (such as :publish).
  def validate!(context = nil)
    raise Sequel::ValidationFailed, self unless valid?(validation_context: context)

    self
  end

  # After the models' own validations: a value still not of its column's
  # type (a note sent as {"a": 1}, a date as "soon") is refused rather than
  # written, unless a validation already named the column. JSON columns have
  # no type here and take any value.
  def after_validation
    super
    columns = values.keys.reject { errors.on(it) }
    validates_schema_types(columns, message: "is invalid")
  end

  private

  def errors_class = Errors

  def default_validation_helpers_options(type)
    message = MESSAGES[type]
    message ? super.merge(message:) : super
  end

  # A finite number, worded as the API does: "is not a number", "must be an
  # integer", "must be greater than 0", "must be greater than or equal to
  # 0", "must be less than or equal to 20", "must be in 1..10".
  def validates_number(*columns, only_integer: false, greater_than: nil, at_least: nil, at_most: nil, within: nil, allow_nil: false)
    columns.each do |column|
      value = get_column_value(column)
      next if value.nil? && allow_nil

      problem =
        if !value.is_a?(Numeric) || !value.finite? then "is not a number"
        elsif only_integer && value != value.to_i then "must be an integer"
        elsif greater_than && value <= greater_than then "must be greater than #{greater_than}"
        elsif at_least && value < at_least then "must be greater than or equal to #{at_least}"
        elsif at_most && value > at_most then "must be less than or equal to #{at_most}"
        elsif within && !within.cover?(value) then "must be in #{within}"
        end
      errors.add(column, problem) if problem
    end
  end

  # A fraction (or infinity) for a whole-number column stays a Float, for
  # validates_number to refuse rather than cutting it to a whole number; a
  # boolean reads strings as Record.boolean does.
  def typecast_value(column, value)
    case db_schema.dig(column, :type)
    when :integer
      number = value.is_a?(String) ? Float(value, exception: false) : value
      return number if number.is_a?(Float) && !(number.finite? && number == number.to_i)
    when :boolean
      return Record.boolean(value) if value.is_a?(String) || value.is_a?(Symbol)
    end
    super
  end
end
