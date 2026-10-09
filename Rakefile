# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/*_test.rb']
end

namespace :test do
  # Replays the recordings through ood_core's adapters. Needs ood_core:
  #   OOD_CORE=../ood_core rake test:ood_core
  Rake::TestTask.new(:ood_core) do |t|
    t.libs << 'lib' << 'test'
    t.libs << File.join(ENV['OOD_CORE'], 'lib') if ENV['OOD_CORE']
    t.test_files = FileList['test/ood_core/*_test.rb']
    # Warnings here come from ood_core and its gems, not this one.
    t.warning = false
  end
end

task default: :test
