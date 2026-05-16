# pearl-runner-build

Builds a Pearl mining runner image and pushes to `ghcr.io/beaaan/pearl-runner`.

Trigger: GitHub Actions → "Build Pearl runner" → Run workflow.

The image bundles `pearld` + `pearl-gateway` + `vllm-miner` + a watchdog into
a single CUDA 12.9 runtime container designed for one-shot launches on
Vast.ai H100/H200 hosts.

Layout:
- `runner/Dockerfile` — multi-stage: vLLM + CUTLASS kernels + pearld release binaries
- `runner/entrypoint.sh` — boots pearld, pearl-gateway, watchdog, then exec's vllm
- `runner/watchdog.sh` — self-destroys the Vast instance on spend cap or share timeout
- `.github/workflows/build-runner.yml` — the actual build job
