# frozen_string_literal: true

require 'json'
require 'time'

module SchedulerRecordings
  # One recorded scenario: a header describing where and how it was recorded,
  # then every command the adapter ran, in order.
  #
  # On disk it is JSONL. The first line is the header; each later line is one
  # call:
  #
  #   {"step":"info","at":"2026-10-01T23:30:01.123Z","env":{},
  #    "command":"/usr/bin/kubectl --kubeconfig={{kubeconfig}} ...",
  #    "stdin":"","stdout":"{...}","stderr":"","exit":0}
  #
  # Values that depend on the machine that recorded it (a kubeconfig path,
  # say) are written as {{name}} placeholders, listed in the header's "vars".
  # Whoever replays the recording supplies their own values for them.
  class Recording
    FORMAT = 1

    Call = Struct.new(:step, :at, :env, :command, :stdin, :stdout, :stderr, :exit, keyword_init: true) do
      def to_h
        { 'step' => step, 'at' => at, 'env' => env, 'command' => command,
          'stdin' => stdin, 'stdout' => stdout, 'stderr' => stderr, 'exit' => self.exit }
      end
    end

    attr_reader :header, :calls, :path

    def self.load(path)
      lines = File.readlines(path, chomp: true, encoding: 'UTF-8').reject(&:empty?)
      raise ArgumentError, "#{path} is empty" if lines.empty?

      header = JSON.parse(lines.first)
      unless header['format'] == FORMAT
        raise ArgumentError, "#{path} is format #{header['format'].inspect}, this gem reads format #{FORMAT}"
      end

      calls = lines.drop(1).map do |line|
        data = JSON.parse(line)
        Call.new(**data.transform_keys(&:to_sym))
      end
      new(header, calls, path: path)
    end

    def initialize(header, calls = [], path: nil)
      @header = header
      @calls = calls
      @path = path
    end

    def scheduler
      header['scheduler']
    end

    def scenario
      header['scenario']
    end

    # The scheduler version the recording came from, as the scheduler reports it.
    def scheduler_version
      header['scheduler_version']
    end

    # Names of the {{placeholders}} a replay has to supply.
    def vars
      header.fetch('vars', [])
    end

    # Facts the scenario checked directly against the scheduler while
    # recording, independent of any adapter code. For example
    # {"phase" => "Running", "ready" => true}.
    def facts
      header.fetch('facts', {})
    end

    # What srand was set to while recording (see SchedulerRecordings::SEED).
    def seed
      header['seed']
    end

    def steps
      calls.map(&:step).uniq
    end

    def calls_for(step)
      return calls if step.nil?

      selected = calls.select { |call| call.step == step.to_s }
      raise ArgumentError, "#{name} has no step #{step.inspect}; steps are #{steps.inspect}" if selected.empty?

      selected
    end

    # When the first call of a step ran. Freeze the clock here in tests whose
    # answers depend on the current time (a running job's wall time).
    def time_of(step)
      Time.iso8601(calls_for(step).first.at)
    end

    def name
      [scheduler, scheduler_version, scenario].compact.join('/')
    end

    def write(path)
      File.open(path, 'w', encoding: 'UTF-8') do |file|
        file.puts(JSON.generate(header))
        calls.each { |call| file.puts(JSON.generate(call.to_h)) }
      end
      @path = path
    end
  end
end
