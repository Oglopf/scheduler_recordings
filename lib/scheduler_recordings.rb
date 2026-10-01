# frozen_string_literal: true

require_relative 'scheduler_recordings/version'
require_relative 'scheduler_recordings/command_line'
require_relative 'scheduler_recordings/recording'
require_relative 'scheduler_recordings/player'

# Real scheduler output, recorded by running Open OnDemand's own adapters
# against real schedulers, for replay in tests.
#
#   SchedulerRecordings.versions('kubernetes')            # => ["v1.31.2", ...]
#   SchedulerRecordings.load('kubernetes/v1.31.2/running_pod')
#   SchedulerRecordings.each('kubernetes', 'running_pod') { |recording| ... }
#
# For minitest, require 'scheduler_recordings/minitest'.
module SchedulerRecordings
  ROOT = File.expand_path('../recordings', __dir__)

  # Recordings are made after srand(SEED), so job IDs an adapter generates at
  # random come out the same every time. Call srand(recording.seed) before
  # replaying a submit to get the recorded ID.
  SEED = 20_261_001

  module_function

  # Where recordings are read from. Defaults to the ones shipped in this gem;
  # point it at your own directory to replay recordings from your site.
  def root
    @root || ENV['SCHEDULER_RECORDINGS_ROOT'] || ROOT
  end

  def root=(path)
    @root = path
  end

  def schedulers
    children(root)
  end

  # Recorded versions of a scheduler, oldest first.
  def versions(scheduler)
    children(File.join(root, scheduler)).sort_by { |version| version_key(version) }
  end

  def scenarios(scheduler, version = versions(scheduler).last)
    Dir[File.join(root, scheduler, version.to_s, '*.jsonl')].map { |path| File.basename(path, '.jsonl') }.sort
  end

  # name is "scheduler/version/scenario", or "scheduler/scenario" for the
  # newest recorded version.
  def path(name)
    parts = name.to_s.split('/')
    parts.insert(1, versions(parts.first).last.to_s) if parts.length == 2
    raise ArgumentError, "expected scheduler/version/scenario, got #{name.inspect}" unless parts.length == 3

    file = File.join(root, *parts) + '.jsonl'
    return file if File.exist?(file)

    raise ArgumentError, "no recording #{parts.join('/')} under #{root}"
  end

  def load(name)
    Recording.load(path(name))
  end

  # Every recorded version of one scenario, oldest first. Versions that
  # don't have the scenario are skipped.
  def each(scheduler, scenario)
    return enum_for(:each, scheduler, scenario) unless block_given?

    versions(scheduler).each do |version|
      file = File.join(root, scheduler, version, "#{scenario}.jsonl")
      yield Recording.load(file) if File.exist?(file)
    end
  end

  def children(dir)
    return [] unless Dir.exist?(dir)

    Dir.children(dir).select { |entry| File.directory?(File.join(dir, entry)) }.sort
  end

  # "v1.31.2+k3s1" sorts as [1, 31, 2]; anything else sorts after numbers.
  def version_key(version)
    numbers = version.to_s.scan(/\d+/).first(3).map(&:to_i)
    [numbers, version.to_s]
  end
end
