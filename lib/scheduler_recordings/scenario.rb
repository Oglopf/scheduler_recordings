# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'recorder'

module SchedulerRecordings
  # A named thing to do against a real scheduler and record.
  #
  #   SchedulerRecordings::Scenario.define('kubernetes', 'running_pod', 'A pod running and ready') do |s|
  #     id = s.record(:submit) { s.adapter.submit(s.script(command: 'sleep 3600')) }
  #     s.wait_until('pod is running') { s.backend.pod(id).dig('status', 'phase') == 'Running' }
  #     s.record(:info) { s.adapter.info(id) }
  #     s.fact('id', id)
  #   end
  #
  # Only calls inside s.record blocks end up in the recording.
  class Scenario
    attr_reader :scheduler, :name, :description, :block

    def self.registry
      @registry ||= Hash.new { |hash, key| hash[key] = {} }
    end

    def self.define(scheduler, name, description, &block)
      registry[scheduler.to_s][name.to_s] = new(scheduler.to_s, name.to_s, description, block)
    end

    def self.all(scheduler)
      registry[scheduler.to_s].values
    end

    def initialize(scheduler, name, description, block)
      @scheduler = scheduler
      @name = name
      @description = description
      @block = block
    end
  end

  # What a scenario block gets: the adapter under test, the backend for
  # unrecorded checks, and ways to record and note facts.
  class Session
    class Timeout < StandardError; end

    attr_reader :backend, :recorder, :facts

    def initialize(backend, recorder)
      @backend = backend
      @recorder = recorder
      @facts = {}
    end

    def adapter
      backend.adapter
    end

    def script(**options)
      backend.script(**options)
    end

    def record(step, &block)
      recorder.record(step, &block)
    end

    # Polls (unrecorded) until the block returns something truthy, and returns it.
    def wait_until(what, timeout: backend.timeout, interval: 1)
      deadline = Time.now + timeout
      loop do
        result = yield
        return result if result
        raise Timeout, "gave up after #{timeout}s waiting until #{what}" if Time.now > deadline

        sleep(interval)
      end
    end

    # Something the scenario checked directly against the scheduler. Saved in
    # the recording's header so tests can assert against it.
    # Saved as JSON right away, so later changes to the value don't leak in.
    def fact(key, value)
      @facts[key.to_s] = JSON.parse(JSON.generate(value))
    end
  end

  # Runs scenarios against a backend and writes one recording per scenario.
  class Runner
    attr_reader :backend, :out, :log

    def initialize(backend, out:, log: $stderr)
      @backend = backend
      @out = out
      @log = log
    end

    def run(scenarios)
      written = []
      failed = []
      scenarios.each do |scenario|
        log.puts("recording #{scenario.scheduler}/#{scenario.name}")
        written << run_one(scenario)
      rescue StandardError => e
        failed << scenario.name
        log.puts("  FAILED: #{e.class}: #{e.message.lines.first.to_s.strip}")
      end
      [written, failed]
    end

    def run_one(scenario)
      backend.prepare
      srand(SchedulerRecordings::SEED)
      recorder = Recorder.new(redact: backend.redactions)
      session = Session.new(backend, recorder)
      begin
        scenario.block.call(session)
      ensure
        backend.clean_up
      end
      recording = recorder.to_recording(header(scenario, session))
      path = File.join(out, scenario.scheduler, backend.version_dir, "#{scenario.name}.jsonl")
      FileUtils.mkdir_p(File.dirname(path))
      recording.write(path)
      log.puts("  #{recorder.calls.length} calls -> #{path}")
      path
    end

    private

    def header(scenario, session)
      {
        'scheduler' => scenario.scheduler,
        'scenario' => scenario.name,
        'description' => scenario.description,
        'scheduler_version' => backend.version_dir,
        'versions' => backend.versions,
        'recorded_with' => backend.recorded_with,
        'identity' => backend.identity,
        'seed' => SchedulerRecordings::SEED,
        'facts' => session.facts
      }
    end
  end
end
