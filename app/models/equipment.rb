# frozen_string_literal: true

# The equipment catalogue, seeded and shared: exercises name the equipment
# they need, so the library and the builder can keep to what is at hand.
# What each user owns of it, which weights and in which unit, is theirs
# (UserEquipment); `unit` here says only whether an item comes in set
# weights, and is no longer the unit anyone's weights are in.
#
# An `any_weight` item is the generic "weight" an exercise needs when any
# dumbbell or kettlebell will do: nobody owns it as such, but it
# counts as owned with any gear in set weights, and its weights are all of
# theirs.
class Equipment < Record
  # Stands in for an any_weight item in Equipment.fixed: the rows of every
  # owned item in set weights, whose weights it has between them.
  AnyWeight = Data.define(:rows) do
    def weights_in = rows.flat_map(&:weights_in)
  end

  # Slugs that name nothing in the catalogue.
  class Unknown < StandardError
    attr_reader :slugs

    def initialize(slugs)
      @slugs = slugs
      super("unknown equipment: #{slugs.join(", ")}")
    end
  end

  many_to_many :exercises, join_table: :exercise_equipment
  many_to_many :steps, join_table: :step_equipment

  dataset_module do
    # In the catalogue; a retired item left the seeds while users still had it.
    where :current, retired: false
    order :in_order, :position

    # Gear in the catalogue that comes in set weights, any_weight items aside.
    def weighted = current.exclude(unit: nil).where(any_weight: false)

    # What the signed-in user owns, with the any_weight items once they own
    # some gear in set weights.
    def owned
      mine = UserEquipment.where(owned: true).select(:equipment_id)
      current.where(Sequel[id: mine] | (Sequel[any_weight: true] & model.weighted.where(id: mine).exists))
    end
  end

  # What `owned`, or a comma-separated list of slugs (or an array), names:
  # the owned equipment, or the items listed (none for an empty list,
  # bodyweight), with the any_weight items when gear in set weights is among
  # them. Raises Unknown for slugs that name nothing.
  def self.named(given)
    return owned.all if given == "owned"

    slugs = (given.is_a?(Array) ? given : given.to_s.split(",")).map { it.to_s.strip }.reject(&:empty?).uniq
    found = current.where(slug: slugs).all
    unknown = slugs - found.map(&:slug)
    raise Unknown, unknown if unknown.any?

    # Dumbbells or a kettlebell do for an exercise that needs just a weight.
    found += current.where(any_weight: true).exclude(id: found.map(&:id)).all if found.any? { it.unit && !it.any_weight }
    found
  end

  # The signed-in user's rows, by equipment id.
  def self.inventory = UserEquipment.as_hash(:equipment_id)

  # The catalogue in order, each item with what the signed-in user has of it.
  def self.listed
    mine = inventory
    current.in_order.all.map { it.as_json(it.any_weight ? it.any_weight_row(mine) : mine[it.id]) }
  end

  # The signed-in user's owned items that come in set weights (dumbbells,
  # kettlebells), by slug: their rows, which give the weights (`weights_in`).
  # With some, each any_weight item too (AnyWeight).
  def self.fixed
    rows = UserEquipment.where(owned: true, equipment_id: weighted.select(:id)).eager(:equipment).all
      .select { it.weights.any? }.sort_by { it.equipment.position }.to_h { [it.equipment.slug, it] }
    return rows if rows.empty?

    rows.merge(current.where(any_weight: true).select_map(:slug).to_h { [it, AnyWeight.new(rows.values)] })
  end

  # The weights a stepper moves through for something done with `slugs`, in
  # `unit`: those owned of the first fixed-weight item among them. Nil when
  # there is none, to step by band instead.
  def self.allowed_for(slugs, unit, fixed = self.fixed)
    item = slugs.filter_map { fixed[it] }.first
    item&.weights_in&.map { Weights.convert(it, unit)[:value] }&.uniq&.sort
  end

  # For something done with the generic weight: its slug and, for each weight
  # the stepper moves through (in `unit`), the owned item that carries it
  # (the first in catalogue order, as `carrying` picks), so the player can
  # name what to pick up as the weight steps. Nil for anything else.
  def self.any_weight_for(slugs, unit, fixed = self.fixed)
    slug = slugs.find { fixed[it] }
    item = fixed[slug]
    return unless item.is_a?(AnyWeight)

    carriers = item.rows.flat_map { |row| row.weights_in.map { [Weights.convert(it, unit)[:value], row.equipment.slug] } }
    { slug:, carriers: carriers.uniq(&:first).sort_by(&:first).map { |value, equipment| { value:, equipment: } } }
  end

  # The slug of the first owned item (in catalogue order) that has `weight`,
  # leaving out `except`: the gear to pick up for it.
  def self.carrying(weight, fixed = self.fixed, except: nil)
    fixed.find { |slug, row| slug != except && row.is_a?(UserEquipment) && row.weights_in.any? { Weights.same?(it, weight) } }&.first
  end

  # Every owned set weight, in `unit`, for snapping a converted weight.
  def self.owned_weights(unit)
    fixed.values.grep(UserEquipment).flat_map(&:weights_in).map { Weights.convert(it, unit)[:value] }.uniq.sort
  end

  # What an any_weight item reads as, a row of its own nobody saves: owned
  # with any owned gear in set weights, and their weights in its unit
  # (UserEquipment.unit_of).
  def any_weight_row(mine = Equipment.inventory)
    owned = mine.values_at(*Equipment.weighted.select_map(:id)).compact.any?(&:owned)
    unit = UserEquipment.unit_of(self)
    UserEquipment.new(owned:, weights: Equipment.allowed_for([slug], unit) || [], unit:)
  end

  # With `mine`, the user's row for it (none: not owned). `unit` is the
  # user's for this item (UserEquipment.unit_of), nil for gear without weights.
  def as_json(mine = nil)
    mine = nil unless mine.is_a?(UserEquipment)
    {
      id:, slug:, name:, owned: mine&.owned || false, weights: mine&.weights || [],
      unit: unit && (mine&.unit || UserEquipment.unit_of(self)), any_weight:
    }
  end

  def validate
    super
    validates_presence %i[slug name]
    validates_unique :slug
    validates_includes ExerciseWeight::UNITS, :unit, allow_nil: true
  end
end
