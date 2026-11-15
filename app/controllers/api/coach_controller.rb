module Api
  class CoachController < ApplicationController
    # The Coach tab: goals, status, focus, concerns, notes and this week.
    # @description `goals` are the active ones in order, `proposals` the
    #   agent's waiting for the user and `past_goals` how many were achieved
    #   or dropped. `status` and `focus` are the newest of
    #   their kind (null when none), each naming the one it `replaces`.
    #   `concerns` are the open ones, newest first, and `notes` the latest
    #   ten of the journal: every other note, the statuses and focus since
    #   replaced and the concerns resolved included. `week` is Monday to Sunday of `today` (the
    #   sender's own date, within a day of the server's): its sessions,
    #   activities, notes, and routines with their days, as GET
    #   /api/calendar gives them: plain lists, with nothing summed or scored.
    # @param today? {Date} The sender's own date.
    # @response 200 #/components/schemas/CoachBoard
    # @response 400 #/components/responses/BadRequest
    def show
      render json: CoachBoard.new(today: client_today)
    end

    # What agents did since the user last looked: "Since you last looked".
    # @description Since `since` (when the user last marked it seen with
    #   POST /api/coach/seen, else the last 14 days): the changes agents
    #   made to the plan, not taken back, newest first, each with whether
    #   it can be taken back on `today` (the sender's own date); the notes
    #   they wrote and the goals they proposed, newest first; and the
    #   activities they copied, counted by agent, with their first and last
    #   day and the sources they came from. `latest` is when the newest of them was
    #   made (null when there is nothing), the time to mark seen.
    # @param today? {Date} The sender's own date, which undo counts from.
    # @response 200 #/components/schemas/CoachNews
    # @response 400 #/components/responses/BadRequest
    def news
      render json: CoachNews.new(Current.user, today: client_today)
    end

    # Mark "Since you last looked" as seen.
    # @description Up to `until` (the `latest` GET /api/coach/news gave, so
    #   anything made after the user read it is still news), else now; never
    #   later than now, and an earlier time than the one marked already
    #   changes nothing. `count` is what is still news after it, which the
    #   Coach tab's dot shows. Only the user marks it seen: with an API
    #   token, 403.
    # @request { until?: DateTime }
    # @response 200 { coach_seen_at: DateTime, count: Integer }
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    def seen
      raise Forbidden, "only the user marks what agents did as seen, in the app" if Current.agent_name

      user = Current.user.coach_seen!(client_time(:until) || Time.now)
      render json: { coach_seen_at: user.coach_seen_at, count: CoachNews.new(user).count }
    end

    # The coach's notes, newest first, a page at a time.
    # @description `kind` keeps those kinds and `author` those authors (each
    #   one or several, comma-separated); `journal=true` keeps the journal
    #   as GET /api/coach shows it (all but the current status and focus and
    #   the open concerns). `before` is a note id: the page holds the notes
    #   written before it. `next_before` is the id to ask with for the next
    #   page, null on the last one.
    # @param kind? Of status, focus, concern and note, such as `note,concern`.
    # @param author? Of user, human and llm, such as `human,llm`.
    # @param journal? {Boolean} Only the journal.
    # @param before? {Integer} A note id; the notes written before it.
    # @param limit? {Integer} Notes a page, 1 to 100 (default 20).
    # @response 200 #/components/schemas/CoachNotes
    # @response 400 #/components/responses/BadRequest
    def notes
      notes = Record.boolean(params[:journal]) ? CoachBoard.new.journal_notes : CoachNote.threads.eager(:activity, session: :workout).newest_first
      notes = notes.of_kind(list_param(:kind, CoachNote::KINDS)) if params[:kind].present?
      notes = notes.by(list_param(:author, CoachNote::AUTHORS)) if params[:author].present?
      if params[:before].present?
        before = Record.id(params[:before]) || raise(BadRequest.param(:before, "must be a note id"))
        notes = notes.where { id < before }
      end
      limit = params[:limit].present? ? Record.id(params[:limit]) : CoachNote::PAGE
      raise BadRequest.param(:limit, "must be in 1..#{CoachNote::PAGE_LIMIT}") unless limit && (1..CoachNote::PAGE_LIMIT).cover?(limit)

      page = notes.limit(limit + 1).all
      more = page.size > limit
      page = page.first(limit)
      render json: { notes: page, next_before: (page.last.id if more) }
    end

    # Write a note.
    # @description `kind` is status or focus (each replaces the current one,
    #   which stays in the journal), concern (open until resolved) or note.
    #   `author_kind` is user (the signed-in person, the default), or human
    #   with an `author_name` for a coach without an account. A note can be
    #   about a `date`, an `activity_id` or a `session_id` of the user's.
    #   An agent writes over MCP; `author_kind: llm` here answers 400.
    #   `reply_to_id` makes it a reply to a note the user didn't write: a
    #   plain note of theirs, shown under that note (its `replies`) rather
    #   than on its own, and deleted with it.
    # @request #/components/schemas/CoachNoteInput
    # @response 201 #/components/schemas/CoachNote
    # @response 400 #/components/responses/BadRequest
    # @response 422 #/components/responses/Invalid
    def create_note
      fields = params.slice(*CoachNote::FIELDS)
      fields[:author_kind] = "user" if fields[:author_kind].blank?
      raise BadRequest.param(:author_kind, "must be user or human") if fields[:author_kind] == "llm"

      render json: CoachNote.create(fields), status: :created
    end

    # Change a note, or resolve a concern.
    # @description Fields left out are kept. `resolved: true` resolves a
    #   concern (with an optional `resolution` saying how), `false` opens it
    #   again; on another kind of note it answers 409. Resolving one resolved
    #   already keeps its date, and `resolution` alone rewrites how a
    #   resolved concern was resolved. An agent's note stays
    #   as it wrote it: changing one answers 403 (resolving or deleting it is
    #   fine).
    # @request #/components/schemas/CoachNoteChange
    # @response 200 #/components/schemas/CoachNote
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def update_note
      note = CoachNote.find!(params[:id])
      fields = params.slice(*CoachNote::FIELDS)
      raise BadRequest.param(:author_kind, "must be user or human") if fields[:author_kind] == "llm"
      if note.author_kind == "llm" && !fields.empty?
        raise Forbidden, "an agent's note stays as it wrote it; delete it, or write a note of your own"
      end

      CoachNote.db.transaction(savepoint: true) do
        note.update(fields) unless fields.empty?
        if params.key?(:resolved)
          resolved = Record.boolean(params[:resolved])
          raise BadRequest.param(:resolved, "must be true or false") unless [true, false].include?(resolved)

          resolved ? note.resolve!(params[:resolution]) : note.reopen!
        elsif params.key?(:resolution)
          raise BadRequest.param(:resolution, "is for a resolved concern; send resolved: true with it") unless note.resolved?

          note.update(resolution: params[:resolution])
        end
      end
      render json: note
    end

    # Delete a note.
    # @description Deleting the current status or focus brings the one
    #   before it back.
    # @response 204
    # @response 404 #/components/responses/NotFound
    def destroy_note
      CoachNote.find!(params[:id]).destroy
      head :no_content
    end

    # How many of an agent's notes "Tidy up" would delete.
    # @description The agent's notes written before `before` (a day, in the
    #   server's time zone), leaving those the user replied to, the current status and focus and the
    #   open concerns. Nothing is deleted.
    # @param before {Date} The first day whose notes stay, tomorrow at the latest.
    # @response 200 { count: Integer }
    # @response 400 #/components/responses/BadRequest
    def tidy_count
      render json: { count: CoachNote.tidy_before(tidy_day).count }
    end

    # Delete an agent's notes written before a day.
    # @description The notes GET /api/coach/tidy counts: the agent's,
    #   written before `before`, but the current status and focus, the
    #   open concerns and those the user replied to. The user's notes and a named coach's stay. `before`
    #   is tomorrow at the latest, so a note written now is never "older".
    # @request { before: Date }
    # @response 200 { deleted: Integer }
    # @response 400 #/components/responses/BadRequest
    def tidy
      day = tidy_day
      deleted = CoachNote.db.transaction { CoachNote.tidy_before(day).delete }
      render json: { deleted: }
    end

    private

    # The day Tidy up keeps notes from: tomorrow (the server's) at the
    # latest, which covers a device a day ahead.
    def tidy_day
      day = DateRange.date(required!(:before), :before)
      raise BadRequest.param(:before, "must be tomorrow or earlier") if day > Time.zone.today + 1

      day
    end

    # A comma-separated list of `allowed` values.
    def list_param(key, allowed)
      values = params[key].to_s.split(",").map(&:strip)
      raise BadRequest.param(key, "must be one or more of #{allowed.join(", ")}") if values.empty? || (values - allowed).any?

      values
    end
  end
end
