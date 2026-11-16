# frozen_string_literal: true

require "test_helper"

describe OpenAPISchema do
  let(:spec) do
    {
      "components" => {
        "schemas" => {
          "Weight" => { "type" => "object", "required" => %w[value unit],
                        "properties" => { "value" => { "type" => "number" }, "unit" => { "type" => "string", "enum" => %w[lb kg] } } },
          "Rest" => { "type" => "object", "required" => %w[type],
                      "properties" => { "type" => { "type" => "string", "enum" => %w[rest] } } },
          "Set" => {
            "allOf" => [
              { "type" => "object", "required" => %w[reps], "properties" => { "reps" => { "type" => "integer" } } },
              { "type" => "object", "required" => %w[weight],
                "properties" => { "weight" => { "allOf" => [{ "$ref" => "#/components/schemas/Weight" }], "nullable" => true } } }
            ]
          }
        }
      }
    }
  end
  let(:checker) { OpenAPISchema.new(spec) }
  let(:set) { { "$ref" => "#/components/schemas/Set" } }

  it "takes a body that fits, with the allOf parts merged" do
    _(checker.errors({ "reps" => 8, "weight" => { "value" => 20.0, "unit" => "lb" } }, set)).must_be_empty
    _(checker.errors({ "reps" => 8, "weight" => nil }, set)).must_be_empty
  end

  it "names a key that is missing or not described" do
    _(checker.errors({ "weight" => nil, "side" => "left" }, set)).must_equal ["$: misses reps", "$: has side, which is not described"]
  end

  it "takes null only where the schema is nullable" do
    _(checker.errors({ "reps" => nil, "weight" => nil }, set)).must_equal ["$.reps: is null"]
  end

  it "checks types and enums through references" do
    _(checker.errors({ "reps" => 8.5, "weight" => { "value" => "20", "unit" => "st" } }, set))
      .must_equal ["$.reps: 8.5 is not integer", "$.weight.value: \"20\" is not number",
                   "$.weight.unit: \"st\" is not one of [\"lb\", \"kg\"]"]
  end

  it "wants exactly one schema of a oneOf to match, item by item" do
    items = { "type" => "array", "items" => { "oneOf" => [set, { "$ref" => "#/components/schemas/Rest" }] } }

    _(checker.errors([{ "type" => "rest" }, { "reps" => 5, "weight" => nil }], items)).must_be_empty
    _(checker.errors([{ "type" => "work" }], items).first).must_equal "$[0]: matches 0 of the oneOf schemas"
  end

  it "wants at least one schema of an anyOf to match, besides the rest of the schema" do
    either = {
      "type" => "object", "anyOf" => [{ "required" => %w[a] }, { "required" => %w[b] }],
      "properties" => { "a" => { "type" => "integer" }, "b" => { "type" => "integer" } }
    }

    _(checker.errors({ "a" => 1, "b" => 2 }, either)).must_be_empty
    _(checker.errors({ "b" => "2" }, either)).must_equal ["$.b: \"2\" is not integer"]
    _(checker.errors({}, either)).must_equal ["$: matches none of the anyOf schemas", "$: misses a"]
  end

  it "takes any other key where additionalProperties is true" do
    open = { "type" => "object", "required" => %w[id], "properties" => { "id" => { "type" => "integer" } }, "additionalProperties" => true }

    _(checker.errors({ "id" => 1, "slug" => "plank" }, open)).must_be_empty
    _(checker.errors({ "slug" => "plank" }, open)).must_equal ["$: misses id"]
  end

  it "takes anything, null included, for a schema with only a description" do
    _(checker.errors(nil, { "description" => "Ignored." })).must_be_empty
    _(checker.errors({ "a" => [1] }, { "description" => "Ignored." })).must_be_empty
  end
end
