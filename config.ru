# frozen_string_literal: true

require_relative "config/application"
require_relative "lib/static_files"

use StaticFiles, Rage.root.join("public").to_s
run Rage.application
