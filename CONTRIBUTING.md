# Contributing

Thanks for your interest in `aws-observability-stack`! This project is under active development — issues and pull requests are welcome.

## Development workflow

1. Fork the repo.
2. Create a topic branch (`git checkout -b feat/my-thing`).
3. Make your changes — keep commits focused and use [Conventional Commits](https://www.conventionalcommits.org/) style messages (`feat`, `fix`, `docs`, `ci`, `chore`, `refactor`, `test`).
4. Run `make fmt validate` for Terraform changes.
5. Open a pull request describing the **why** as well as the **what**.

## Code expectations

- Terraform: every variable has a description, every resource has tags, lifecycle
  rules where relevant.
- Manifests: requests + limits, runAsNonRoot security context, readiness/liveness probes.
- Alerts: every rule has `summary`, `description`, and `runbook_url` annotations.
- Dashboards: one Grafana JSON per logical view, no machine IDs hard-coded.

## Reporting issues

Open a GitHub issue with reproduction steps. Security issues — please email the
maintainer directly rather than opening a public issue.
