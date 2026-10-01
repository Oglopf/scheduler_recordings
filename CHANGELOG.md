# Changelog

## 0.1.0 (unreleased)

- Recorder that captures every `Open3.capture3` call an ood_core adapter
  makes against a real scheduler, with machine-specific text replaced by
  `{{placeholders}}`.
- Replay through `Player` and the `SchedulerRecordings::Minitest` helpers.
- Kubernetes backend and 13 scenarios, recorded against Kubernetes v1.31.2.
- `record` workflow for kind at Kubernetes v1.34 through v1.37.
