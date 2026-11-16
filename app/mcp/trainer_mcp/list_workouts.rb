# frozen_string_literal: true

module TrainerMcp
  class ListWorkouts < Tool
    description <<~TEXT.squish
      Every workout, by program: the programs imported from examples, and then the user's own and
      assistant-made workouts under "My workouts". Each with its id, kind (warmup,
      workout or cooldown), the exercises and equipment it holds, its minutes with its warm-up and
      cool-down (`framed_minutes`), when it was last done and whether Today offers it next when
      nothing is planned (`up_next`). get_workout has the blocks and steps.
    TEXT
    annotations(title: "List workouts", **READ_ONLY)

    def self.answer
      { programs: compact(Workout.catalog) }
    end
  end
end
