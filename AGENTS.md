# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Every row of the README's table "What is proven, and how" is a check that runs in CI: `tests/e2e/run.sh` on a fresh kind cluster with gVisor (`.github/workflows/e2e.yml`), or `scripts/validate.sh` with its planted violations (`.github/workflows/verify.yml`). The tables "The one credential" and "What the control plane dials" are measurements printed by the e2e and by `.github/workflows/server-egress.yml`; a value in them is pasted from a named run, never written. Each refusal is paired with a control that must succeed, so a check cannot pass because the environment refuses everything. A claim with no check is not written, and in `docs/threat-model.md` a control with no check is listed as a residual risk. It is a reference on kind, CPU only, at no cloud cost, and nothing says otherwise: no wording about running anywhere in production, about using Coder before this repository, or about any program, title or certification.

Toward Coder, be exact and respectful. Its licensed features (AI Gateway, Agent Firewall, audit logs, external provisioners, more than one replica) are named in Coder's own words with a link to where Coder says so, and never imitated; this repository is the layer under any edition. Never "bypass", never "a free alternative".

## Before changing anything

- Read the decision record that covers it, under `docs/decisions/`. A change that alters a decision amends that record or adds one, in the same format, ending with how the choice is explained to a customer. A change to a threat or a control changes its row in `docs/threat-model.md`.
- `make check` runs `scripts/validate.sh` (kubeconform, images, vendor, coder, template), then `tests/static/plant_violations.py`, which shows each check its planted violation from `tests/static/plants.tsv`. It must end all caught, none missed, none stale. Verify also runs actionlint, shellcheck and `terraform fmt -check`; `make check` does not.
- `make test` runs the e2e against the cluster `make up GITHUB=placeholder` creates, with `scripts/dns-log.sh on` run before Coder is installed if step 9 is to see the server's first minutes. It fails on a machine with swap, on purpose. Docker Desktop has swap, so the e2e is proved in CI.

## The sandbox is not edited here

`vendor/kubernetes-ai-agent-sandbox/` is kubernetes-ai-agent-sandbox at the commit `VENDOR.txt` names, byte for byte. Nothing under it changes in this repository: `scripts/check-vendor.py` fails Verify on a changed byte or an extra file. A change to the boundary is made in the sandbox, released there, and copied in at the new commit with a new `VENDOR.txt`, in one commit whose diff is the review. Every place this repository does something the sandbox does not is a row in ADR 2.

## A check is trusted only after it has failed

A new or changed check ships with the violation it exists for: a variant of `tests/e2e/tampered/main.tf` with its row in `tests/e2e/variants.tsv` naming the refusal it must get (or `admitted` for a control, `measured` for a finding), a row in `tests/static/plants.tsv`, or a deliberate sabotage run whose failing output is recorded in the commit message. A plant whose text is no longer in its file is reported stale and fails the run, so a change to a planted file updates its row in the same commit. The server-egress workflow's defaults run is step 9's planted violation: a measurement that never saw a name proves nothing.

## Proving a risky change

A change to the template, admission, a network policy, the chart values, a pin or a workflow runs the full e2e and Verify on a branch before it reaches main:

```bash
gh workflow run e2e.yml --ref <branch>
gh workflow run verify.yml --ref <branch>
```

`scripts/status.py` reads e2e runs on main only, so branch runs never touch the badges. A dispatched Verify also runs the freshness job, which fails when upstream has moved past a pin; that failure is about upstream, not the branch.

## Pins

Everything is pinned:

- The Coder chart: version and the sha256 of its archive in `charts.lock`, Coder's stable channel. `scripts/install-coder.sh` refuses an archive that does not match.
- kind, kubectl, kubeconform, helm and the coder CLI: version and sha256 per platform in `tools.lock`. The CLI is the server's version.
- CI images (actionlint, shellcheck, terraform): by digest in `ci-images.pins`.
- Container images: by digest where they are used, in `manifests/`, `helm/values.yaml` (the digest rides on `coder.image.tag`), both templates and `tests/e2e/run.sh`. The workspace image appears in both templates and the gate's busybox in both templates, `manifests/corp.yaml` and `tests/e2e/run.sh`; a bump moves every copy in one commit, and `scripts/validate.sh template` refuses a fixture that differs from the template.
- Terraform providers: by version in both templates and by hash in their identical `.terraform.lock.hcl` files, regenerated with `terraform providers lock -platform=linux_amd64 -platform=linux_arm64` in the pinned terraform image.
- gVisor and the kind node image: the sandbox's, in `vendor/`.
- Actions: by commit SHA, bumped weekly by Dependabot in one group and merged by `dependabot-automerge.yml` only after the e2e and Verify pass. The SLSA generator in `release-assets.yml` is the exception: it refuses a SHA, so it is referenced by tag.

Dependabot reads the actions and the providers. Everything else is moved by hand, with the new hash checked against the publisher's. `scripts/check-freshness.py` reports each pin upstream has moved past, and `scripts/check-vendor.py --upstream` a newer sandbox release; neither changes anything.

## Numbers

The second row of README badges is written by `.github/workflows/status.yml` (`scripts/status.py`) to the `status` branch, from the e2e runs on main and their `e2e-results` artifacts. It is never edited by hand. The counts the README states (nineteen refused variants and one control, fifteen planted violations) are the counts in `tests/e2e/variants.tsv` and `tests/static/plants.tsv`, and change with them in the same commit. When a check fails on one run and passes on the next, find what changed (the runner, its swap, an image, the Coder release) before calling it noise: the `runAsNonRoot` finding and the telemetry trap both came from checks that failed during the build. A threshold or an allowed name comes from a stated cause, and is never widened to get a green run.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` in the same commit as the change. The compare links at the bottom move when a version is cut.
- Tag only a commit whose e2e and Verify are green, or a docs-only commit right after one, and say which in the release notes: what is new, what was found while building it, how it was checked.
- Publishing a release runs `release-assets.yml`: an archive of the tag, a keyless cosign signature and SLSA provenance. Then verify them the way a stranger would, with the `cosign verify-blob` and `slsa-verifier verify-artifact --source-tag <tag>` commands at the top of that workflow.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, commits and files. Commit subjects follow the log: `type(scope): what changed`. Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines.

## Never

- Print a secret or a credential, pass one as a command-line argument, or put one in a file or a log. The database password is generated at install and handed to kubectl on stdin; the first user's password goes to `coder login` in its environment; the e2e hands every token to curl on stdin (`curl --config -`) and reports a key by the hash of its public half.
- Turn off or weaken a check, a policy, a test or a gate to get a run green.
- Edit `vendor/`, or loosen what the sandbox's policy, this repository's policy, Pod Security `restricted` or the provisioner's Role hold workspaces to.
- Open a workspace's egress past its resolver and the Coder server, give the provisioner a right outside `coder-workspaces`, or turn back on a dial `helm/values.yaml` turns off.
- Send anything to Coder from CI: the defaults measurement runs with the server's internet closed.
- Open an issue, a pull request or a comment on Coder's projects, gVisor or any project not the maintainer's. A bug found upstream is written up for the maintainer.
- Touch anything outside this repository's own CI to test a change: no cloud resources, no outside services.
