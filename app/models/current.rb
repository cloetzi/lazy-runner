# frozen_string_literal: true

# Who the request is for: set from the session by ApplicationController.
# Rage keeps CurrentAttributes per fiber, so each request has its own. Code
# that runs outside a request (an MCP tool, the seed loader, a job) runs
# under `Current.set(user:)`. Model code reads the user only from here.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
  # What UserEquipment.unit_of reads, loaded once per request (or until the
  # user's gear or settings change): the user's unit and their gear's.
  attribute :gear_units
  # The name of the API token a request or an MCP tool call came with: what
  # the agent is called on what it writes (Record::AgentSigned, CoachNote).
  attribute :agent_name
  # How the plan changes made now are recorded (PlanChange): the id shared by
  # the changes of one request or tool call, the reason given for them, the
  # change an undo takes back, and whether to record nothing (a routine day
  # confirmed or made tentative again is a state, not a plan change).
  attribute :plan_batch, :plan_reason, :plan_undo, :plan_quiet

  class Missing < StandardError; end
  # A record saved or deleted while someone else is signed in.
  class Mismatch < StandardError; end

  # The user, or an error when nobody is signed in: for code that must never
  # run for nobody.
  def self.user! = user || raise(Missing, "no user is signed in")
end
