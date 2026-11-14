# Security policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release | yes |
| `main` | yes |
| Older releases | no |

## Reporting a vulnerability

Report privately through GitHub: [**Security → Report a vulnerability**](https://github.com/heyvaldemar/kubernetes-coder-agent-workspaces/security/advisories/new) on this repository. Email to connect@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the changelog. Please do not open public issues for security reports.

A vulnerability in Coder itself belongs with Coder, through [coder/coder's security policy](https://github.com/coder/coder/security/policy). One in the vendored boundary belongs with [kubernetes-ai-agent-sandbox](https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/security/policy).

## What this repository is

A reference deployment, not a hosted service. A vulnerability here is most likely a way for a workspace, or a template, to reach or become something the README says it cannot: a path past the network policies, an admission rule a template slips through, a right the provisioner should not have, or a credential the README does not list.

## Supply chain

- Container images are pinned by digest, and CI fails on one that is not; the Coder chart by the sha256 of its archive (`charts.lock`).
- GitHub Actions are pinned by commit SHA; CLI tools by version and sha256 (`tools.lock`); CI images by digest (`ci-images.pins`); the templates' Terraform providers by version and hash (`.terraform.lock.hcl`).
- The sandbox's files are vendored at a pinned commit with each file's sha256 (`vendor/kubernetes-ai-agent-sandbox/VENDOR.txt`), checked on every Verify run and against GitHub weekly.

## Credentials

None stored. The database password and the first user's password are generated at install and are never on a command line or in a log. GitHub external auth reads its client ID and secret from a Secret the user creates on stdin; CI creates one with a client ID that names no app.
