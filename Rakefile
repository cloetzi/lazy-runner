require_relative "config/application"
require "rake/testtask"

Rage.load_tasks

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

task default: :test
