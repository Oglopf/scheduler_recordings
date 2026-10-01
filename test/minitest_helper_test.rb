# frozen_string_literal: true

require_relative 'test_helper'

class MinitestHelperTest < Minitest::Test
  include TestHelper
  include SchedulerRecordings::Minitest

  def test_with_recording_answers_open3_for_the_block_only
    fake = recording([{ command: 'qstat', stdout: 'replayed' }])
    with_recording(fake) do |_recording, _player|
      assert_equal('replayed', Open3.capture3('qstat').first)
    end

    assert_equal("real\n", Open3.capture3('echo', 'real').first)
  end

  def test_with_recording_loads_by_name_and_fills_vars
    with_recording('kubernetes/not_found', step: :info, kubectl: 'kubectl', kubeconfig: '/k8s.yml') do |recording, player|
      id = recording.facts.fetch('id')
      _out, err, status = Open3.capture3("kubectl --kubeconfig=/k8s.yml --namespace=ood -o json get pod #{id}")

      refute_predicate(status, :success?)
      assert_match(/NotFound/, err)
      assert_all_played(player)
    end
  end

  def test_assert_all_played_names_what_was_skipped
    with_recording(recording([{ command: 'qstat' }, { command: 'qdel 1' }])) do |_recording, player|
      Open3.capture3('qstat')
      error = assert_raises(Minitest::Assertion) { assert_all_played(player) }

      assert_match(/qdel 1/, error.message)
    end
  end
end
