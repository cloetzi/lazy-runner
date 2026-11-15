require "test_helper"

describe SeedLoader do
  # Loads the real seeds with some files rewritten: { "exercises.yml" => [...] }.
  def load_seeds_with(files)
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[Rage.root.join("db/seeds/*.yml")], dir)
      files.each { |name, content| File.write(File.join(dir, name), content.to_yaml) }
      SeedLoader.load!(dir)
    end
  end

  def seed(name) = YAML.safe_load_file(Rage.root.join("db/seeds", name))

  it "loads every exercise and piece of equipment, and no programs" do
    _(Exercise.count).must_equal 44
    _(Equipment.current.count).must_equal seed("equipment.yml").size

    someone = create_user("someone", bare: true)
    SeedLoader.load!
    _(Program.of(someone.id).count).must_equal 0
    _(Workout.of(someone.id).count).must_equal 0
    _(UserEquipment.of(someone.id).count).must_equal 0
  end

  it "is idempotent and keeps ids stable" do
    ids = -> { [Exercise.order(:id).select_map(:id), Equipment.order(:id).select_map(:id)] }
    before = ids.call

    SeedLoader.load!

    _(ids.call).must_equal before
  end

  it "writes nothing when the seeds haven't changed" do
    stamps = -> { [Exercise, Equipment].map { it.max(:updated_at) } }
    before = stamps.call

    travel_to(Time.now + 60) { SeedLoader.load! }

    _(stamps.call).must_equal before
  end

  it "keeps the library shared: one copy whoever signs up" do
    counts = -> { [Exercise.count, Equipment.count] }
    before = counts.call
    create_user("someone")
    SeedLoader.load!

    _(counts.call).must_equal before
  end

  describe "equipment" do
    it "tags exercises with what they need, and nothing for bodyweight" do
      _(exercise("rear-foot-elevated-split-squat").equipment_slugs).must_equal %w[bench dumbbell]
      _(exercise("plank").equipment).must_be_empty
    end

    it "keeps what the user changed in their inventory" do
      inventory("dumbbell").update(weights: [5, 10, 20])
      inventory("hangboard").update(owned: false)

      SeedLoader.load!

      _(inventory("dumbbell").weights).must_equal [5, 10, 20]
      _(inventory("hangboard").owned).must_equal false
    end

    it "adds new items to the catalogue, and retires dropped ones, out of every exercise" do
      list = seed("equipment.yml").reject { it["slug"] == "stability_ball" }
      list << { "slug" => "band", "name" => "Resistance band" }
      exercises = seed("exercises.yml")
      exercises.each { it["equipment"]&.delete("stability_ball") }

      load_seeds_with("equipment.yml" => list, "exercises.yml" => exercises)

      _(equipment("band").retired).must_equal false
      _(Equipment.current.where(slug: "stability_ball").empty?).must_equal true
      _(exercise("swiss-ball-hamstring-curl").equipment).must_be_empty
      # What the user had of it stays, for when it comes back.
      _(inventory("stability_ball").owned).must_equal true
      SeedLoader.load!
      _(equipment("stability_ball").retired).must_equal false
    end

    it "takes a retired item off the steps that named it" do
      deadlift = step_for("cycle-1-workout-1", "straight-leg-deadlift")
      _(deadlift.equipment_needed).must_equal ["kettlebell"]

      SeedLoader.new(Rage.root.join("db/seeds")).send(:prune_equipment, Equipment.exclude(slug: "kettlebell").select_map(:slug))

      _(deadlift.refresh.equipment_needed).must_equal ["dumbbell"]
    end
  end

  describe "when an exercise leaves the seeds" do
    let(:gone) { Exercise.create(slug: "rowing", name: "Rowing", category: "cardio") }

    it "removes it when nothing uses it, with its remembered weight" do
      ExerciseWeight.create(exercise: gone, value: 10, unit: "lb")

      SeedLoader.load!

      _(Exercise.where(id: gone.id).empty?).must_equal true
      _(ExerciseWeight.where(exercise_id: gone.id).empty?).must_equal true
    end

    it "retires it when sets were done of it, keeping them" do
      SetLog.create(session: session_on(Date.current), step: step_for("cycle-1-workout-1", "goblet-squat"), exercise: gone, set_number: 1, reps: 20)

      SeedLoader.load!

      _(gone.refresh.retired).must_equal true
      _(Exercise.current.where(id: gone.id).empty?).must_equal true
      _(ExerciseHistory.new(gone).sessions.first[:sets].first[:reps]).must_equal 20
    end

    it "brings a retired exercise back when it returns to the seeds" do
      exercise("plank").update(retired: true)

      SeedLoader.load!

      _(exercise("plank").retired).must_equal false
    end
  end

  describe "with a broken seed" do
    it "rejects an exercise with a broken animation" do
      exercises = seed("exercises.yml")
      exercises.find { it["slug"] == "plank" }["animation"] = { "keyframes" => [{ "pose" => { "tail" => 10 } }, {}] }

      error = _ { load_seeds_with("exercises.yml" => exercises) }.must_raise SeedLoader::Error
      _(error.message).must_include "plank: Animation unknown segments in keyframe 0: tail"
    end

    it "rejects an exercise that needs unknown equipment" do
      exercises = seed("exercises.yml")
      exercises.find { it["slug"] == "plank" }["equipment"] = ["treadmill"]

      error = _ { load_seeds_with("exercises.yml" => exercises) }.must_raise SeedLoader::Error
      _(error.message).must_equal "plank: unknown equipment 'treadmill'"
    end

    # On a fresh install, where no step keeps the exercise in the library.
    it "stops at an example program naming an exercise the library no longer has" do
      User.dataset.delete
      exercises = seed("exercises.yml").reject { it["slug"] == "goblet-squat" }

      error = _ { load_seeds_with("exercises.yml" => exercises) }.must_raise Example::Error
      _(error.message).must_equal "cycle-1: cycle-1-workout-1 A: unknown exercise 'goblet-squat'"
      _(exercise("goblet-squat").retired).must_equal false
    end

    it "loads nothing when the seed is broken" do
      exercises = seed("exercises.yml")
      exercises << { "slug" => "rowing", "name" => "Rowing", "category" => "cardio", "equipment" => ["treadmill"] }

      _ { load_seeds_with("exercises.yml" => exercises) }.must_raise SeedLoader::Error
      _(Exercise.where(slug: "rowing").empty?).must_equal true
    end
  end
end
