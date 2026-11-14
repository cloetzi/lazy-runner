module TrainerMcp
  class ProposeGoal < CoachTool
    description <<~TEXT.squish
      Propose a goal for the user to accept or dismiss on their Coach tab: a new one, or a change to an active goal
      (`replaces`, its id), which on accepting takes that goal's place. Only the user writes goals; you can only
      propose, with a reason grounded in what they told you or what the training shows. A title they dismissed
      can't be proposed again, and at most #{Goal::OPEN_PROPOSALS} proposals wait at once.
    TEXT
    input_schema(
      properties: {
        title: { type: "string", description: "The goal, short: Half marathon under 1:50." },
        reason: { type: "string", description: "Why you propose it, for the user to judge." },
        why: { type: "string", description: "Why the goal matters, as the user would put it." },
        target_date: { type: "string", format: "date", description: "When, YYYY-MM-DD." },
        replaces: { type: "integer", description: "The active goal this one would change." }
      },
      required: %w[title reason]
    )
    annotations(title: "Propose goal", **WRITES)

    def self.answer(title:, reason:, **rest)
      goal(Goal.propose!(title:, reason:, **rest))
    end
  end
end
