# frozen_string_literal: true

# Slurm scenarios, written to be safe on a production cluster: see
# Backends::Slurm for the limits every job runs under. None of them record
# info_all, which lists every user's jobs.
#
# Finished-job scenarios record both views OnDemand has of a finished job:
# squeue (info), which keeps it for a few minutes after it ends, and the
# accounting database (info_historic). Each saves the accounting database's
# own state and exit code as facts.
module SchedulerRecordings
  module Scenarios
    module Slurm
      SCHEDULER = 'slurm'

      # Scenario options are saved as a fact, without the backend's defaults
      # (which include the real account), so a replay can rebuild the script.
      def self.submit(s, step: :submit, **options)
        script = s.script(**options)
        s.fact(step == :submit ? 'script' : "script_#{step}", options)
        s.fact('partition', s.backend.partition)
        s.record(step) { s.adapter.submit(script) }
      end

      def self.wait_for_state(s, id, *states)
        s.wait_until("job #{id} is #{states.join(' or ')}", interval: s.backend.poll_interval) do
          states.include?(s.backend.state(id))
        end
      end

      def self.observe(s, id)
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
      end

      def self.finished_job(s, expected_state, **options)
        id = submit(s, **options)
        s.fact('id', id)
        accounting = s.wait_until("the accounting database has job #{id} finished", interval: s.backend.poll_interval) do
          found = s.backend.accounting(id)
          found if found && !%w[PENDING RUNNING COMPLETING].include?(found.first)
        end
        s.fact('state', accounting.first)
        s.fact('exit_code', accounting.last)
        raise "expected #{expected_state}, the accounting database says #{accounting.first}" unless accounting.first == expected_state

        observe(s, id)
        s.record(:info_historic) { s.adapter.info_historic(opts: { job_ids: [id] }) }
      end

      # First, so the queue holds as little as possible of earlier scenarios.
      Scenario.define(SCHEDULER, 'several_jobs', 'One running job and one held job, listed by owner') do |s|
        others = s.backend.other_jobs
        unless others.empty?
          raise "you have #{others.length} other job(s) in squeue (#{others.join(' ')}); listing your jobs " \
                'would record them. Run this scenario when you have none, or leave it out with --only.'
        end

        running = submit(s)
        held = submit(s, step: :submit_held, submit_as_hold: true)
        wait_for_state(s, running, 'RUNNING')
        s.fact('ids', { 'running' => running, 'held' => held })
        s.record(:info_where_owner) { s.adapter.info_where_owner(s.backend.user.name) }
      end

      Scenario.define(SCHEDULER, 'running_job', 'A job that is running') do |s|
        id = submit(s)
        s.fact('id', id)
        wait_for_state(s, id, 'RUNNING')
        s.fact('state', 'RUNNING')
        observe(s, id)
      end

      Scenario.define(SCHEDULER, 'held_job', 'A job submitted on hold') do |s|
        id = submit(s, submit_as_hold: true)
        s.fact('id', id)
        wait_for_state(s, id, 'PENDING')
        s.fact('state', 'PENDING')
        s.fact('reason', s.backend.reason(id))
        observe(s, id)
      end

      Scenario.define(SCHEDULER, 'dependent_job', 'A job waiting on a dependency (afterok on a held job)') do |s|
        held = submit(s, step: :submit_held, submit_as_hold: true)
        s.fact('held_id', held)
        s.fact('script', {})
        s.fact('afterok', held)
        id = s.record(:submit) { s.adapter.submit(s.script, afterok: held) }
        s.fact('id', id)
        wait_for_state(s, id, 'PENDING')
        s.fact('state', 'PENDING')
        s.fact('reason', s.backend.reason(id))
        observe(s, id)
      end

      Scenario.define(SCHEDULER, 'released_job', 'A held job released, then running') do |s|
        id = submit(s, submit_as_hold: true)
        s.fact('id', id)
        wait_for_state(s, id, 'PENDING')
        s.record(:release) { s.adapter.release(id) }
        wait_for_state(s, id, 'RUNNING')
        s.fact('state', 'RUNNING')
        s.record(:info) { s.adapter.info(id) }
      end

      Scenario.define(SCHEDULER, 'completed_job', 'A job whose script exited 0') do |s|
        finished_job(s, 'COMPLETED', content: 'exit 0')
      end

      Scenario.define(SCHEDULER, 'failed_job', 'A job whose script exited 3') do |s|
        finished_job(s, 'FAILED', content: 'exit 3')
      end

      Scenario.define(SCHEDULER, 'timeout_job', 'A job killed at its one minute time limit') do |s|
        finished_job(s, 'TIMEOUT', wall_time: 60)
      end

      Scenario.define(SCHEDULER, 'canceled_job', 'Deleting a running job, then asking about it') do |s|
        id = submit(s)
        s.fact('id', id)
        wait_for_state(s, id, 'RUNNING')
        s.record(:delete) { s.adapter.delete(id) }
        accounting = s.wait_until("job #{id} is canceled", interval: s.backend.poll_interval) do
          found = s.backend.accounting(id)
          found if found && found.first == 'CANCELLED'
        end
        s.fact('state', accounting.first)
        observe(s, id)
        s.record(:info_historic) { s.adapter.info_historic(opts: { job_ids: [id] }) }
      end

      Scenario.define(SCHEDULER, 'not_found', "Asking about, holding and deleting a job Slurm doesn't know") do |s|
        id = Backends::Slurm::UNKNOWN_JOB_ID
        raise "job #{id} exists; refusing to record someone else's job" unless s.backend.job(id).nil?

        s.fact('id', id)
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
        s.record(:hold) { s.adapter.hold(id) }
        s.record(:delete) { s.adapter.delete(id) }
      end

      Scenario.define(SCHEDULER, 'invalid_submit', 'Submitting to a partition that does not exist') do |s|
        options = { queue_name: 'ood-rec-no-such-partition' }
        s.fact('script', options)
        s.fact('partition', s.backend.partition)
        error = s.record(:submit) do
          s.adapter.submit(s.script(**options))
          nil
        rescue OodCore::JobAdapterError => e
          e
        end
        raise 'expected the submit to fail' if error.nil?

        s.fact('error', error.class.name)
      end
    end
  end
end
