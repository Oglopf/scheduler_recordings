# frozen_string_literal: true

# Kubernetes scenarios. Names follow the hand-captured fixtures in ood_core's
# spec/fixtures/output/k8s, so each recording can replace or check one.
module SchedulerRecordings
  module Scenarios
    module Kubernetes
      SCHEDULER = 'kubernetes'

      # Submits a pod, waits (unrecorded) until the block says it's in the
      # state the scenario is about, then records the adapter's view of it.
      def self.submit_and_observe(s, script, what)
        s.fact('native', script.native)
        id = s.record(:submit) { s.adapter.submit(script) }
        s.fact('id', id)
        s.wait_until(what) { yield id }
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
        s.record(:info_all) { s.adapter.info_all }
        id
      end

      def self.phase(s, id)
        s.backend.pod(id).to_h.dig('status', 'phase')
      end

      def self.waiting_reason(s, id)
        s.backend.container_state(id).dig('waiting', 'reason')
      end

      Scenario.define(SCHEDULER, 'running_pod', 'A pod whose container is running and ready') do |s|
        submit_and_observe(s, s.script, 'the pod is running and ready') do |id|
          s.backend.condition(id, 'Ready').to_h['status'] == 'True'
        end
        s.fact('phase', 'Running')
        s.fact('ready', true)
      end

      Scenario.define(SCHEDULER, 'running_pod_not_ready', 'A running pod whose startup probe never passes (nothing listens on the port)') do |s|
        script = s.script(container: { port: 8080 })
        submit_and_observe(s, script, 'the container is running') do |id|
          s.backend.container_state(id).key?('running')
        end
        s.fact('phase', 'Running')
        s.fact('ready', false)
      end

      Scenario.define(SCHEDULER, 'queued_pod', 'A pod still pending because its init container is running') do |s|
        init = [{ name: 'init', image: s.backend.image, command: 'sleep 3600' }]
        script = s.script(init_containers: init)
        submit_and_observe(s, script, 'the init container is running') do |id|
          init_state = s.backend.pod(id).to_h.dig('status', 'initContainerStatuses').to_a.first.to_h['state'].to_h
          init_state.key?('running')
        end
        s.fact('phase', 'Pending')
        s.fact('reason', 'PodInitializing')
      end

      Scenario.define(SCHEDULER, 'unschedulable_pod', 'A pod no node can fit (it requests 64 CPUs)') do |s|
        script = s.script(container: { cpu: '64' })
        submit_and_observe(s, script, 'the scheduler marks it unschedulable') do |id|
          s.backend.condition(id, 'PodScheduled').to_h['reason'] == 'Unschedulable'
        end
        s.fact('phase', 'Pending')
        s.fact('reason', 'Unschedulable')
      end

      Scenario.define(SCHEDULER, 'completed_pod', 'A pod whose container exited 0') do |s|
        script = s.script(container: { command: 'sh -c "exit 0"' })
        submit_and_observe(s, script, 'the pod succeeded') { |id| phase(s, id) == 'Succeeded' }
        s.fact('phase', 'Succeeded')
        s.fact('exit_code', 0)
      end

      Scenario.define(SCHEDULER, 'error_pod', 'A pod whose container exited 3 and is not restarted') do |s|
        script = s.script(container: { command: 'sh -c "exit 3"' })
        submit_and_observe(s, script, 'the pod failed') { |id| phase(s, id) == 'Failed' }
        s.fact('phase', 'Failed')
        s.fact('exit_code', 3)
      end

      Scenario.define(SCHEDULER, 'crash_loop_pod', 'A pod whose container keeps exiting 1 under restartPolicy Always') do |s|
        script = s.script(container: { command: 'sh -c "exit 1"', restart_policy: 'Always' })
        submit_and_observe(s, script, 'the container is in CrashLoopBackOff') do |id|
          waiting_reason(s, id) == 'CrashLoopBackOff'
        end
        s.fact('phase', 'Running')
        s.fact('reason', 'CrashLoopBackOff')
      end

      Scenario.define(SCHEDULER, 'image_error_pod', "A pod whose image can't be pulled") do |s|
        script = s.script(container: { image: 'registry.invalid/ood/does-not-exist:1' })
        submit_and_observe(s, script, 'the image pull fails') do |id|
          %w[ErrImagePull ImagePullBackOff].include?(waiting_reason(s, id))
        end
        s.fact('phase', 'Pending')
        s.fact('reason', 'ErrImagePull or ImagePullBackOff')
      end

      Scenario.define(SCHEDULER, 'several_pods', 'One running pod and one completed pod, listed together') do |s|
        running = s.record(:submit) { s.adapter.submit(s.script) }
        done = s.record(:submit) { s.adapter.submit(s.script(container: { command: 'sh -c "exit 0"' })) }
        s.wait_until('both pods settle') do
          s.backend.condition(running, 'Ready').to_h['status'] == 'True' && phase(s, done) == 'Succeeded'
        end
        s.record(:info_all) { s.adapter.info_all }
        s.record(:info_where_owner) { s.adapter.info_where_owner(s.backend.identity['user']) }
        s.fact('ids', { 'running' => running, 'completed' => done })
      end

      Scenario.define(SCHEDULER, 'delete_pod', 'Deleting a running pod, then asking about it') do |s|
        id = s.record(:submit) { s.adapter.submit(s.script) }
        s.fact('id', id)
        s.wait_until('the pod is running') { phase(s, id) == 'Running' }
        s.record(:delete) { s.adapter.delete(id) }
        s.wait_until('the pod is gone') { s.backend.pod(id).nil? }
        s.record(:info_after_delete) { s.adapter.info(id) }
      end

      Scenario.define(SCHEDULER, 'not_found', "Asking about and deleting a pod that doesn't exist") do |s|
        id = 'rec-doesnotexist'
        s.fact('id', id)
        s.record(:info) { s.adapter.info(id) }
        s.record(:status) { s.adapter.status(id) }
        s.record(:delete) { s.adapter.delete(id) }
      end

      Scenario.define(SCHEDULER, 'empty_namespace', 'Listing jobs when the user has none') do |s|
        s.record(:info_all) { s.adapter.info_all }
      end

      Scenario.define(SCHEDULER, 'invalid_submit', 'Submitting a pod with an invalid memory quantity') do |s|
        script = s.script(container: { memory: 'lots' })
        s.fact('native', script.native)
        error = s.record(:submit) do
          s.adapter.submit(script)
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
