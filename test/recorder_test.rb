# frozen_string_literal: true

require_relative 'test_helper'
require 'scheduler_recordings/recorder'
require 'tmpdir'

class RecorderTest < Minitest::Test
  include TestHelper

  def test_records_real_commands_inside_record_blocks_only
    recorder = SchedulerRecordings::Recorder.new
    Open3.capture3('echo', 'before')
    recorder.record(:main) { Open3.capture3('echo', 'inside') }
    Open3.capture3('echo', 'after')

    assert_equal([%w[echo inside]], recorder.calls.map(&:command))
    assert_equal("inside\n", recorder.calls.first.stdout)
    assert_equal('main', recorder.calls.first.step)
  end

  def test_records_stdin_stderr_and_exit_status
    recorder = SchedulerRecordings::Recorder.new
    recorder.record(:main) do
      Open3.capture3('sh', '-c', 'cat; echo oops >&2; exit 3', stdin_data: 'hello')
    end
    call = recorder.calls.first

    assert_equal('hello', call.stdin)
    assert_equal('hello', call.stdout)
    assert_equal("oops\n", call.stderr)
    assert_equal(3, call.exit)
  end

  def test_record_returns_the_blocks_value_and_passes_real_output_through
    recorder = SchedulerRecordings::Recorder.new
    out, _err, status = recorder.record(:main) { Open3.capture3('echo', 'hi') }

    assert_equal("hi\n", out)
    assert_predicate(status, :success?)
  end

  def test_redacts_machine_specific_text_to_placeholders
    recorder = SchedulerRecordings::Recorder.new(redact: { '/home/me/.kube/config' => 'kubeconfig' })
    recorder.record(:main) { Open3.capture3('echo', '--kubeconfig=/home/me/.kube/config') }
    call = recorder.calls.first

    assert_equal(['echo', '--kubeconfig={{kubeconfig}}'], call.command)
    assert_equal("--kubeconfig={{kubeconfig}}\n", call.stdout)
    assert_equal(['kubeconfig'], recorder.vars)
  end

  def test_longer_redactions_win_over_their_prefixes
    recorder = SchedulerRecordings::Recorder.new(redact: { '/k' => 'short', '/k/config' => 'long' })
    recorder.record(:main) { Open3.capture3('echo /k/config /k') }

    assert_equal("{{long}} {{short}}\n", recorder.calls.first.stdout)
  end

  def test_saved_recording_replays_what_was_recorded
    recorder = SchedulerRecordings::Recorder.new(redact: { Dir.tmpdir => 'tmp' })
    recorder.record(:list) { Open3.capture3("ls -d #{Dir.tmpdir}") }
    recorder.record(:fail) { Open3.capture3('sh -c "echo no >&2; exit 4"') }

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'r.jsonl')
      recorder.to_recording('scheduler' => 'fake', 'scenario' => 'roundtrip').write(path)
      player = SchedulerRecordings::Player.new(SchedulerRecordings::Recording.load(path), vars: { tmp: '/scratch' })

      assert_equal("/scratch\n", player.capture3('ls -d /scratch').first)
      _out, err, status = player.capture3('sh -c "echo no >&2; exit 4"')
      assert_equal(["no\n", 4], [err, status.exitstatus])
    end
  end

  def test_recorders_do_not_leak_between_threads
    recorder = SchedulerRecordings::Recorder.new
    recorder.record(:main) do
      Thread.new { Open3.capture3('echo', 'other thread') }.join
      Open3.capture3('echo', 'this thread')
    end

    assert_equal([['echo', 'this thread']], recorder.calls.map(&:command))
  end
end
