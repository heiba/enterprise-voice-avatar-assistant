# Contributing

Thank you for helping with this quickstart. It is maintained by the AI quickstart team at Red Hat; the current owners are Mohamed Heiba (frontend, workflows, demo) and Sander (platform and chart), with the backend services shared.

## Before you start

- Read the [README](README.md) for what the quickstart does and how it deploys, and [docs/development.md](docs/development.md) for running the pieces locally.
- Open an issue for anything beyond a small fix, so the scope can be agreed first. Bug reports are most useful with the output of `scripts/demo-preflight.sh` and `scripts/cluster-versions.sh`.

## Making a change

1. Branch from `main`; keep one topic per branch.
2. Run the checks the CI runs: `ruff check` and `pytest` in every Python service you touched, `npm run build` for the frontend, `helm lint chart -f chart/values-demo-cluster.yaml` for the chart.
3. If you changed `chart/values.yaml`, run `scripts/gen-values-reference.py --write` and commit `chart/README.md` with it. If you changed a sample document, rebuild with `scripts/build-sample-docs.sh` and commit the rendered files.
4. Open a pull request against `main` with a short description of the change and how you verified it. CI (`.github/workflows/ci.yaml`) must be green; a maintainer reviews and squash-merges.
5. Merges to `main` that touch a service build new images and update the demo cluster automatically; mention in the PR if a change needs a values update or a secret on the demo cluster.

## Rules that keep the quickstart deployable

- No cluster-admin requirements in the chart; everything runs as a regular project user under the restricted SCC.
- No secrets in git, in values files, or in workflow JSON; secrets are created by `scripts/create-secrets.sh` and referenced by name.
- Every value in `values.yaml` has a comment above it.
- Sample data stays synthetic and license-clean, with no real company, person or location.
- Documentation changes go with the code change that needs them, not later.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
