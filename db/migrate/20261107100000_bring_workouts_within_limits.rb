# frozen_string_literal: true

# Workouts saved before their limits may be past them: a block of a
# trillion rounds still stalls the server when its plan is drawn, and a
# title too long fails every later save. Each value is brought within its
# limit; a row within them is left as it is.
Sequel.migration do
  up do
    { blocks: { rounds: 20, rest_seconds: 600 }, steps: { reps: 1000, duration_seconds: 3600 } }.each do |table, columns|
      columns.each { |column, most| self[table].where { Sequel[column] > most }.update(column => most) }
    end
    { workouts: { title: 100, subtitle: 200 }, steps: { note: 500 } }.each do |table, columns|
      columns.each do |column, most|
        self[table].where { length(Sequel[column]) > most }.update(column => Sequel.function(:substr, column, 1, most))
      end
    end
    # A label is unique in its workout, so a cut one ends with its block's id.
    self[:blocks].where { length(:label) > 60 }.select(:id, :label).all.each do |block|
      suffix = " #{block[:id]}"
      self[:blocks].where(id: block[:id]).update(label: "#{block[:label][0, 60 - suffix.size].rstrip}#{suffix}")
    end
  end

  down do
    # Nothing to undo: the values cut down are gone.
  end
end
