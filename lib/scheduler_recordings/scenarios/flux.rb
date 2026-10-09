# frozen_string_literal: true

# Flux scenarios. Each finished-job scenario waits for Flux's own result
# (COMPLETED, FAILED, TIMEOUT, CANCELED) and saves it as a fact, so replay
# tests can check the adapter against what Flux said.
module SchedulerRecordings
  module Scenarios
    module Flux
      SCHEDULER = 'flux'

      # Saves the script options as a fact, so a replay can rebuild the
      # exact script and check what submit sends.
      def self.submit(s, step: :submit, **options)
        script = s.script(**options)
        s.fact(step == :submit ? 'script' : "script_#{step}", options)
        s.record(step) { s.adapter.submit(script) }
      end

      # Records the adapter's view of one job: info, status and the job list.
      def self.observe(s, id)
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
        s.record(:info_all) { s.adapter.info_all }
      end

      # Submits, waits (unrecorded) for Flux's own result, then observes.
      def self.finished_job(s, expected_result, **options)
        id = submit(s, **options)
        s.fact('id', id)
        s.wait_until("the job finishes #{expected_result}") { s.backend.state(id) == 'INACTIVE' }
        s.fact('state', 'INACTIVE')
        s.fact('result', s.backend.result(id))
        s.fact('returncode', s.backend.job(id)['returncode'])
        observe(s, id)
        raise "expected #{expected_result}, Flux said #{s.backend.result(id)}" unless s.backend.result(id) == expected_result
      end

      Scenario.define(SCHEDULER, 'running_job', 'A job that is running') do |s|
        id = submit(s)
        s.fact('id', id)
        s.wait_until('the job is running') { s.backend.state(id) == 'RUN' }
        s.fact('state', 'RUN')
        observe(s, id)
      end

      Scenario.define(SCHEDULER, 'held_job', 'A job submitted on hold (urgency 0)') do |s|
        id = submit(s, submit_as_hold: true)
        s.fact('id', id)
        s.wait_until('the job reaches the scheduler') { s.backend.state(id) == 'SCHED' }
        s.fact('state', 'SCHED')
        s.fact('urgency', s.backend.job(id)['urgency'])
        observe(s, id)
      end

      Scenario.define(SCHEDULER, 'dependent_job', 'A job waiting on a dependency (afterok on a held job)') do |s|
        held = submit(s, step: :submit_held, submit_as_hold: true)
        s.fact('held_id', held)
        id = s.record(:submit) { s.adapter.submit(s.script, afterok: held) }
        s.fact('script', {})
        s.fact('afterok', held)
        s.fact('id', id)
        s.wait_until('the job is waiting on its dependency') { s.backend.state(id) == 'DEPEND' }
        s.fact('state', 'DEPEND')
        s.fact('dependencies', s.backend.job(id)['dependencies'])
        observe(s, id)
      end

      Scenario.define(SCHEDULER, 'released_job', 'A held job released, then running') do |s|
        id = submit(s, submit_as_hold: true)
        s.fact('id', id)
        s.wait_until('the job reaches the scheduler') { s.backend.state(id) == 'SCHED' }
        s.record(:release) { s.adapter.release(id) }
        s.wait_until('the released job runs') { s.backend.state(id) == 'RUN' }
        s.fact('state', 'RUN')
        s.record(:info) { s.adapter.info(id) }
      end

      Scenario.define(SCHEDULER, 'completed_job', 'A job whose script exited 0') do |s|
        finished_job(s, 'COMPLETED', content: 'exit 0')
      end

      Scenario.define(SCHEDULER, 'failed_job', 'A job whose script exited 3') do |s|
        finished_job(s, 'FAILED', content: 'exit 3')
      end

      Scenario.define(SCHEDULER, 'timeout_job', 'A job killed at its 2 second time limit') do |s|
        finished_job(s, 'TIMEOUT', content: 'sleep 600', wall_time: 2)
      end

      Scenario.define(SCHEDULER, 'canceled_job', 'Deleting a running job, then asking about it') do |s|
        id = submit(s)
        s.fact('id', id)
        s.wait_until('the job is running') { s.backend.state(id) == 'RUN' }
        s.record(:delete) { s.adapter.delete(id) }
        s.wait_until('the job is inactive') { s.backend.state(id) == 'INACTIVE' }
        s.fact('result', s.backend.result(id))
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
      end

      Scenario.define(SCHEDULER, 'several_jobs', 'One running job and one held job, listed together') do |s|
        running = submit(s)
        held = submit(s, step: :submit_held, submit_as_hold: true)
        s.wait_until('both jobs settle') do
          s.backend.state(running) == 'RUN' && s.backend.state(held) == 'SCHED'
        end
        s.fact('ids', { 'running' => running, 'held' => held })
        s.record(:info_all) { s.adapter.info_all }
        s.record(:info_where_owner) { s.adapter.info_where_owner(s.backend.identity['user']) }
      end

      Scenario.define(SCHEDULER, 'not_found', "Asking about, holding and deleting a job Flux doesn't know") do |s|
        id = '999999'
        s.fact('id', id)
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
        s.record(:hold) { s.adapter.hold(id) }
        s.record(:delete) { s.adapter.delete(id) }
      end

      Scenario.define(SCHEDULER, 'no_jobs', 'Listing jobs when the user has none active') do |s|
        s.record(:info_all) { s.adapter.info_all }
      end

      Scenario.define(SCHEDULER, 'invalid_submit', 'Submitting to a queue that does not exist') do |s|
        options = { queue_name: 'no-such-queue' }
        s.fact('script', options)
        error = s.record(:submit) do
          s.adapter.submit(s.script(**options))
          nil
        rescue OodCore::JobAdapterError => e
          e
        end
        raise 'expected the submit to fail' if error.nil?

        s.fact('error', error.class.name)
        s.fact('message', error.message.strip)
      end
    end
  end
end
