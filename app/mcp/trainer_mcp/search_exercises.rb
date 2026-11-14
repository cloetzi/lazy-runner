module TrainerMcp
  class SearchExercises < Tool
    description <<~TEXT.squish
      Find exercises in the library, which is fixed: only these exercises exist, each with its
      animation and cues. By default keeps to what can be done with the equipment the user owns.
      Each exercise comes with its slug and id, body areas (the first is the main one), movement
      pattern, category, whether it is done one side at a time (unilateral: reps and seconds count per side) or alternates sides within a set (alternating: reps count both sides together), the equipment it needs,
      its default reps or seconds and its cues. get_exercise has the full instructions and the
      remembered weight.
    TEXT
    input_schema(
      properties: {
        text: {
          type: "string",
          description: "Words to find in the name, slug or cues, such as \"squat\" or \"calf ankle\": the exercises with " \
                       "every word, else those with any of them, most words first."
        },
        area: { type: "string", enum: Exercise::AREAS, description: "Body area worked." },
        pattern: { type: "string", enum: Exercise::PATTERNS, description: "Movement pattern trained." },
        category: { type: "string", enum: Exercise::CATEGORIES },
        equipment: {
          type: "string",
          description: "\"owned\" (default) keeps to what the user owns; \"all\" lists every exercise; " \
                       "a comma-separated list of equipment slugs keeps to exactly that (dumbbell or kettlebell " \
                       "also finds exercises that need just a weight), and \"none\" to bodyweight."
        }
      }
    )
    annotations(title: "Search exercises", **READ_ONLY)

    def self.answer(text: nil, area: nil, pattern: nil, category: nil, equipment: "owned")
      exercises = Exercise.current.eager(:equipment).order(:name)
      exercises = exercises.doable_with(equipment_filter(equipment)) unless equipment == "all"
      exercises = exercises.where(pattern:) if pattern
      exercises = exercises.where(category:) if category
      exercises = exercises.all
      exercises.select! { it.areas.include?(area) } if area
      exercises = matching(exercises, text) if text.present?

      {
        count: exercises.size,
        exercises: exercises.map do
          compact(
            id: it.id, slug: it.slug, name: it.name, category: it.category, areas: it.areas, pattern: it.pattern,
            unilateral: it.unilateral, alternating: it.alternating, equipment: it.equipment_slugs,
            default_reps: it.default_reps, default_seconds: it.default_seconds, cues: it.cues
          )
        end
      }
    end

    def self.equipment_filter(given)
      Equipment.named(given.blank? ? "owned" : given.sub(/\Anone\z/, ""))
    rescue Equipment::Unknown => error
      raise Problem, "#{error.message}; list_equipment lists the slugs"
    end

    # Words too common to find anything with on their own.
    COMMON = %w[a an and at for in of on or the to with].freeze

    # The exercises with every word of `text`; else those with a word that
    # starts one of theirs (common words left out), the ones with most words
    # first.
    def self.matching(exercises, text)
      words = text.downcase.tr("-", " ").split.uniq
      haystacks = exercises.to_h { [it.id, [it.name, it.slug.tr("-", " "), *it.cues].join(" ").downcase] }
      all = exercises.select { |exercise| words.all? { haystacks[exercise.id].include?(it) } }
      return all if all.any?

      patterns = (words - COMMON).map { /\b#{Regexp.escape(it)}/ }
      hits = haystacks.transform_values { |haystack| patterns.count { haystack.match?(it) } }
      exercises.select { hits[it.id].positive? }.sort_by.with_index { |exercise, index| [-hits[exercise.id], index] }
    end
  end
end
