# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'scheduler_recordings'
require 'scheduler_recordings/minitest'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

module TestHelper
  # A small in-memory recording for unit tests.
  def recording(calls, vars: [], scenario: 'example')
    header = { 'format' => SchedulerRecordings::Recording::FORMAT, 'scheduler' => 'fake',
               'scenario' => scenario, 'scheduler_version' => 'v1.0.0', 'vars' => vars }
    built = calls.map do |call|
      defaults = { step: 'main', at: '2026-10-01T23:00:00.000Z', env: {}, stdin: '', stdout: '', stderr: '', exit: 0 }
      SchedulerRecordings::Recording::Call.new(**defaults.merge(call))
    end
    SchedulerRecordings::Recording.new(header, built)
  end
end
