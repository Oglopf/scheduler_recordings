# frozen_string_literal: true

require 'open3'
require 'time'
require_relative 'command_line'
require_relative 'recording'

module SchedulerRecordings
  # Captures every Open3.capture3 call made inside #record blocks, letting the
  # real command run. Calls made outside a #record block (polling while
  # waiting for a pod to start, say) run normally and aren't kept.
  class Recorder
    attr_reader :calls

    # redact maps text that depends on this machine to a placeholder name:
    # { '/home/me/.kube/config' => 'kubeconfig' } turns every occurrence into
    # {{kubeconfig}} in the saved commands and output.
    def initialize(redact: {})
      @redact = redact.reject { |text, _name| text.to_s.empty? }
                      .sort_by { |text, _name| -text.to_s.length }
      @calls = []
      @step = nil
      install_hook
    end

    def record(step)
      previous = Thread.current[:scheduler_recordings_recorder]
      Thread.current[:scheduler_recordings_recorder] = self
      @step = step.to_s
      yield
    ensure
      Thread.current[:scheduler_recordings_recorder] = previous
      @step = nil
    end

    def add(args, options, stdout, stderr, status)
      env, command = CommandLine.split(args)
      @calls << Recording::Call.new(
        step: @step,
        at: Time.now.utc.iso8601(3),
        env: env.transform_values { |value| redact(value) },
        command: CommandLine.map(command) { |part| redact(part) },
        stdin: redact(options[:stdin_data].to_s),
        stdout: redact(stdout),
        stderr: redact(stderr),
        exit: status.exitstatus
      )
    end

    def vars
      @redact.map { |_text, name| name.to_s }.uniq.sort
    end

    def to_recording(header)
      Recording.new({ 'format' => Recording::FORMAT }.merge(header).merge('vars' => vars), calls)
    end

    private

    def redact(text)
      return text if text.nil?

      @redact.reduce(text.to_s) { |redacted, (real, name)| redacted.gsub(real.to_s, "{{#{name}}}") }
    end

    # Wraps Open3.capture3 once per process. The wrapper does nothing unless
    # a Recorder is active on the current thread. It replaces the singleton
    # method rather than prepending a module, because Minitest's and Mocha's
    # stubbing alias and restore singleton methods, and a prepended module
    # turns that restore into infinite recursion.
    def install_hook
      return if Open3.singleton_class.method_defined?(:__scheduler_recordings_original_capture3)

      Open3.singleton_class.send(:alias_method, :__scheduler_recordings_original_capture3, :capture3)
      Open3.define_singleton_method(:capture3) do |*args, **options|
        result = __scheduler_recordings_original_capture3(*args, **options)
        recorder = Thread.current[:scheduler_recordings_recorder]
        recorder&.add(args, options, *result)
        result
      end
    end
  end
end
