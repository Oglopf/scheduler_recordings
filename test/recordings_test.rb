# frozen_string_literal: true

require_relative 'test_helper'

# Checks the library's lookups and that every recording this gem ships is
# well formed, so a bad re-record fails here rather than in someone's tests.
class RecordingsTest < Minitest::Test
  RECORDINGS = Dir[File.join(SchedulerRecordings::ROOT, '*', '*', '*.jsonl')].sort

  def test_ships_recordings
    refute_empty(RECORDINGS)
    assert_includes(SchedulerRecordings.schedulers, 'kubernetes')
  end

  def test_every_recording_loads_with_a_complete_header
    RECORDINGS.each do |path|
      recording = SchedulerRecordings::Recording.load(path)
      scheduler, version, scenario = path.split('/').last(3)

      assert_equal(scheduler, recording.scheduler, path)
      assert_equal(version, recording.scheduler_version, path)
      assert_equal(File.basename(scenario, '.jsonl'), recording.scenario, path)
      %w[description versions recorded_with identity].each do |key|
        assert(recording.header[key], "#{path} has no #{key}")
      end
      refute_empty(recording.calls, path)
    end
  end

  def test_every_call_is_complete_and_uses_only_declared_vars
    RECORDINGS.each do |path|
      recording = SchedulerRecordings::Recording.load(path)
      recording.calls.each_with_index do |call, index|
        where = "#{path} call #{index + 1}"
        assert_kind_of(String, call.step, where)
        assert_kind_of(Integer, call.exit, where)
        Time.iso8601(call.at)
        text = [SchedulerRecordings::CommandLine.display(call.command), call.stdin, call.stdout, call.stderr].join
        used = text.scan(/\{\{(\w+)\}\}/).flatten.uniq
        assert_empty(used - recording.vars, "#{where} uses undeclared vars")
      end
    end
  end

  def test_recordings_do_not_leak_the_recording_machine
    RECORDINGS.each do |path|
      text = File.read(path, encoding: 'UTF-8')
      refute_match(%r{/etc/rancher|/home/runner|/root/|\.kube/config}, text, path)
    end
  end

  def test_versions_sort_numerically
    Dir.mktmpdir do |dir|
      %w[v1.9.0 v1.31.2 v1.30.6].each { |v| FileUtils.mkdir_p(File.join(dir, 'kubernetes', v)) }
      SchedulerRecordings.root = dir

      assert_equal(%w[v1.9.0 v1.30.6 v1.31.2], SchedulerRecordings.versions('kubernetes'))
    ensure
      SchedulerRecordings.root = nil
    end
  end

  def test_short_names_mean_the_newest_version
    newest = SchedulerRecordings.versions('kubernetes').last

    assert_equal(SchedulerRecordings.path("kubernetes/#{newest}/running_pod"),
                 SchedulerRecordings.path('kubernetes/running_pod'))
  end

  def test_unknown_recordings_are_an_error
    assert_raises(ArgumentError) { SchedulerRecordings.path('kubernetes/v0.0.1/running_pod') }
    assert_raises(ArgumentError) { SchedulerRecordings.path('kubernetes') }
  end

  def test_each_yields_a_scenario_across_versions
    recordings = SchedulerRecordings.each('kubernetes', 'running_pod').to_a

    assert_equal(SchedulerRecordings.versions('kubernetes').length, recordings.length)
    assert(recordings.all? { |r| r.scenario == 'running_pod' })
  end

  def test_time_of_a_step
    recording = SchedulerRecordings.load('kubernetes/running_pod')

    assert_equal(Time.iso8601(recording.calls_for(:info).first.at), recording.time_of(:info))
  end
end
