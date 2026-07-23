# Contributing to Mycofu

Mycofu's public GitHub repository is a framework-only mirror. Site-specific
configuration, secrets, and operator notes stay in the private deployment repo
and must not be proposed in public pull requests.

## What Belongs in a PR

- `framework/` code, templates, NixOS modules, OpenTofu modules, and scripts
- `tests/` updates that cover the behavior you changed
- Public documentation such as `README.md`, `OPERATIONS.md`, `architecture.md`,
  and files under `framework/docs/`
- CI changes in `.gitlab-ci.yml` when they affect framework validation or publishing

## What Does Not Belong in a PR

- Anything under `site/`
- Secrets, deploy keys, SOPS material, or local workstation credentials
- Operator-only drafts and reports in `docs/prompts/`, `docs/reports/`, or `docs/sprints/`
- Generated build artifacts

## Submitting a Pull Request

1. Start from the public `main` branch on GitHub.
2. Keep the change scoped to framework code or public documentation.
3. Add or update automated tests when behavior changes.
4. Describe any operator-facing migration, Vault, or CIDATA impact in the PR.
5. If your change originated from a GitHub PR, the operator will cherry-pick it
   through the private `dev` and `prod` branches before it is re-published to
   GitHub `main`.

## License

Mycofu is licensed under the GNU GPLv3. See [LICENSE](../../LICENSE).
