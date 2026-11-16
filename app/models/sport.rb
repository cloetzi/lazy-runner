# frozen_string_literal: true

# The families sports belong to (run, ride, hike, ...), from the word lists in
# public/js/sports.json that the PWA picks icons by. A routine for a sport is
# fulfilled by an activity of the same family, so whatever shows a run icon
# counts for a run routine; a word in no family matches only itself.
module Sport
  # The words of a sport as they are compared: as Activity.sport keeps
  # them, hyphens read as spaces ("e-bike" is "e bike").
  def self.words(sport) = Activity.sport(sport.to_s.tr("-", " "))

  FAMILIES = JSON.parse(File.read(File.expand_path("../../public/js/sports.json", __dir__)))
    .flat_map { |family, words| words.map { [self.words(it), family] } }.to_h.freeze

  # The family of a sport; its words when it is in none.
  def self.family(sport)
    words = words(sport)
    FAMILIES.fetch(words, words)
  end

  def self.same?(a, b) = family(a) == family(b)
end
