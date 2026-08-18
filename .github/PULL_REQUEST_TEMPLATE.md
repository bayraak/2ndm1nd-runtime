## What this changes

## Why

## Checklist

- [ ] `swift build` succeeds
- [ ] `swift test` passes
- [ ] `python3 -m compileall -q *.py mcp` passes (if Python touched)
- [ ] `bash -n` passes on any touched shell script (macOS ships bash 3.2)
- [ ] The capture path is still model-free — no code path from sensors,
      connectors, the event store, the sessionizer, or the scheduler invokes
      a model (see CONTRIBUTING.md; PRs breaking this are rejected on
      principle)
- [ ] docs/privacy.md updated if the privacy floor, sandbox, or presence-marker
      semantics changed
