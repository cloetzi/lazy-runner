require "test_helper"

describe Record do
  let(:squat) { exercise("goblet-squat") }

  describe ".find!" do
    it "finds by id, given as a number or as text" do
      _(Exercise.find!(squat.id).slug).must_equal "goblet-squat"
      _(Exercise.find!(squat.id.to_s).slug).must_equal "goblet-squat"
    end

    it "names what it didn't find" do
      error = _ { Exercise.find!("nope") }.must_raise Record::NotFound

      _([error.resource, error.id, error.message]).must_equal ["exercise", "nope", "Exercise nope not found"]
    end

    it "loads what eager asks for" do
      _(Exercise.eager(:equipment).find!(squat.id).associations.keys).must_equal [:equipment]
      _(Exercise.eager(:equipment).first(slug: "goblet-squat").associations.keys).must_equal [:equipment]
      _(Exercise.eager(:equipment).with_pk(squat.id).associations.keys).must_equal [:equipment]
    end
  end

  it "is not found once deleted since it was loaded" do
    setting = Setting.current
    Setting.where(id: setting.id).delete

    _ { setting.update(unit: "kg") }.must_raise Record::NotFound
    _ { setting.destroy }.must_raise Record::NotFound
  end

  it "refuses a value its column's type can't hold, unless a validation named it" do
    session = Session.new(workout: workout("cycle-1-workout-1"), date: Date.today, started_at: "soon", note: { a: 1 })
    block = Block.new(workout: workout("cycle-1-workout-1"), label: "Z", position: 9, rounds: [2])

    _([session, block].map { it.valid? && nil || it.errors.full_messages })
      .must_equal [["Started at is invalid", "Note is invalid"], ["Rounds is not a number"]]
  end

  describe ".boolean" do
    it "reads text as the API always has" do
      _(%w[0 f false off FALSE Off].map { Record.boolean(it) }.uniq).must_equal [false]
      _(%w[1 t true on yes no].map { Record.boolean(it) }.uniq).must_equal [true]
      _([Record.boolean(""), Record.boolean(nil), Record.boolean(true), Record.boolean(false)]).must_equal [nil, nil, true, false]
    end
  end
end
