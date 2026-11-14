require "json"

# Checks an exercise animation against the skeleton the frontend renders it
# on (public/js/skeleton.json), so a typo in the seed YAML fails on load rather
# than drawing a broken figure. The format is described in public/js/figure.js.
module Animation
  SKELETON = JSON.parse(File.read(File.expand_path("../../public/js/skeleton.json", __dir__)))
  SEGMENTS = SKELETON.fetch("segments").keys.freeze
  JOINTS = (["hip"] + SKELETON.fetch("segments").values.map { it.fetch("to") }).freeze
  PROPS = SKELETON.fetch("props").freeze
  KEYS = %w[anchor accent highlight props still keyframes].freeze
  KEYFRAME_KEYS = %w[pose at scale hold move].freeze

  # A list of problems, empty when the animation is fine.
  def self.problems(animation)
    return ["must be a mapping"] unless animation.is_a?(Hash)

    keyframes = animation["keyframes"]
    return ["needs at least two keyframes"] unless keyframes.is_a?(Array) && keyframes.size >= 2

    problems = unknown("keys", animation.keys, KEYS)
    problems << "unknown anchor joint #{animation["anchor"]}" if animation["anchor"] && !JOINTS.include?(animation["anchor"])
    problems += unknown("accent segments", Array(animation["accent"]), SEGMENTS)
    problems += unknown("highlight segments or joints", Array(animation["highlight"]), SEGMENTS + JOINTS)
    problems << "still must be a keyframe index" if animation["still"] && !(0...keyframes.size).cover?(animation["still"])
    problems += Array(animation["props"]).flat_map { prop_problems(it) }
    problems + keyframes.each_with_index.flat_map { |keyframe, index| keyframe_problems(keyframe, index) }
  end

  def self.keyframe_problems(keyframe, index)
    return ["keyframe #{index} must be a mapping"] unless keyframe.is_a?(Hash)

    pose = keyframe.fetch("pose", {})
    problems = unknown("keys in keyframe #{index}", keyframe.keys, KEYFRAME_KEYS)
    problems += unknown("segments in keyframe #{index}", pose.keys, SEGMENTS)
    problems << "keyframe #{index}: angles must be numbers" unless pose.values.all?(Numeric)
    problems << "keyframe #{index}: at must be [x, y]" if keyframe.key?("at") && !point?(keyframe["at"])
    problems += scale_problems(keyframe.fetch("scale", {}), index)
    %w[hold move].each do |key|
      problems << "keyframe #{index}: #{key} must be zero or more seconds" if keyframe.key?(key) && !(keyframe[key].is_a?(Numeric) && keyframe[key] >= 0)
    end
    problems
  end

  def self.scale_problems(scale, index)
    return ["keyframe #{index}: scale must be a mapping"] unless scale.is_a?(Hash)

    problems = unknown("segments in keyframe #{index} scale", scale.keys, SEGMENTS)
    problems << "keyframe #{index}: scale must be between 0 and 1" unless scale.values.all? { it.is_a?(Numeric) && it.between?(0, 1) }
    problems
  end

  def self.prop_problems(prop)
    return ["unknown prop #{prop.inspect}"] unless prop.is_a?(Hash) && PROPS.include?(prop["type"])

    joints = prop.values_at("at", "from", "to").compact
    unknown("joints for #{prop["type"]}", joints, JOINTS)
  end

  def self.unknown(what, names, known)
    extra = names - known
    extra.any? ? ["unknown #{what}: #{extra.join(", ")}"] : []
  end

  def self.point?(value)
    value.is_a?(Array) && value.size == 2 && value.all?(Numeric)
  end

  private_class_method :keyframe_problems, :scale_problems, :prop_problems, :unknown, :point?
end
