# frozen_string_literal: true

require 'etc'
require 'open3'

module SchedulerRecordings
  module Backends
    # Records Open OnDemand's slurm adapter against a Slurm cluster, which may
    # be a production cluster other people are using. Run it from a login
    # node as yourself.
    #
    # How it stays out of everyone else's way:
    #
    # - Every job it submits is named JOB_NAME, charged to the account you
    #   pass, in the partition you pass (use a debug partition), with one
    #   task, a five minute time limit, no output file, and /tmp as its
    #   working directory. A job left behind by a crash ends on its own.
    # - It only cancels jobs that are yours *and* named JOB_NAME, by job ID.
    #   It never runs scancel -u, and it refuses to run as root, whose
    #   scancel could reach other people's jobs.
    # - It polls Slurm every POLL_INTERVAL seconds, not every second.
    # - Scenarios never record info_all: ood_core's squeue call for it has no
    #   user filter, so it would capture every user's jobs.
    # - Your user name, group, home directory and account are written as
    #   {{placeholders}}. Node names, partition names, numeric IDs and
    #   Slurm's version are not; review recordings before committing them.
    class Slurm
      # Name of every job the recorder submits. Cleanup only touches jobs
      # with this name.
      JOB_NAME = 'ood-rec'

      # Longest a recorder job may run, in seconds. Jobs that only need to
      # be seen running are canceled long before this.
      WALL_TIME = 300

      POLL_INTERVAL = 5

      # Higher than Slurm's largest possible job ID (MaxJobId is at most
      # 67,108,863), so it can't be anyone's real job.
      UNKNOWN_JOB_ID = '999999999'

      ACTIVE_STATES = 'PENDING,RUNNING,SUSPENDED,COMPLETING,CONFIGURING,REQUEUED,RESIZING'

      attr_reader :account, :partition, :timeout, :poll_interval

      def initialize(account:, partition:, timeout: 600, poll_interval: POLL_INTERVAL)
        raise ArgumentError, 'refusing to record as root: its scancel can reach other users\' jobs' if Process.uid.zero?
        raise ArgumentError, 'pass --account: the account to charge test jobs to' if account.to_s.empty?
        raise ArgumentError, 'pass --partition: a debug or test partition' if partition.to_s.empty?

        @account = account.to_s
        @partition = partition.to_s
        @timeout = timeout
        @poll_interval = poll_interval
        require 'ood_core'
        require 'ood_core/job/adapters/slurm'
      end

      # What the replay tests act as: the placeholders the recorder writes
      # in place of the real user.
      def identity
        { 'user' => '{{user}}', 'group' => '{{group}}', 'home' => '{{home}}' }
      end

      def user
        @user ||= Etc.getpwuid(Process.uid)
      end

      def adapter
        @adapter ||= OodCore::Job::Factory.build(adapter: 'slurm')
      end

      # Options every recorder job gets. Replay tests rebuild scripts from
      # these plus the scenario's own options.
      def self.script_defaults(account:, partition:)
        { job_name: JOB_NAME, accounting_id: account, queue_name: partition, wall_time: WALL_TIME,
          workdir: '/tmp', output_path: '/dev/null', shell_path: '/bin/bash', content: 'sleep 240' }
      end

      def script(**options)
        defaults = self.class.script_defaults(account: account, partition: partition)
        OodCore::Job::Script.new(**defaults.merge(options))
      end

      # Machine- and person-specific text, recorded as {{placeholders}}.
      # Values under three characters are left alone, since replacing them
      # would mangle unrelated text. When two are the same text (a group
      # named after its project account, or after the user), the later name
      # wins: user over account over group.
      def redactions
        found = {}
        found[Etc.getgrgid(user.gid).name] = 'group'
        found[account] = 'account'
        found[user.name] = 'user'
        found[user.dir] = 'home'
        found.reject { |text, _name| text.to_s.length < 3 }
      end

      def prepare
        @adapter = nil
        clean_up
      end

      # Cancels this recorder's leftover jobs, by ID, and waits for them to
      # leave the active states.
      def clean_up
        ids = own_jobs(states: ACTIVE_STATES).select { |_id, name| name == JOB_NAME }.keys
        run('scancel', *ids) unless ids.empty?
        deadline = Time.now + timeout
        loop do
          active = own_jobs(states: ACTIVE_STATES).select { |_id, name| name == JOB_NAME }.keys
          break if active.empty?
          raise "recorder jobs still active after #{timeout}s: #{active.join(' ')}" if Time.now > deadline

          sleep(poll_interval)
        end
      end

      # Your jobs in squeue that the recorder didn't submit. Scenarios that
      # list jobs by owner refuse to run while there are any, so your real
      # work doesn't end up in a recording.
      def other_jobs
        own_jobs(states: 'all').reject { |_id, name| name == JOB_NAME }.keys
      end

      # [state, reason] from squeue, or nil once Slurm has forgotten the job.
      # Not recorded.
      def job(id)
        out, _err, status = run('squeue', '-h', '-j', id.to_s, '-o', '%T|%r')
        return nil unless status.success?

        state, reason = out.lines.first.to_s.strip.split('|', 2)
        state.to_s.empty? ? nil : [state, reason]
      end

      def state(id)
        job(id)&.first
      end

      def reason(id)
        job(id)&.last
      end

      # [state, exit_code] from the accounting database, once it has the
      # job. "CANCELLED by 1234" is trimmed to "CANCELLED". Not recorded.
      def accounting(id)
        out, _err, status = run('sacct', '-n', '-X', '-P', '-j', id.to_s, '-o', 'State,ExitCode')
        return nil unless status.success?

        state, exit_code = out.lines.first.to_s.strip.split('|', 2)
        state.to_s.empty? ? nil : [state.split.first, exit_code]
      end

      # Directory name for this cluster's recordings: "slurm 24.05.4" -> "v24.05.4".
      def version_dir
        "v#{slurm_version[/\d+\.\d+\.\d+/] || slurm_version}"
      end

      def versions
        { 'slurm' => slurm_version }
      end

      def recorded_with
        { 'ood_core' => OodCore::VERSION, 'scheduler_recordings' => SchedulerRecordings::VERSION,
          'ood_core_commit' => ood_core_commit }.compact
      end

      private

      # { id => name } for your jobs in the given states.
      def own_jobs(states:)
        out, err, status = run('squeue', '-h', '-u', user.name, "--states=#{states}", '-o', '%i|%j')
        raise "squeue failed: #{err}" unless status.success?

        out.lines.map { |line| line.strip.split('|', 2) }.reject { |id, _| id.to_s.empty? }.to_h
      end

      def slurm_version
        @slurm_version ||= begin
          out, err, status = run('squeue', '--version')
          raise "can't run squeue: #{err}" unless status.success?

          out.strip.sub(/\Aslurm\s+/, '')
        end
      end

      def ood_core_commit
        root = Gem.loaded_specs['ood_core']&.full_gem_path || File.expand_path('../..', $LOADED_FEATURES.grep(%r{/ood_core\.rb\z}).first.to_s)
        out, _err, status = Open3.capture3('git', '-C', root, 'rev-parse', '--short', 'HEAD')
        status.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end

      def run(*args)
        Open3.capture3(*args)
      end
    end
  end
end
