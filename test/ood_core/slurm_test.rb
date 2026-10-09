# frozen_string_literal: true

# Replays every Slurm recording through Open OnDemand's own slurm adapter,
# with no cluster. Needs ood_core loadable:
#
#   OOD_CORE=../ood_core bundle exec rake test:ood_core
#
# Status assertions pin the adapter's current mapping, including the parts
# under discussion in OSC/ood_core#977 (a held job is :queued, not
# :queued_held), so a change to that mapping shows up here.

require_relative '../test_helper'
require 'scheduler_recordings/backends/slurm'

begin
  require 'ood_core'
  require 'ood_core/job/adapters/slurm'
rescue LoadError => e
  # Pointed at an ood_core on purpose (OOD_CORE, as CI does): a load failure
  # is a broken setup, not a reason to report 0 runs as a pass.
  raise if ENV['OOD_CORE']

  warn("skipping slurm replay tests: #{e.message}")
  return
end

class SlurmReplayTest < Minitest::Test
  include SchedulerRecordings::Minitest

  # Stand-ins for the recording user's {{placeholders}}.
  VARS = { user: 'ood', group: 'oodgroup', home: '/home/ood', account: 'PZS0000' }.freeze

  def adapter
    OodCore::Job::Factory.build(adapter: 'slurm')
  end

  def replay(recording, step)
    with_recording(recording, step: step, **VARS) do |_recording, player|
      result = yield player
      assert_all_played(player)
      result
    end
  end

  # Runs the block once per recorded Slurm version of a scenario.
  def each_version(scenario, &block)
    recordings = SchedulerRecordings.each('slurm', scenario).to_a
    skip("no slurm recordings of #{scenario} yet") if recordings.empty?

    recordings.each(&block)
  end

  def info_of(recording)
    replay(recording, :info) { adapter.info(recording.facts.fetch('id')) }
  end

  def assert_status(expected, scenario)
    each_version(scenario) do |recording|
      info = info_of(recording)
      assert_equal(expected, info.status.to_sym, "#{recording.name}: #{recording.facts}")
      assert_equal(recording.facts['id'], info.id, recording.name)
      assert_equal(VARS[:user], info.job_owner, recording.name)
    end
  end

  def test_running_job_is_running
    assert_status(:running, 'running_job')
  end

  # Slurm says PENDING (reason JobHeldUser); the adapter has no held state.
  def test_held_job_is_queued
    assert_status(:queued, 'held_job')
  end

  def test_job_waiting_on_a_dependency_is_queued
    assert_status(:queued, 'dependent_job')
  end

  def test_released_job_is_running
    assert_status(:running, 'released_job')
  end

  def test_finished_jobs_are_completed_in_squeue_and_accounting
    %w[completed_job failed_job timeout_job canceled_job].each do |scenario|
      each_version(scenario) do |recording|
        assert_equal(:completed, info_of(recording).status.to_sym, recording.name)

        historic = replay(recording, :info_historic) do
          adapter.info_historic(opts: { job_ids: [recording.facts.fetch('id')] })
        end
        assert_equal([recording.facts['id']], historic.map(&:id), recording.name)
        assert_equal(:completed, historic.first.status.to_sym, recording.name)
        assert_equal(recording.facts['state'], historic.first.native[:state].split.first, recording.name)
      end
    end
  end

  def test_status_agrees_with_info
    %w[running_job held_job dependent_job completed_job failed_job timeout_job canceled_job].each do |scenario|
      each_version(scenario) do |recording|
        status = replay(recording, :status) { adapter.status(recording.facts.fetch('id')) }
        assert_equal(info_of(recording).status, status, recording.name)
      end
    end
  end

  def test_info_where_owner_finds_the_users_jobs
    each_version('several_jobs') do |recording|
      ids = replay(recording, :info_where_owner) { adapter.info_where_owner(VARS[:user]).map(&:id) }
      recording.facts['ids'].each_value { |id| assert_includes(ids, id, recording.name) }
    end
  end

  def test_unknown_job_is_completed_and_holding_or_deleting_it_is_quiet
    each_version('not_found') do |recording|
      id = recording.facts.fetch('id')
      assert_equal(:completed, info_of(recording).status.to_sym, recording.name)
      replay(recording, :hold) { adapter.hold(id) }
      replay(recording, :delete) { adapter.delete(id) }
    end
  end

  def test_submit_sends_the_recorded_job_and_returns_its_id
    %w[running_job held_job completed_job failed_job timeout_job].each do |scenario|
      each_version(scenario) do |recording|
        id = replay(recording, :submit) { adapter.submit(script(recording)) }
        assert_equal(recording.facts['id'], id, recording.name)
      end
    end
  end

  def test_submit_with_a_dependency
    each_version('dependent_job') do |recording|
      id = replay(recording, :submit) do
        adapter.submit(script(recording), afterok: recording.facts.fetch('afterok'))
      end
      assert_equal(recording.facts['id'], id, recording.name)
    end
  end

  def test_rejected_submit_raises_an_adapter_error
    each_version('invalid_submit') do |recording|
      replay(recording, :submit) do
        assert_raises(OodCore::JobAdapterError) { adapter.submit(script(recording)) }
      end
    end
  end

  private

  # The script the scenario submitted: the recorder's defaults, with the
  # account placeholder's stand-in, plus the scenario's own options.
  def script(recording)
    defaults = SchedulerRecordings::Backends::Slurm.script_defaults(
      account: VARS[:account], partition: recording.facts.fetch('partition')
    )
    options = recording.facts.fetch('script').transform_keys(&:to_sym)
    OodCore::Job::Script.new(**defaults.merge(options))
  end
end
