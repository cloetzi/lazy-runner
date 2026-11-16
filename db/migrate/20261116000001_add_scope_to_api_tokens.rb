# frozen_string_literal: true

# What an API token is good for: `mcp`, the trainer's MCP server alone, or
# `api`, the REST API under /api as well (for a script). MCP alone is the
# default, and every token made before this is MCP alone: REST access is
# ticked when a token is made. An ADD COLUMN, so no table is copied.
Sequel.migration do
  up do
    run "ALTER TABLE `api_tokens` ADD COLUMN `scope` varchar(255) NOT NULL DEFAULT 'mcp' " \
        "CONSTRAINT `api_tokens_scope` CHECK (`scope` IN ('mcp', 'api'))"
  end

  down do
    alter_table(:api_tokens) { drop_column :scope }
  end
end
