module Api
  class WorkoutsController < ApplicationController
    # Every workout, by program.
    # @description What each one holds (exercise names and `exercise_ids`,
    #   equipment), which main workout Today offers when nothing is planned
    #   (`up_next`), when each was `last_done`
    #   and its minutes with the warm-up and cool-down (`framed_minutes`).
    #   Workouts without a program (the user's own) come last, under
    #   "My workouts" (`id: null`). Archived workouts are left out.
    # @response 200 #/components/schemas/ProgramWorkoutsList
    def index
      render json: Workout.catalog
    end

    # The whole workout, with blocks and steps expanded.
    # @description Each step carries its resolved `target` (a remembered
    #   weight winning over the seed) and, when
    #   weighted, the owned weights to step through (`allowed_weights`), else
    #   the `weight_steps` bands apply. A step's `equipment` and
    #   `weights_held` are its own, null while it follows its exercise;
    #   `equipment_needed` is what it is done with. Also `source`, `editable`, its
    #   `warmup` / `cooldown` choice and the parts a session runs (`framed`).
    #   `changes` holds the latest edit an agent made to it, while nothing
    #   changed it since and it was not taken back, with whether POST
    #   /api/plan_changes/:id/undo can take it back (`undoable`).
    # @response 200 #/components/schemas/Workout
    # @response 404 #/components/responses/NotFound
    def show
      show_workout(params[:id])
    end

    # A new workout of the user's own, with its blocks and steps.
    # @description It stands alone, without a program, and is listed under
    #   "My workouts". `kind` is warmup, workout or cooldown; a main workout
    #   may pick a `warmup` and `cooldown` (a workout id, or "none"), and runs
    #   without them otherwise. `blocks` is the whole structure, as PUT
    #   /api/workouts/:id takes it. Nothing is written when any part is
    #   invalid: the 422 names each block and step at fault, and `fields` has
    #   each problem under its path in the request, such as
    #   `blocks[0].steps[1].reps`. Answers as GET /api/workouts/:id does.
    # @request #/components/schemas/NewWorkout
    # @response 201 #/components/schemas/Workout
    # @response 400 #/components/responses/BadRequest
    # @response 422 #/components/responses/Invalid
    def create
      blocks!
      workout = Workout.create_with!(params.to_h.slice(:kind, :title, :subtitle, :warmup, :cooldown, :blocks))
      show_workout(workout.id, status: :created)
    end

    # Change a workout's title or framing.
    # @description Fields left out are kept. `warmup` and `cooldown` (main
    #   workouts only) take a workout id, "none", or null for its program's.
    #   Archived workouts are read-only (403). Blocks and steps change with
    #   PUT. The warm-up and cool-down can't change
    #   while a session of the workout is under way (409).
    # @request { title?: String, subtitle?: String, warmup?: String, cooldown?: String }
    # @response 200 #/components/schemas/Workout
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def update
      workout = Workout.find!(params[:id])
      raise BadRequest.param(:blocks, "change with PUT, which takes the whole structure") if params.key?(:blocks)
      raise BadRequest.param(:kind, "can't change; build a new workout instead") if params.key?(:kind)
      workout.revise!(params.to_h.slice(*Workout::FIELDS.map(&:to_sym)))
      show_workout(workout.id)
    end

    # Replace the blocks and steps of the user's own workout.
    # @description `blocks` is the whole structure, in order: each block's
    #   `label` (unique in the workout), `rounds` (1 if left out) and
    #   `rest_seconds` after each round but the last (0), and its `steps`:
    #   `exercise_id`, `reps` or `duration_seconds` (or only a `note`),
    #   `tempo`, `weight` ({ value, unit }, the exercise's unit if left out),
    #   `weights_held`, `per_side` (the exercise's), `note` and `equipment`
    #   slugs when done with other gear than the exercise names. A block or
    #   step that names its `id` is kept, so the sets logged against a step
    #   keep their link; one given another exercise becomes a new step. The
    #   blocks GET gives can be sent back as they are: what only GET has
    #   (`position`, `exercise`, `target`, ...) is ignored.
    #   Blocks and steps left out are deleted; their logged sets stay in the
    #   history. Title, subtitle, `warmup` and `cooldown` may come along, as
    #   PATCH takes them. All or nothing: the 422 names each block and step
    #   at fault, with `fields` keyed by path, such as
    #   `blocks[0].steps[1].reps`. Archived workouts are read-only
    #   (403); while a session of it is under way, as the workout or its
    #   warm-up or cool-down, the answer is a 409 until it is finished or
    #   skipped, or planned again while no set is logged in it. A session
    #   counts as under way on its day and the next, and later on while it
    #   was picked up again or logged a set in the last day; one left idle
    #   longer no longer blocks the change.
    # @request #/components/schemas/WorkoutStructure
    # @response 200 #/components/schemas/Workout
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def replace
      workout = editable(Workout.find!(params[:id]))
      blocks!
      raise BadRequest.param(:kind, "can't change; build a new workout instead") if params.key?(:kind) && params[:kind].to_s != workout.kind
      workout.revise!(params.to_h.slice(*Workout::FIELDS.map(&:to_sym), :blocks))
      show_workout(workout.id)
    end

    # Archive the user's own workout.
    # @description It leaves the lists and the calendar from today on: its
    #   sessions still planned from today are deleted. Missed, skipped and done
    #   sessions keep it and say it is archived. A warm-up or cool-down also
    #   leaves the main workouts that pick it, which run without one (their
    #   `warmup` or `cooldown` reads "none"); while a session runs it, the
    #   answer is a 409.
    # @response 204
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def destroy
      workout = editable(Workout.find!(params[:id]))
      workout.archive!
      head :no_content
    end

    # An editable copy of any workout, standing on its own.
    # @description With the same steps, warm-up and cool-down. `title` names
    #   it, else "<title> (copy)". Answers as GET /api/workouts/:id does.
    # @request { title?: String }
    # @response 201 #/components/schemas/Workout
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def duplicate
      copy = Workout.find!(params[:id]).duplicate!(title: params[:title])
      show_workout(copy.id, status: :created)
    end

    private

    # The whole workout, as `show` gives it.
    def show_workout(id, status: :ok)
      workout = Workout.expanded.find!(id)
      render json: workout.detail.merge(changes: PlanChange.standing(workout_ids: [workout.id], today: client_today)), status:
    end

    # The structure is required; an empty one is for WorkoutStructure to refuse.
    def blocks!
      raise BadRequest.param(:blocks, "is required") unless params.key?(:blocks)
    end

    def editable(workout)
      reason = workout.read_only_reason
      raise Forbidden, reason if reason

      workout
    end
  end
end
