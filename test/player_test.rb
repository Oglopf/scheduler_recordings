# frozen_string_literal: true

require_relative 'test_helper'

class PlayerTest < Minitest::Test
  include TestHelper

  def test_answers_a_recorded_command
    player = SchedulerRecordings::Player.new(recording([{ command: 'qstat -f', stdout: 'Job Id: 1' }]))
    out, err, status = player.capture3('qstat -f')

    assert_equal('Job Id: 1', out)
    assert_equal('', err)
    assert_predicate(status, :success?)
    assert_equal(0, status.exitstatus)
  end

  def test_replays_failures_with_their_exit_status_and_stderr
    player = SchedulerRecordings::Player.new(recording([{ command: 'qdel 9', stderr: 'Unknown Job Id', exit: 153 }]))
    _out, err, status = player.capture3('qdel 9')

    assert_equal('Unknown Job Id', err)
    refute_predicate(status, :success?)
    assert_equal(153, status.exitstatus)
  end

  def test_argv_calls_match_recorded_argv_whatever_the_env
    player = SchedulerRecordings::Player.new(recording([{ command: %w[qstat -f -t], stdout: 'ok' }]))

    assert_equal('ok', player.capture3({ 'PBS_SERVER' => 'x' }, 'qstat', '-f', '-t').first)
  end

  def test_argv_and_string_forms_are_different_commands
    player = SchedulerRecordings::Player.new(recording([{ command: %w[qstat -f -t] }]))
    error = assert_raises(SchedulerRecordings::UnrecordedCall) { player.capture3('qstat -f -t') }

    assert_match(/Closest recorded command:\n  qstat -f -t/, error.message)
  end

  def test_repeated_commands_answer_in_recorded_order
    calls = [{ command: 'get pod a', stdout: 'Pending' }, { command: 'get pod a', stdout: 'Running' }]
    player = SchedulerRecordings::Player.new(recording(calls))

    assert_equal(%w[Pending Running], [player.capture3('get pod a').first, player.capture3('get pod a').first])
  end

  def test_different_commands_can_come_in_any_order
    calls = [{ command: 'one', stdout: '1' }, { command: 'two', stdout: '2' }]
    player = SchedulerRecordings::Player.new(recording(calls))

    assert_equal('2', player.capture3('two').first)
    assert_equal('1', player.capture3('one').first)
  end

  def test_unrecorded_command_raises_and_names_the_closest_recorded_one
    player = SchedulerRecordings::Player.new(recording([{ command: 'kubectl get pod abc' }, { command: 'qstat' }]))
    error = assert_raises(SchedulerRecordings::UnrecordedCall) { player.capture3('kubectl get pod xyz') }

    assert_match(/not in the recording/, error.message)
    assert_match(/kubectl get pod abc/, error.message)
  end

  def test_running_a_command_more_times_than_recorded_raises
    player = SchedulerRecordings::Player.new(recording([{ command: 'qstat' }]))
    player.capture3('qstat')
    error = assert_raises(SchedulerRecordings::UnrecordedCall) { player.capture3('qstat') }

    assert_match(/already been used/, error.message)
  end

  def test_fills_vars_in_commands_and_output
    calls = [{ command: '{{kubectl}} --kubeconfig={{kubeconfig}} get pods', stdout: 'config at {{kubeconfig}}' }]
    player = SchedulerRecordings::Player.new(recording(calls, vars: %w[kubeconfig kubectl]),
                                             vars: { kubeconfig: '/k.yml', kubectl: '/bin/kubectl' })

    assert_equal('config at /k.yml', player.capture3('/bin/kubectl --kubeconfig=/k.yml get pods').first)
  end

  def test_missing_vars_are_an_error_up_front
    error = assert_raises(ArgumentError) do
      SchedulerRecordings::Player.new(recording([], vars: %w[kubeconfig]))
    end

    assert_match(/kubeconfig: \.\.\./, error.message)
  end

  def test_step_limits_replay_to_that_steps_calls
    calls = [{ step: 'submit', command: 'qsub', stdout: '1.pbs' }, { step: 'info', command: 'qstat', stdout: 'R' }]
    player = SchedulerRecordings::Player.new(recording(calls), step: :info)

    assert_equal('R', player.capture3('qstat').first)
    assert_raises(SchedulerRecordings::UnrecordedCall) { player.capture3('qsub') }
  end

  def test_unknown_step_is_an_error
    assert_raises(ArgumentError) { SchedulerRecordings::Player.new(recording([{ command: 'x' }]), step: :nope) }
  end

  def test_tracks_played_unplayed_and_what_was_sent
    calls = [{ command: 'create -f -', stdin: 'recorded yaml' }, { command: 'get pods' }]
    player = SchedulerRecordings::Player.new(recording(calls))
    player.capture3('create -f -', stdin_data: 'new yaml')

    assert_equal(['create -f -'], player.played.map(&:command))
    assert_equal(['get pods'], player.unplayed.map(&:command))
    assert_equal([['create -f -', 'new yaml']], player.requests)
  end
end
