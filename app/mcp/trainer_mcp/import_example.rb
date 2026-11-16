# frozen_string_literal: true

module TrainerMcp
  class ImportExample < Tool
    description <<~TEXT.squish
      Import an example program (list_examples) into the user's programs, marked `source: llm`: its
      workouts become ordinary ones of theirs that update_workout can change. Each step's weight snaps to
      the nearest weight the user owns of its gear, and is left out when they own none of it; steps
      needing gear they lack are kept. A program imported before is refused unless `copy` is true, which
      adds another copy. Answers with the program and its workouts (id, kind, title, minutes); get_workout
      and list_workouts have the rest.
    TEXT
    input_schema(
      properties: {
        example: { type: "string", description: "The example's slug, from list_examples." },
        copy: { type: "boolean", description: "Import it again although it was imported before." }
      },
      required: %w[example]
    )
    annotations(title: "Import example program", **WRITES)

    def self.answer(example:, copy: false)
      program = Example.find!(example).import!(copy:, source: "llm")
      compact(Program.eager(workouts: { blocks: :steps }).with_pk(program.id).as_json)
    end
  end
end
