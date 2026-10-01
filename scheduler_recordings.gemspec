# frozen_string_literal: true

require_relative 'lib/scheduler_recordings/version'

Gem::Specification.new do |spec|
  spec.name          = 'scheduler_recordings'
  spec.version       = SchedulerRecordings::VERSION
  spec.authors       = ['Travis Ravert']
  spec.email         = ['travert@osc.edu']
  spec.summary       = "Real scheduler output, recorded through Open OnDemand's adapters, for replay in tests"
  spec.description   = <<~DESC
    Recordings of what Open OnDemand's ood_core scheduler adapters send to and
    get back from real schedulers, made by running the adapters themselves
    against real clusters, plus a minitest helper that replays them by
    stubbing Open3.capture3. Test adapter code against many scheduler
    versions without a cluster.
  DESC
  spec.homepage      = 'https://github.com/Oglopf/scheduler_recordings'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 2.7'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*.rb', 'recordings/**/*.jsonl', 'exe/*', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.bindir = 'exe'
  spec.executables = ['scheduler-recordings']
  spec.require_paths = ['lib']
end
