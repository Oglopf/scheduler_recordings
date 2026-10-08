# scheduler_recordings

Real scheduler output for testing [Open OnDemand](https://openondemand.org/)'s
scheduler adapters, without a cluster.

Each recording is made by running ood_core's own adapter against a real
scheduler and capturing every command it runs and everything it gets back.
Tests replay a recording by stubbing `Open3.capture3`, so the adapter's
parsing code runs against real output, from as many scheduler versions as
have been recorded.

```ruby
require 'scheduler_recordings/minitest'

class KubernetesTest < Minitest::Test
  include SchedulerRecordings::Minitest

  def test_running_pod
    SchedulerRecordings.each('kubernetes', 'running_pod') do |recording|
      with_recording(recording, step: :info, kubectl: '/usr/bin/kubectl', kubeconfig: '/etc/k8s.yml') do |_rec, player|
        # adapter: an ood_core kubernetes adapter built with that bin and config_file
        info = adapter.info(recording.facts['id'])

        assert_equal(:running, info.status.to_sym, recording.name)
        assert_all_played(player)
      end
    end
  end
end
```

That one test runs against every recorded Kubernetes version. Recording a
new version adds coverage without changing the test.

## What's recorded

| Scheduler | Versions | Scenarios |
|---|---|---|
| Kubernetes | v1.31.2 (k3s); kind v1.34–v1.37 via the `record` workflow | running_pod, running_pod_not_ready, queued_pod, unschedulable_pod, completed_pod, error_pod, crash_loop_pod, image_error_pod, several_pods, delete_pod, not_found, empty_namespace, invalid_submit |
| Flux | v0.89.0 (fluxrm/flux-sched container) | running_job, held_job, dependent_job, released_job, completed_job, failed_job, timeout_job, canceled_job, several_jobs, not_found, no_jobs, invalid_submit |

The Kubernetes scenario names follow the hand-captured fixtures in ood_core's
`spec/fixtures/output/k8s`, so each recording can check or replace one.

`scheduler-recordings list` shows what's in your installed copy.

## Install

```ruby
group :test do
  gem 'scheduler_recordings'
end
```

No runtime dependencies. Ruby 2.7 or newer. `scheduler_recordings/minitest`
needs minitest, which you already have if you're using it.

## Replaying

| Call | Does |
|---|---|
| `SchedulerRecordings.versions('kubernetes')` | recorded versions, oldest first |
| `SchedulerRecordings.scenarios('kubernetes')` | scenario names in the newest version |
| `SchedulerRecordings.load('kubernetes/v1.31.2/running_pod')` | one `Recording`; `'kubernetes/running_pod'` means the newest version |
| `SchedulerRecordings.each('kubernetes', 'running_pod') { \|r\| }` | that scenario in every version that has it |
| `with_recording(name_or_recording, step: nil, **vars) { \|recording, player\| }` | replaces `Open3.capture3` for the block |
| `assert_all_played(player)` | fails if the test skipped recorded calls |

How replay matches calls:

- **Commands must match exactly.** A command the recording doesn't have
  raises `SchedulerRecordings::UnrecordedCall`, naming the closest recorded
  command. That's usually an adapter change worth looking at.
- **Order between different commands doesn't matter.** Repeats of the same
  command are answered in recorded order, and asking more times than
  recorded raises.
- **`step:` narrows replay** to one part of a scenario. Scenarios label their
  calls (`submit`, `info`, `status`, `info_all`, ...), so a test of `info`
  doesn't have to replay the submit first.
- **Exit status and stderr replay too**, so error handling runs for real:
  `not_found` and `invalid_submit` hold the scheduler's actual error text.

Things that differ between machines are stored as `{{placeholders}}` and
listed in the header's `vars`. For Kubernetes those are `kubectl` and
`kubeconfig`; for Flux, `flux`. Pass your test's values as keywords. Leaving one out is an
error before anything runs.

### What a recording knows

The header of each recording has:

- `versions`: what the scheduler reported (for Kubernetes, the API server
  and kubectl versions).
- `recorded_with`: the ood_core version and commit that made it.
- `identity`: the user the adapter acted as. Every recording is made as user
  `ood` (uid and gid 1000), whoever runs the recorder, so recordings from
  different machines can be compared.
  `SchedulerRecordings::Backends::Kubernetes.pin_identity(adapter.batch, recording.header['identity'])`
  makes a replaying adapter act as that user too. Flux reports the real
  submitting user, so Flux recordings are made as whoever runs the recorder;
  stub `Etc.getpwuid` with
  `SchedulerRecordings::Backends::Flux.account(recording.header['identity'])`
  when replaying (see `test/ood_core/flux_test.rb`).
- `facts`: what the scenario checked directly against the scheduler, without
  the adapter: the job ID, the pod's phase, whether it was ready. Assert the
  adapter agrees with these.
- `seed`: recordings are made after `srand(seed)`, so IDs the adapter
  generates at random come out the same. Call `srand(recording.seed)` before
  replaying a submit to get the recorded ID.

Each call also has `at`, when it ran, for tests whose answers depend on the
clock (a running job's wall time): `recording.time_of(:info)`.

`player.requests` is what your code actually sent, as `[command, stdin]`.
Compare it with the recorded stdin to catch changes in what's submitted, such
as a changed pod template.

## Recording

Recording runs ood_core's adapter, so ood_core has to be loadable:

```sh
ruby -I ../ood_core/lib exe/scheduler-recordings record kubernetes --kubeconfig ~/.kube/config
ruby -I ../ood_core/lib exe/scheduler-recordings record kubernetes --only running_pod,error_pod
ruby -I ../ood_core/lib exe/scheduler-recordings record flux            # from a shell inside `flux start`
```

Recordings go to `recordings/<scheduler>/<version>/<scenario>.jsonl`
(`--out` to change that). For Kubernetes the version is the API server's,
without distribution suffixes (`v1.31.2+k3s1` is recorded as `v1.31.2`).

The Kubernetes recorder works in namespace `ood` on any cluster your
kubeconfig reaches. Between scenarios it deletes only the pods, services,
secrets and configmaps labelled `app.kubernetes.io/managed-by=open-ondemand`
in that namespace. Test pods use `busybox:1.36.1` (`--image` to change it)
and ask for 100m CPU and 64Mi memory.

The Flux recorder talks to whatever instance the shell it runs in can reach,
so run it inside `flux start` (or with `FLUX_URI` set). The version is
flux-core's, without the git suffix (`0.89.0-124-g11c9d4c0f` is recorded as
`v0.89.0`). Between scenarios it cancels every active job of the user running
it, so use a test instance: `fluxrm/flux-sched` in a container works. Jobs
run in `/tmp` so their output files stay out of your checkout.

Only calls inside a scenario's `record` blocks are kept. The polling a
scenario does while it waits for a pod to start isn't recorded, and neither
are its own checks of the cluster, so a recording holds just what the adapter
did.

### In GitHub Actions

The `record` workflow (run it from the Actions tab) records against kind at
Kubernetes v1.34 through v1.37, with whichever ood_core branch you name, and
opens a pull request with the results. Diffs against existing recordings are
real changes in what the API server returns or what the adapter sends.

### Recording at your site

Recordings from production clusters are especially useful for schedulers
that don't run well in a container, or whose commercial and open-source
builds may differ. Record against your cluster, check the files for anything
you don't want public (node names and cluster details are in the output),
and send a pull request.

## Writing scenarios

```ruby
SchedulerRecordings::Scenario.define('kubernetes', 'error_pod', 'A pod whose container exited 3') do |s|
  script = s.script(container: { command: 'sh -c "exit 3"' })
  id = s.record(:submit) { s.adapter.submit(script) }
  s.wait_until('the pod failed') { s.backend.pod(id).dig('status', 'phase') == 'Failed' }
  s.record(:info) { s.adapter.info(id) }
  s.fact('id', id)
  s.fact('phase', 'Failed')
end
```

`lib/scheduler_recordings/scenarios/kubernetes.rb` has the rest.

## Running the tests

```sh
bundle exec rake test                               # the gem itself; no ood_core needed
OOD_CORE=../ood_core bundle exec rake test:ood_core # replays every recording through ood_core
```

## Known limits

- **Kubernetes and Flux so far.** PBS Pro (OpenPBS in a container) is next.
  Flux needs an ood_core with the flux adapter.
- **ood_core's Kubernetes adapter can't submit in a plain Ruby process**
  on ood_core 0.31.1 and master as of October 2026: `batch.rb` uses `ERB` and
  `Array.wrap`, and `helper.rb` uses `Shellwords`, without requiring them.
  Recording needs those fixed in the ood_core you record with.
