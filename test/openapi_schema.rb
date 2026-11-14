# Checks JSON against the schemas in the API description, strictly: an object
# must have exactly the properties its schema lists (allOf parts merged), so a
# field added to a response without describing it fails too. Covers the parts
# of OpenAPI 3.0 the description uses: $ref, allOf, oneOf, anyOf, nullable,
# type, enum, properties, required, additionalProperties (a schema, or true
# for any) and items; a schema with only a description takes anything.
class OpenAPISchema
  def initialize(spec)
    @spec = spec
  end

  # The problems with `value`, as "path: what is wrong"; empty when it fits.
  def errors(value, schema, path = "$")
    schema = resolve(schema)
    return [] if value.nil? && (schema["nullable"] || any?(schema))
    return ["#{path}: is null"] if value.nil?

    if schema["oneOf"]
      results = schema["oneOf"].map { errors(value, it, path) }
      return results.count(&:empty?) == 1 ? [] : ["#{path}: matches #{results.count(&:empty?)} of the oneOf schemas"] + results.min_by(&:size)
    end

    if schema["anyOf"]
      results = schema["anyOf"].map { errors(value, it, path) }
      return ["#{path}: matches none of the anyOf schemas"] + results.min_by(&:size) if results.none?(&:empty?)

      schema = schema.except("anyOf")
    end

    schema = merged(schema)
    problems = type_errors(value, schema, path)
    return problems if problems.any?
    return ["#{path}: #{value.inspect} is not one of #{schema["enum"].inspect}"] if schema["enum"] && !schema["enum"].include?(value)

    case value
    when Hash then object_errors(value, schema, path)
    when Array then schema["items"] ? value.each_with_index.flat_map { |item, i| errors(item, schema["items"], "#{path}[#{i}]") } : []
    else []
    end
  end

  private

  # A schema that says nothing about the value, null included, such as an
  # input field that is ignored.
  def any?(schema)
    (schema.keys - %w[description]).empty?
  end

  def resolve(schema)
    schema = @spec.dig(*schema["$ref"].delete_prefix("#/").split("/")) while schema["$ref"]
    schema
  end

  # One schema of an allOf and its parts.
  def merged(schema)
    return schema unless schema["allOf"]

    [schema.except("allOf"), *schema["allOf"].map { merged(resolve(it)) }].reduce do |all, part|
      all.merge(part) do |key, mine, theirs|
        case key
        when "properties" then mine.merge(theirs)
        when "required" then mine | theirs
        else mine
        end
      end
    end
  end

  def type_errors(value, schema, path)
    fits =
      case schema["type"]
      when nil then true
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      end
    fits ? [] : ["#{path}: #{value.inspect} is not #{schema["type"]}"]
  end

  def object_errors(value, schema, path)
    properties = schema["properties"] || {}
    missing = (schema["required"] || []) - value.keys
    problems = missing.map { "#{path}: misses #{it}" }

    value.each do |key, item|
      if properties.key?(key)
        problems.concat(errors(item, properties[key], "#{path}.#{key}"))
      elsif schema["additionalProperties"].is_a?(Hash)
        problems.concat(errors(item, schema["additionalProperties"], "#{path}.#{key}"))
      elsif schema.key?("properties") && schema["additionalProperties"] != true
        problems << "#{path}: has #{key}, which is not described"
      end
    end
    problems
  end
end
