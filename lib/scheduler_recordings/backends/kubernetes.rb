# frozen_string_literal: true

require 'json'
require 'open3'

module SchedulerRecordings
  module Backends
    # Records Open OnDemand's kubernetes adapter against any cluster a
    # kubeconfig can reach (kind, k3s, a site's real cluster).
    #
    # Everything happens in one namespace, named after the pinned identity's
    # user, so recordings look the same wherever they're made. Only pods,
    # services, secrets and configmaps OnDemand labels as its own are
    # deleted between scenarios.
    class Kubernetes
      # The OnDemand user every recording is made as, regardless of who runs
      # the recorder. Tests replaying a recording act as this user.
      IDENTITY = {
        'user' => 'ood',
        'uid' => 1000,
        'gid' => 1000,
        'group' => 'ood',
        'home' => '/home/ood'
      }.freeze

      MANAGED = 'app.kubernetes.io/managed-by=open-ondemand'

      # What OnDemand's adapter calls on the batch object for the user's
      # account; only the fields it reads.
      Account = Struct.new(:name, :uid, :gid, :dir)

      attr_reader :kubeconfig, :kubectl, :image, :timeout

      # Sets the account the adapter would otherwise look up with Etc, on
      # this adapter's batch object only. Replays call this too, so the
      # adapter acts as the user the recording was made as:
      #
      #   adapter = OodCore::Job::Factory.build(adapter: 'kubernetes', ...)
      #   SchedulerRecordings::Backends::Kubernetes.pin_identity(adapter.batch, recording.header['identity'])
      def self.pin_identity(batch, identity = IDENTITY)
        account = Account.new(identity['user'], identity['uid'], identity['gid'], identity['home'])
        group_name = identity['group']
        batch.instance_variable_set(:@username, identity['user'])
        batch.instance_variable_set(:@user, account)
        batch.define_singleton_method(:group) { group_name }
        batch
      end

      def initialize(kubeconfig:, kubectl: nil, image: 'busybox:1.36.1', timeout: 120)
        @kubeconfig = File.expand_path(kubeconfig)
        @kubectl = kubectl || which('kubectl')
        @image = image
        @timeout = timeout
        require 'ood_core'
      end

      def namespace
        IDENTITY['user']
      end

      def identity
        IDENTITY
      end

      # The adapter under test, acting as IDENTITY.
      def adapter
        @adapter ||= build_adapter
      end

      # A job script whose native container settings are small enough to
      # schedule anywhere. Pass container: {...} to override fields.
      def script(container: {}, init_containers: nil, content: 'recorded by scheduler_recordings', **options)
        native = {
          container: {
            name: 'rec',
            image: image,
            command: 'sleep 3600',
            memory: '64Mi',
            cpu: '100m'
          }.merge(container)
        }
        native[:init_containers] = init_containers unless init_containers.nil?
        OodCore::Job::Script.new(content: content, native: native, **options)
      end

      # Machine-specific text recorded as {{placeholders}}.
      def redactions
        { kubeconfig => 'kubeconfig', kubectl => 'kubectl' }
      end

      def prepare
        @adapter = nil
        out, err, status = kubectl_run('create', 'namespace', namespace)
        return if status.success? || err.include?('AlreadyExists')

        raise "could not create namespace #{namespace}: #{err}#{out}"
      end

      def clean_up
        kubectl_run('delete', 'pods,services,secrets,configmaps', '-n', namespace, '-l', MANAGED,
                    '--grace-period=0', '--force', '--wait=true', '--ignore-not-found')
      end

      # The pod as the API server reports it, read without the adapter (and
      # without being recorded). nil when it doesn't exist.
      def pod(id)
        out, _err, status = kubectl_run('get', 'pod', id, '-n', namespace, '-o', 'json')
        status.success? ? JSON.parse(out) : nil
      end

      def container_state(id)
        statuses = pod(id).to_h.dig('status', 'containerStatuses').to_a
        statuses.first.to_h['state'].to_h
      end

      def condition(id, type)
        conditions = pod(id).to_h.dig('status', 'conditions').to_a
        conditions.find { |c| c['type'] == type }
      end

      # Directory name for this cluster's recordings: the API server's
      # version without distribution suffixes ("v1.31.2+k3s1" -> "v1.31.2").
      def version_dir
        server_version[/v\d+\.\d+\.\d+/] || server_version
      end

      def versions
        { 'server' => server_version, 'client' => client_version }
      end

      def recorded_with
        { 'ood_core' => OodCore::VERSION, 'scheduler_recordings' => SchedulerRecordings::VERSION,
          'ood_core_commit' => ood_core_commit }.compact
      end

      private

      def build_adapter
        built = OodCore::Job::Factory.build(adapter: 'kubernetes', config_file: kubeconfig, bin: kubectl)
        self.class.pin_identity(built.batch)
        built
      end

      def server_version
        version_json.dig('serverVersion', 'gitVersion').to_s
      end

      def client_version
        version_json.dig('clientVersion', 'gitVersion').to_s
      end

      def version_json
        @version_json ||= begin
          out, err, status = kubectl_run('version', '-o', 'json')
          raise "kubectl can't reach the cluster: #{err}" unless status.success?

          JSON.parse(out)
        end
      end

      def ood_core_commit
        root = Gem.loaded_specs['ood_core']&.full_gem_path || File.expand_path('../..', $LOADED_FEATURES.grep(%r{/ood_core\.rb\z}).first.to_s)
        out, _err, status = Open3.capture3('git', '-C', root, 'rev-parse', '--short', 'HEAD')
        status.success? ? out.strip : nil
      end

      def kubectl_run(*args)
        Open3.capture3(kubectl, "--kubeconfig=#{kubeconfig}", *args)
      end

      def which(command)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, command)
          return path if File.executable?(path) && !File.directory?(path)
        end
        raise "#{command} not found on PATH; pass --kubectl"
      end
    end
  end
end
