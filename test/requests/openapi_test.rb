require "test_helper"

describe "API description" do
  include RequestHelpers

  # Rage rewinds rack.input before a mounted app, which rack-test leaves out
  # of a GET; the server always has one.
  let(:spec) do
    get "/api/openapi/json", {}, { "rack.input" => StringIO.new }
    json
  end

  it "is served as OpenAPI" do
    _(spec).must_be_kind_of Hash
    _(last_response.status).must_equal 200
    _(spec["openapi"]).must_match(/\A3\./)
    _(spec["info"]["title"]).must_equal "The Lazy Runner API"
    _(spec["components"]["schemas"]).must_include "Error"
  end

  # Rage's own page loads swagger-ui-dist@^5 from unpkg; this one serves an
  # exact release from this server, and lets nothing else run (#206).
  describe "the reference page" do
    def page(path = "")
      get "/api/openapi#{path}", {}, { "rack.input" => StringIO.new }
      last_response
    end

    it "loads Swagger UI from this server only" do
      _(page.status).must_equal 200
      _(page.content_type).must_include "text/html"
      scripts = page.body.scan(/<script[^>]*src="([^"]+)"/).flatten
      _(scripts).must_equal %w[/api/openapi/swagger-ui/swagger-ui-bundle.js /api/openapi/init.js]
      _(page.body).wont_include "unpkg"
      _(page.headers["content-security-policy"]).must_include "script-src 'self'"
      _(page.headers["content-security-policy"]).must_include "frame-ancestors 'none'"
    end

    it "serves the exact release it names, and nothing else from its folder" do
      version = JSON.parse(File.read(File.join(ApiReference::ROOT, "swagger-ui/package.json")))["version"]
      _(version).must_match(/\A\d+\.\d+\.\d+\z/)
      _(page("/swagger-ui/swagger-ui-bundle.js").status).must_equal 200
      _(page("/swagger-ui/swagger-ui.css").status).must_equal 200
      _(page("/init.js").body).must_include "/api/openapi/json"
      _(page("/swagger-ui/package.json").status).must_equal 404
      _(page("/../api_reference.rb").status).must_equal 404
    end
  end

  it "builds without warnings" do
    _(Rage::OpenAPI.__collect_warnings { Rage::OpenAPI.build }).must_be_empty
  end

  it "describes every route with a summary and a success response" do
    routes = Rage.__router.routes.select { it[:meta][:controller_class] }
    _(routes).wont_be_empty

    routes.each do |route|
      path = route[:path].gsub(/:(\w+)/, '{\1}')
      operation = spec.dig("paths", path, route[:method].downcase)

      _(operation).wont_be_nil "#{route[:method]} #{path} is not described"
      _(operation["summary"]).wont_be_nil "#{route[:method]} #{path} has no summary"
      _(operation["responses"].keys.any? { it.start_with?("2") }).must_equal true, "#{route[:method]} #{path} has no success response"
    end
  end

  it "describes the body of every success response but a 204" do
    successes = spec["paths"].flat_map do |path, operations|
      operations.except("parameters").flat_map do |method, operation|
        operation["responses"].select { |status, _| status.start_with?("2") }.map { |status, response| ["#{method.upcase} #{path} #{status}", response] }
      end
    end

    successes.each do |name, response|
      schema = response.dig("content", "application/json", "schema")
      if name.end_with?("204") then _(schema).must_be_nil name
      else _(schema).wont_be_nil "#{name} has no body schema"
      end
    end
  end

  it "points every error response at the shared error shape" do
    refs = spec["paths"].values.flat_map { it.except("parameters").values }.flat_map { it["responses"].reject { |status, _| status.start_with?("2") }.values }

    _(refs).wont_be_empty
    _(refs.map { it["$ref"] }.uniq - spec["components"]["responses"].keys.map { "#/components/responses/#{it}" }).must_be_empty
  end

  # The YAML can't read Ruby constants, so this keeps the two together.
  it "states a workout's limits as the models keep them" do
    schemas = spec["components"]["schemas"]
    step, block = schemas["StepInput"]["properties"], schemas["BlockInput"]["properties"]

    _([step["reps"]["maximum"], step["duration_seconds"]["maximum"], step["note"]["maxLength"]])
      .must_equal [Step::MAX_REPS, Step::MAX_SECONDS, Step::MAX_NOTE]
    _([block["rounds"]["maximum"], block["rest_seconds"]["maximum"], block["label"]["maxLength"], block["steps"]["maxItems"]])
      .must_equal [Block::MAX_ROUNDS, Block::MAX_REST_SECONDS, Block::MAX_LABEL, WorkoutStructure::MAX_STEPS]
    %w[WorkoutStructure NewWorkout].each do |name|
      workout = schemas[name]["properties"]
      _([workout["title"]["maxLength"], workout["subtitle"]["maxLength"], workout["blocks"]["maxItems"]])
        .must_equal [Workout::MAX_LENGTHS[:title], Workout::MAX_LENGTHS[:subtitle], WorkoutStructure::MAX_BLOCKS]
    end
  end
end
