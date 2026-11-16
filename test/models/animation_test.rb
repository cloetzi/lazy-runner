# frozen_string_literal: true

require "test_helper"

describe Animation do
  def animation(**changes)
    {
      "anchor" => "ankle_near",
      "accent" => ["thigh_near"],
      "highlight" => %w[thigh_near hip],
      "props" => [{ "type" => "dumbbell", "at" => "hand_near" }, { "type" => "bench", "x" => 20, "width" => 60, "height" => 40 }],
      "still" => 1,
      "keyframes" => [
        { "pose" => { "torso" => -90, "thigh_near" => 88 }, "at" => [96, 182], "hold" => 1, "move" => 2 },
        { "pose" => { "torso" => -62.5 } }
      ]
    }.merge(changes.transform_keys(&:to_s))
  end

  it "accepts a well-formed animation" do
    _(Animation.problems(animation)).must_be_empty
  end

  it "accepts every animation in the seeds" do
    Exercise.exclude(animation: nil).each do |exercise|
      _(Animation.problems(exercise.animation)).must_be_empty
    end
    _(Exercise.exclude(animation: nil).select_map(:slug)).must_include "goblet-squat"
  end

  it "needs at least two keyframes" do
    _(Animation.problems(animation(keyframes: [{ "pose" => {} }]))).must_equal ["needs at least two keyframes"]
    _(Animation.problems("squat")).must_equal ["must be a mapping"]
  end

  it "rejects unknown segments, joints and keys" do
    problems = Animation.problems(animation(
                                    anchor: "tail",
                                    accent: ["wing"],
                                    highlight: %w[hip fin],
                                    tempo: 2111,
                                    keyframes: [{ "pose" => { "thigh" => 10 } }, { "pose" => {}, "speed" => 2 }]
                                  ))

    _(problems).must_equal [
      "unknown keys: tempo",
      "unknown anchor joint tail",
      "unknown accent segments: wing",
      "unknown highlight segments or joints: fin",
      "unknown segments in keyframe 0: thigh",
      "unknown keys in keyframe 1: speed"
    ]
  end

  it "rejects bad numbers" do
    problems = Animation.problems(animation(
                                    still: 5,
                                    keyframes: [{ "pose" => { "torso" => "up" }, "at" => [1], "hold" => -1 }, { "move" => "slow" }]
                                  ))

    _(problems).must_equal [
      "still must be a keyframe index",
      "keyframe 0: angles must be numbers",
      "keyframe 0: at must be [x, y]",
      "keyframe 0: hold must be zero or more seconds",
      "keyframe 1: move must be zero or more seconds"
    ]
  end

  it "checks foreshortening scales" do
    good = animation(keyframes: [{ "pose" => {}, "scale" => { "upper_arm_near" => 0.3 } }, { "scale" => { "upper_arm_near" => 1 } }])
    bad = animation(keyframes: [{ "scale" => { "wing" => 0.5, "shin_far" => 1.5 } }, { "scale" => 2 }])

    _(Animation.problems(good)).must_be_empty
    _(Animation.problems(bad)).must_equal [
      "unknown segments in keyframe 0 scale: wing",
      "keyframe 0: scale must be between 0 and 1",
      "keyframe 1: scale must be a mapping"
    ]
  end

  it "rejects unknown props and props on unknown joints" do
    problems = Animation.problems(animation(props: [{ "type" => "barbell" }, { "type" => "band", "from" => "knee_near", "to" => "paw" }]))

    _(problems).must_equal ['unknown prop {"type" => "barbell"}', "unknown joints for band: paw"]
  end

  it "stops an exercise with a broken animation from saving" do
    plank = exercise("plank")
    plank.animation = animation(accent: ["wing"])

    _(plank.valid?).must_equal false
    _(plank.errors[:animation]).must_equal ["unknown accent segments: wing"]
  end
end
