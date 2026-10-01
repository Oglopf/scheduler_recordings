# frozen_string_literal: true

require 'shellwords'

module SchedulerRecordings
  # Turns the arguments of an Open3.capture3 call into [env, command] the
  # same way for recording and replay. A call made with one string keeps it
  # as a string; a call made with separate arguments keeps them as an array,
  # exactly as passed.
  #
  #   capture3('kubectl get pods')                   => [{}, "kubectl get pods"]
  #   capture3({ 'X' => '1' }, 'qstat', '-f', '-t')  => [{ 'X' => '1' }, ["qstat", "-f", "-t"]]
  module CommandLine
    module_function

    def split(args)
      args = args.dup
      env = args.first.is_a?(Hash) ? args.shift : {}
      argv = args.map { |arg| arg.is_a?(Array) ? arg.first : arg }.map(&:to_s)
      command = argv.length == 1 ? argv.first : argv
      [env.transform_keys(&:to_s).transform_values { |v| v&.to_s }, command]
    end

    # For messages: how the command would look typed at a shell.
    def display(command)
      command.is_a?(Array) ? Shellwords.join(command) : command.to_s
    end

    # Applies a string substitution to a command in either form.
    def map(command, &block)
      command.is_a?(Array) ? command.map(&block) : block.call(command)
    end
  end

  # Stands in for Process::Status in replayed calls.
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end

    def exited?
      true
    end

    def signaled?
      false
    end

    def to_i
      exitstatus << 8
    end

    def pid
      0
    end
  end
end
