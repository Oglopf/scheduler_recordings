# frozen_string_literal: true

require 'open3'
require 'minitest/mock'
require_relative '../scheduler_recordings'

module SchedulerRecordings
  # Minitest helpers. Include in a test class:
  #
  #   class KubernetesRecordedTest < Minitest::Test
  #     include SchedulerRecordings::Minitest
  #
  #     def test_running_pod
  #       with_recording('kubernetes/running_pod', step: :info, kubeconfig: '/k8s.yml') do |recording|
  #         info = adapter.info(recording.facts['id'])
  #         assert_equal(:running, info.status.to_sym)
  #       end
  #     end
  #   end
  #
  # Open3.capture3 is replaced for the length of the block; any command the
  # recording doesn't have raises SchedulerRecordings::UnrecordedCall.
  module Minitest
    # recording is a name ("kubernetes/v1.31.2/running_pod") or a Recording.
    # step limits replay to the calls recorded in that step. The remaining
    # keywords fill the recording's {{vars}}. Yields the Recording and Player.
    def with_recording(recording, step: nil, **vars)
      recording = SchedulerRecordings.load(recording) unless recording.is_a?(Recording)
      player = Player.new(recording, vars: vars, step: step)
      replay = ->(*args, **options) { player.capture3(*args, **options) }
      Open3.stub(:capture3, replay) { yield recording, player }
    end

    # Fails unless every recorded call of the step was replayed.
    def assert_all_played(player)
      unplayed = player.unplayed.map { |call| CommandLine.display(call.command) }
      assert_empty(unplayed, "recorded calls the test never made:\n  #{unplayed.join("\n  ")}")
    end
  end
end
