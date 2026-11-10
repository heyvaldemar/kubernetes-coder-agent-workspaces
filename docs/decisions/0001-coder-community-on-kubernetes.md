# 1. Coder Community on Kubernetes, stable channel, chart by archive hash

- Status: accepted
- Date: 2026-11-10

## Context

A coding agent needs somewhere to run that has a shell, a filesystem and the project's tools, and that a person can open too. Coder gives each user workspaces defined by Terraform templates, with an agent inside each one that the server, the CLI and the IDEs reach through it. Coder ships a Helm chart for Kubernetes and a Compose file. The Compose file mounts the host's Docker socket into the server, which hands the host to every template; on Kubernetes the server creates pods through the API server, where admission can refuse them.

Coder publishes two release channels. The 2026-11-03 releases name v2.39.0 a mainline release ("We advise enterprise customers without a staging environment to install our latest stable release") and v2.38.6 the stable one, which GitHub also marks as the latest release.

## Decision

- Coder Community edition, the chart `coder` 2.38.6 from `https://helm.coder.com/v2`, installed from its archive. `charts.lock` pins the archive's sha256, which is the digest the repository's index publishes; `scripts/install-coder.sh` refuses an archive whose hash differs. The server image is `ghcr.io/coder/coder:v2.38.6` by digest.
- The stable channel. `scripts/check-freshness.py` compares the chart and the CLI with Coder's stable release (GitHub's latest), not with the newest version in the chart index, which is mainline.
- PostgreSQL from the official image, `postgres:17.11-alpine3.24` by digest, as one StatefulSet in `manifests/postgres.yaml`. Coder needs PostgreSQL 13 or later; its own Compose file uses 17. No bitnami chart or image.
- Every server setting that differs from the chart's default is in `helm/values.yaml` with its reason, flag names taken from `codersdk/deployment.go` at v2.38.6.
- Nothing Premium. External provisioner daemons, workspace proxies, high availability, audit logging and AI Governance (AI Gateway, Agent Firewall) are licensed features and are not used or imitated here. This repository is the layer under any edition: what the cluster lets a workspace be and reach.

## Consequences

- An install is the same bytes on every machine: the chart archive by hash, the images by digest, the CLI by hash (`tools.lock`).
- Stable trails mainline by a release. A fix that ships only on mainline arrives here when Coder promotes it; the weekly freshness job says when stable moves.
- Coder patches several release lines at once (2026-11-03: v2.39.0, v2.38.6, v2.37.10, v2.34.18, v2.29.26). A pin here needs the same upkeep as any other.
- One server replica: high availability is a Premium feature, and on kind there is nothing to fail over to.

## Alternatives

- **Mainline.** Newer features, and Coder's own advice is to stage it first. A reference people copy should start where Coder points production.
- **The Compose file.** One host, and the server holds the host's Docker socket. The boundary this repository is about cannot exist there.
- **`helm install --repo ... --version`.** The index decides what that installs; an archive by hash cannot change under the same version.

## How to explain this to a customer

Coder runs here exactly as Coder ships it for Kubernetes, on the release Coder recommends for production, with every file it installs checked against a fingerprint first. The free edition is enough: what keeps an agent's workspace contained is Kubernetes itself, not a paid tier.
