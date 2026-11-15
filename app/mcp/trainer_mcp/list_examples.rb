module TrainerMcp
  class ListExamples < Tool
    description <<~TEXT.squish
      The example programs the user can import as their own (import_example): each with its workouts and
      their minutes (a main workout's own, without its warm-up and cool-down), the equipment its steps need
      (gear, each marked owned or not), how many of its exercises need gear the user lacks
      (missing_exercises: 0 fits their gear) and whether the user has imported it already. A quick start for someone with no workouts yet, or a
      base to change with update_workout once imported.
    TEXT
    annotations(title: "List example programs", **READ_ONLY)

    def self.answer
      library = Example.library
      owned = Equipment.owned.select_map(:slug)
      { examples: Example.all.map { it.as_json(library, owned:) } }
    end
  end
end
