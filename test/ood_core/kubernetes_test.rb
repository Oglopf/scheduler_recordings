# frozen_string_literal: true

# Replays every Kubernetes recording through Open OnDemand's own adapter,
# with no cluster. Needs ood_core loadable:
#
#   OOD_CORE=../ood_core bundle exec rake test:ood_core
#
# This is the loop the recordings exist for, and a template for tests in
# ood_core itself. Assertions stick to what's unambiguous about each real
# state; questions about the adapter's mapping belong in ood_core.

require_relative '../test_helper'
require 'scheduler_recordings/backends/kubernetes'

begin
  require 'ood_core'
rescue LoadError => e
  # Pointed at an ood_core on purpose (OOD_CORE, as CI does): a load failure
  # is a broken setup, not a reason to report 0 runs as a pass.
  raise if ENV['OOD_CORE']

  warn("skipping ood_core replay tests: #{e.message}")
  return
end

class KubernetesReplayTest < Minitest::Test
  include SchedulerRecordings::Minitest

  KUBECTL = '/usr/bin/kubectl'
  KUBECONFIG = '/etc/ood/k8s.yml'
  VARS = { kubectl: KUBECTL, kubeconfig: KUBECONFIG }.freeze

  def adapter(recording)
    built = OodCore::Job::Factory.build(adapter: 'kubernetes', config_file: KUBECONFIG, bin: KUBECTL)
    SchedulerRecordings::Backends::Kubernetes.pin_identity(built.batch, recording.header['identity'])
    built
  end

  # Runs the block once per recorded Kubernetes version of a scenario.
  def each_version(scenario, &block)
    recordings = SchedulerRecordings.each('kubernetes', scenario).to_a
    refute_empty(recordings, "no kubernetes recordings of #{scenario}")
    recordings.each(&block)
  end

  def info_of(recording)
    with_recording(recording, step: :info, **VARS) do |_recording, player|
      info = adapter(recording).info(recording.facts.fetch('id'))
      assert_all_played(player)
      info
    end
  end

  def assert_status(expected, scenario)
    each_version(scenario) do |recording|
      info = info_of(recording)
      assert_equal(expected, info.status.to_sym, "#{recording.name}: #{recording.facts}")
      assert_equal(recording.facts['id'], info.id, recording.name)
      assert_equal(recording.header['identity']['user'], info.job_owner, recording.name)
    end
  end

  def test_running_and_ready_pod_is_running
    assert_status(:running, 'running_pod')
  end

  def test_pending_pod_is_queued
    assert_status(:queued, 'queued_pod')
  end

  def test_unschedulable_pod_is_held
    assert_status(:queued_held, 'unschedulable_pod')
  end

  def test_pod_that_exited_zero_is_completed
    assert_status(:completed, 'completed_pod')
  end

  def test_status_agrees_with_info
    %w[running_pod queued_pod completed_pod error_pod].each do |scenario|
      each_version(scenario) do |recording|
        status = with_recording(recording, step: :status, **VARS) do
          adapter(recording).status(recording.facts.fetch('id'))
        end
        assert_equal(info_of(recording).status, status, recording.name)
      end
    end
  end

  def test_every_pod_state_parses_without_error
    %w[running_pod running_pod_not_ready queued_pod unschedulable_pod completed_pod
       error_pod crash_loop_pod image_error_pod].each do |scenario|
      each_version(scenario) { |recording| assert_kind_of(OodCore::Job::Info, info_of(recording)) }
    end
  end

  def test_info_all_lists_the_users_pods
    each_version('several_pods') do |recording|
      ids = with_recording(recording, step: :info_all, **VARS) { adapter(recording).info_all.map(&:id) }
      assert_equal(recording.facts['ids'].values.sort, ids.sort, recording.name)
    end
  end

  def test_info_where_owner_finds_the_users_pods
    each_version('several_pods') do |recording|
      owner = recording.header['identity']['user']
      jobs = with_recording(recording, step: :info_where_owner, **VARS) { adapter(recording).info_where_owner(owner) }
      assert_equal(2, jobs.length, recording.name)
    end
  end

  def test_no_pods_lists_nothing
    each_version('empty_namespace') do |recording|
      assert_empty(with_recording(recording, **VARS) { adapter(recording).info_all })
    end
  end

  def test_unknown_pod_is_reported_completed_and_deleting_it_is_quiet
    each_version('not_found') do |recording|
      assert_equal(:completed, info_of(recording).status.to_sym, recording.name)
      with_recording(recording, step: :delete, **VARS) do |_recording, player|
        adapter(recording).delete(recording.facts.fetch('id'))
        assert_all_played(player)
      end
    end
  end

  def test_submit_sends_the_recorded_pod_and_returns_its_id
    skip_unless_kubernetes_can_submit
    each_version('running_pod') do |recording|
      with_recording(recording, step: :submit, **VARS) do |_recording, player|
        srand(recording.seed)
        id = adapter(recording).submit(script(recording))

        assert_equal(recording.facts['id'], id, recording.name)
        sent = player.requests.first.last
        assert_equal(player.played.first.stdin, sent, "#{recording.name}: the submitted pod changed")
      end
    end
  end

  def test_rejected_submit_raises_an_adapter_error
    skip_unless_kubernetes_can_submit
    each_version('invalid_submit') do |recording|
      with_recording(recording, step: :submit, **VARS) do
        srand(recording.seed)
        error = assert_raises(OodCore::JobAdapterError) do
          adapter(recording).submit(script(recording))
        end
        assert_match(/quantities must match/, error.message)
      end
    end
  end

  private

  # ood_core's Kubernetes adapter uses ERB without requiring it (see the
  # README's known limits), so submit raises NameError in a plain Ruby
  # process. Skip, naming the bug, until ood_core requires it; these tests
  # run again on their own once it does.
  def skip_unless_kubernetes_can_submit
    skip("ood_core's kubernetes adapter uses ERB without requiring it") unless defined?(::ERB)
  end

  # The script the scenario submitted, from the native spec it recorded.
  def script(recording)
    OodCore::Job::Script.new(content: 'recorded by scheduler_recordings', native: symbolize(recording.facts.fetch('native')))
  end

  def symbolize(value)
    case value
    when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_sym] = symbolize(v) }
    when Array then value.map { |v| symbolize(v) }
    else value
    end
  end
end
