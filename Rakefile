require "rubygems"
require "rake/testtask"
require "bundler"
require "bundler/gem_tasks"
require "bundler/setup"
require "jasmine"

ENV["JASMINE_CONFIG_PATH"] ||= File.join(Dir.pwd, "spec", "assets", "support", "jasmine.yml")
load "jasmine/tasks/jasmine.rake"

require "rubocop/rake_task"
RuboCop::RakeTask.new

require "yard"
YARD::Rake::YardocTask.new

desc "Generate documentation for Yard, and fail if there are any warnings"
task :test_doc do
  sh "yard --fail-on-warning #{'--no-progress' if ENV['CI']}"
end

Bundler.require(:default, :test)

task default: :spec

module CustomBuild
  def build_gem
    `cp assets/message-bus* vendor/assets/javascripts`
    super
  end
end

module Bundler
  class GemHelper
    prepend CustomBuild
  end
end

run_spec = proc do |backend|
  begin
    ENV["MESSAGE_BUS_BACKEND"] = backend
    sh "#{FileUtils::RUBY} -e \"ARGV.each{|f| load f}\" #{Dir['spec/**/*_spec.rb'].to_a.join(' ')}"
  ensure
    ENV.delete("MESSAGE_BUS_BACKEND")
  end
end

task spec: [:spec_memory, :spec_redis, :spec_postgres, :spec_client_js, :rubocop, :test_doc]

task spec_client_js: "jasmine:ci"

task :spec_redis do
  run_spec.call("redis")
end

task :spec_memory do
  run_spec.call("memory")
end

task :spec_postgres do
  run_spec.call("postgres")
end
