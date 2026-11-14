module Api
  class CoachController < ApplicationController
    # The Coach tab: goals, status, focus, concerns, notes and this week.
    # @description `goals` are the active ones in order and `proposals` the
    #   agent's waiting for the user. `status` and `focus` are the newest of
    #   their kind (null when none), each naming the one it `replaces`.
    #   `concerns` are the open ones, newest first, and `notes` the latest
    #   ten of the journal: every other note, the statuses and focus since
    #   replaced and the concerns resolved included. `week` is Monday to Sunday of `today` (the
    #   sender's own date, within a day of the server's): its sessions,
    #   activities and dated notes as plain lists, with nothing summed or
    #   scored.
    # @param today? {Date} The sender's own date.
    # @response 200 #/components/schemas/CoachBoard
    # @response 400 #/components/responses/BadRequest
    def show
      render json: CoachBoard.new(today: client_today)
    end

    # The coach's notes, newest first, a page at a time.
    # @description `kind` keeps one kind; `journal=true` keeps the journal
    #   as GET /api/coach shows it (all but the current status and focus and
    #   the open concerns). `before` is a note id: the page holds the notes
    #   written before it. `next_before` is the id to ask with for the next
    #   page, null on the last one.
    # @param kind? One of status, focus, concern, note.
    # @param journal? {Boolean} Only the journal.
    # @param before? {Integer} A note id; the notes written before it.
    # @param limit? {Integer} Notes a page, 1 to 100 (default 20).
    # @response 200 #/components/schemas/CoachNotes
    # @response 400 #/components/responses/BadRequest
    def notes
      notes = Record.boolean(params[:journal]) ? CoachBoard.new.journal_notes : CoachNote.eager(:activity, session: :workout).newest_first
      if params[:kind].present?
        raise BadRequest.param(:kind, "must be one of #{CoachNote::KINDS.join(", ")}") unless CoachNote::KINDS.include?(params[:kind])

        notes = notes.of_kind(params[:kind])
      end
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
  end
end
