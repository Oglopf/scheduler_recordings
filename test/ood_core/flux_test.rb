# frozen_string_literal: true

# Replays every Flux recording through Open OnDemand's own flux adapter,
# with no Flux instance. Needs an ood_core that has the flux adapter:
#
#   OOD_CORE=../ood_core bundle exec rake test:ood_core
#
# Assertions stick to what's unambiguous about each real state; questions
# about the adapter's mapping belong in ood_core.

require_relative '../test_helper'
require 'etc'
require 'scheduler_recordings/backends/flux'

begin
  require 'ood_core'
  require 'ood_core/job/adapters/flux'
rescue LoadError => e
  # Pointed at an ood_core on purpose (OOD_CORE, as CI does): a load failure
  # is a broken setup, not a reason to report 0 runs as a pass.
  raise if ENV['OOD_CORE']

  warn("skipping flux replay tests: #{e.message}")
  return
end

class FluxReplayTest < Minitest::Test
  include SchedulerRecordings::Minitest

  FLUX = '/usr/bin/flux'
  VARS = { flux: FLUX }.freeze

  def adapter
    OodCore::Job::Factory.build(adapter: 'flux', bin_overrides: { 'flux' => FLUX })
  end

  # Replays one step as the user the recording was made as, so the
  # environment the adapter builds for a submit matches what was sent.
  def replay(recording, step)
    account = SchedulerRecordings::Backends::Flux.account(recording.header['identity'])
    Etc.stub(:getpwuid, account) do
      with_recording(recording, step: step, **VARS) do |_recording, player|
        result = yield player
        assert_all_played(player)
        result
      end
    end
  end

  # Runs the block once per recorded Flux version of a scenario.
  def each_version(scenario, &block)
    recordings = SchedulerRecordings.each('flux', scenario).to_a
    skip("no flux recordings of #{scenario} yet") if recordings.empty?

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
      assert_equal(recording.header['identity']['user'], info.job_owner, recording.name)
    end
  end

  def test_running_job_is_running
    assert_status(:running, 'running_job')
  end

  def test_held_job_is_queued_held
    assert_status(:queued_held, 'held_job')
  end

  def test_job_waiting_on_a_dependency_is_queued
    assert_status(:queued, 'dependent_job')
  end

  def test_released_job_is_running
    assert_status(:running, 'released_job')
  end

  def test_finished_jobs_are_completed_and_keep_flux_result
    %w[completed_job failed_job timeout_job].each do |scenario|
      each_version(scenario) do |recording|
        info = info_of(recording)
        assert_equal(:completed, info.status.to_sym, recording.name)
        assert_equal(recording.facts['result'], info.native[:result], recording.name)
        assert_equal(recording.facts['returncode'], info.native[:returncode], recording.name)
      end
    end
  end

  def test_canceled_job_is_completed
    assert_status(:completed, 'canceled_job')
  end

  def test_status_agrees_with_info
    %w[running_job held_job dependent_job completed_job failed_job timeout_job canceled_job].each do |scenario|
      each_version(scenario) do |recording|
        status = replay(recording, :status) { adapter.status(recording.facts.fetch('id')) }
        assert_equal(info_of(recording).status, status, recording.name)
      end
    end
  end

  def test_running_job_has_its_node_and_cores
    each_version('running_job') do |recording|
      info = info_of(recording)
      refute_empty(info.allocated_nodes.map(&:name).reject(&:empty?), recording.name)
      assert_operator(info.procs.to_i, :>, 0, recording.name)
    end
  end

  def test_info_all_lists_the_users_jobs
    each_version('several_jobs') do |recording|
      ids = replay(recording, :info_all) { adapter.info_all.map(&:id) }
      assert_equal(recording.facts['ids'].values.sort, ids.sort, recording.name)
    end
  end

  def test_info_where_owner_finds_the_users_jobs
    each_version('several_jobs') do |recording|
      owner = recording.header['identity']['user']
      jobs = replay(recording, :info_where_owner) { adapter.info_where_owner(owner) }
      assert_equal(2, jobs.length, recording.name)
    end
  end

  def test_no_active_jobs_lists_nothing
    each_version('no_jobs') do |recording|
      assert_empty(replay(recording, :info_all) { adapter.info_all }, recording.name)
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
        error = assert_raises(OodCore::JobAdapterError) { adapter.submit(script(recording)) }
        assert_equal(recording.facts['message'], error.message.strip, recording.name)
      end
    end
  end

  private

  # The script the scenario submitted, rebuilt from the options it recorded.
  # Same defaults as Backends::Flux#script.
  def script(recording)
    defaults = { content: 'sleep 600', workdir: '/tmp' }
    options = defaults.merge(recording.facts.fetch('script').transform_keys(&:to_sym))
    OodCore::Job::Script.new(**options)
  end
end
