# frozen_string_literal: true

require 'etc'
require 'json'
require 'open3'

module SchedulerRecordings
  module Backends
    # Records Open OnDemand's flux adapter against a running Flux instance:
    # a site's system instance, or a test instance in a container
    # (fluxrm/flux-sched, `flux start --test-size=1`).
    #
    # Run the recorder from a shell that can reach the instance, i.e. inside
    # `flux start` or with FLUX_URI set. Between scenarios it cancels every
    # active job of the user running it, so use a test user or instance.
    #
    # Unlike Kubernetes, the identity can't be pinned to a fixed user: Flux
    # reports the real submitting user, so recordings are made as whoever
    # runs the recorder, and the header says who that was.
    class Flux
      # The fields of an Etc::Passwd the flux adapter reads.
      Account = Struct.new(:name, :uid, :gid, :dir, :shell)

      attr_reader :flux, :timeout

      # The account a replaying test should hand the adapter in place of an
      # Etc lookup, so the environment it builds matches the recording:
      #
      #   Etc.stub(:getpwuid, SchedulerRecordings::Backends::Flux.account(recording.header['identity'])) { ... }
      def self.account(identity)
        Account.new(identity['user'], identity['uid'], identity['gid'], identity['home'], identity['shell'])
      end

      def initialize(flux: nil, timeout: 120)
        @flux = flux || which('flux')
        @timeout = timeout
        require 'ood_core'
        require 'ood_core/job/adapters/flux'
      end

      def identity
        @identity ||= begin
          user = Etc.getpwuid(Process.uid)
          { 'user' => user.name, 'uid' => user.uid, 'gid' => user.gid, 'home' => user.dir, 'shell' => user.shell }
        end
      end

      # The adapter under test. It's given the flux binary as an override so
      # every command starts with the {{flux}} placeholder.
      def adapter
        @adapter ||= OodCore::Job::Factory.build(adapter: 'flux', bin_overrides: { 'flux' => flux })
      end

      # A job script that runs in /tmp, so job output doesn't land in the
      # recorder's checkout.
      def script(content: 'sleep 600', **options)
        OodCore::Job::Script.new(content: content, workdir: '/tmp', **options)
      end

      def redactions
        { flux => 'flux' }
      end

      def prepare
        @adapter = nil
        clean_up
      end

      # Cancels the user's active jobs and waits until none are left.
      def clean_up
        flux_run('cancel', '--all')
        deadline = Time.now + timeout
        until active_jobs.empty?
          raise "jobs still active after #{timeout}s: #{active_jobs.join(' ')}" if Time.now > deadline

          sleep(1)
        end
      end

      # The job as Flux reports it, read without the adapter (and without
      # being recorded). nil when Flux doesn't know it.
      def job(id)
        out, _err, status = flux_run('jobs', '--json', id.to_s)
        status.success? ? JSON.parse(out) : nil
      end

      def state(id)
        job(id).to_h['state']
      end

      def result(id)
        job(id).to_h['result']
      end

      # Directory name for this instance's recordings: flux-core's version
      # without the git suffix ("0.89.0-124-g11c9d4c0f" -> "v0.89.0").
      def version_dir
        "v#{core_version[/\d+\.\d+\.\d+/] || core_version}"
      end

      def versions
        version_lines.slice('commands', 'libflux-core', 'libflux-security', 'broker')
      end

      def recorded_with
        { 'ood_core' => OodCore::VERSION, 'scheduler_recordings' => SchedulerRecordings::VERSION,
          'ood_core_commit' => ood_core_commit }.compact
      end

      private

      def active_jobs
        out, _err, status = flux_run('jobs', '--no-header', '--format={id}')
        status.success? ? out.split : []
      end

      def core_version
        version_lines.fetch('libflux-core') { version_lines.fetch('commands', '') }
      end

      # `flux version` prints "name: value" lines.
      def version_lines
        @version_lines ||= begin
          out, err, status = flux_run('version')
          raise "flux can't reach an instance: #{err}" unless status.success?

          out.lines.each_with_object({}) do |line, found|
            name, value = line.split(':', 2)
            found[name.strip] = value.to_s.strip if value
          end
        end
      end

      def ood_core_commit
        root = Gem.loaded_specs['ood_core']&.full_gem_path || File.expand_path('../..', $LOADED_FEATURES.grep(%r{/ood_core\.rb\z}).first.to_s)
        out, _err, status = Open3.capture3('git', '-C', root, 'rev-parse', '--short', 'HEAD')
        status.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end

      def flux_run(*args)
        Open3.capture3(flux, *args)
      end

      def which(command)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, command)
          return path if File.executable?(path) && !File.directory?(path)
        end
        raise "#{command} not found on PATH; pass --flux"
      end
    end
  end
end
