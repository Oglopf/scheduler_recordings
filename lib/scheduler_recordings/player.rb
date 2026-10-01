# frozen_string_literal: true

require_relative 'command_line'
require_relative 'recording'

module SchedulerRecordings
  # Raised when replayed code runs a command the recording doesn't have, or
  # runs a recorded command more times than it was recorded.
  class UnrecordedCall < StandardError; end

  # Answers Open3.capture3 calls from a recording.
  #
  # Each distinct command keeps its own queue of recorded answers, so code may
  # run commands in a different order than when it was recorded, but every
  # call has to match a recorded command exactly (after {{vars}} are filled
  # in) and can't be answered more times than it was recorded.
  class Player
    attr_reader :recording, :vars

    def initialize(recording, vars: {}, step: nil)
      @recording = recording
      @vars = vars.transform_keys(&:to_s)
      missing = recording.vars - @vars.keys
      unless missing.empty?
        raise ArgumentError, "#{recording.name} needs values for #{missing.join(', ')} " \
                             "(pass #{missing.map { |v| "#{v}: ..." }.join(', ')})"
      end

      @queues = Hash.new { |hash, key| hash[key] = [] }
      recording.calls_for(step).each { |call| @queues[fill_command(call.command)] << call }
      @played = []
      @requests = []
    end

    # Same signature as Open3.capture3.
    def capture3(*args, **options)
      _env, command = CommandLine.split(args)
      @requests << [command, options[:stdin_data].to_s]
      call = @queues.fetch(command, []).shift
      raise UnrecordedCall, unrecorded_message(command) if call.nil?

      @played << call
      [fill(call.stdout), fill(call.stderr), Status.new(call.exit)]
    end

    # Recorded calls that replay never asked for. Assert this is empty to
    # prove a test drove everything the scenario recorded.
    def unplayed
      @queues.values.flatten
    end

    # Recorded calls that were answered, in the order they were asked for.
    def played
      @played.dup
    end

    # What the code under test actually sent, as [command, stdin] pairs.
    # Compare with played calls' stdin to catch changes in what's submitted
    # (a pod template, a qsub script).
    def requests
      @requests.dup
    end

    private

    def fill_command(command)
      CommandLine.map(command) { |part| fill(part) }
    end

    def fill(text)
      return text if text.nil? || vars.empty?

      vars.reduce(text) { |filled, (name, value)| filled.gsub("{{#{name}}}", value.to_s) }
    end

    def unrecorded_message(command)
      recorded = @queues.keys
      used_up = @played.map { |call| fill_command(call.command) }.include?(command)
      reason = if used_up
                 'it was recorded, but every recorded answer has already been used'
               else
                 'it is not in the recording'
               end
      shown = CommandLine.display(command)
      closest = recorded.min_by { |known| distance(CommandLine.display(known), shown) }
      message = +"#{recording.name}: can't answer `#{shown}`: #{reason}."
      message << "\nClosest recorded command:\n  #{CommandLine.display(closest)}" if closest && !used_up
      message
    end

    # Rough similarity for the error message: length of the shared prefix,
    # negated so min_by picks the longest.
    def distance(left, right)
      shared = 0
      shared += 1 while shared < left.length && shared < right.length && left[shared] == right[shared]
      -shared
    end
  end
end
