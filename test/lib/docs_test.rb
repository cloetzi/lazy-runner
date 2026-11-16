# frozen_string_literal: true

require "test_helper"

describe "docs/data-model.md" do
  let(:diagram) { File.read(Rage.root.join("docs/data-model.md"), encoding: "UTF-8")[/```mermaid\n(.*?)```/m, 1] }

  # The attribute names listed under each entity of the ER diagram.
  let(:documented) do
    diagram.scan(/^\s+(\w+) \{\n(.*?)^\s+\}/m).to_h do |table, body|
      [table, body.lines.map { it.split[1] }.compact]
    end
  end

  let(:schema) do
    (DB.tables - %i[schema_migrations]).to_h do |table|
      [table.to_s, DB.schema(table).map { it.first.to_s } - %w[created_at updated_at]]
    end
  end

  it "draws every table" do
    _(documented.keys.sort).must_equal schema.keys.sort
  end

  it "lists every column, and only columns that exist" do
    schema.each do |table, columns|
      _(documented.fetch(table).sort).must_equal columns.sort, "#{table} columns differ from the schema"
    end
  end
end
