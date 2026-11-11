# 7. Coder Agents under the boundary, driven by a scripted model

- Status: accepted
- Date: 2026-11-11

## Context

Coder Agents is Coder's own coding agent. Its docs at v2.38.6 ([`docs/ai-coder/agents/index.md`](https://github.com/coder/coder/blob/v2.38.6/docs/ai-coder/agents/index.md)) say the loop runs inside the control plane: the Coder server sends the prompt to a model provider, the model answers with tool calls, and the server runs them in a workspace "over the existing workspace connection", so "no specialized software, API keys, or network access is required inside your workspace". On v2.38.6, "Community licenses support up to five concurrently active agents deployment-wide" ([`docs/ai-coder/agents/licensing-usage.md`](https://github.com/coder/coder/blob/v2.38.6/docs/ai-coder/agents/licensing-usage.md)). On a licensed deployment Coder reports Agent Time to `tallyman-prod.coder.com`; the publisher does nothing without a license that enables it ([`enterprise/coderd/usage/publisher.go`](https://github.com/coder/coder/blob/v2.38.6/enterprise/coderd/usage/publisher.go)).

So the question this repository asks of a workspace has a second half. A model that has been talked into exfiltration does not run in the workspace at all. It asks the control plane to run commands there, and reads what they print.

## Decision

- A scripted model, `manifests/model/model.py`: an OpenAI-compatible endpoint (Chat Completions, streamed or not) in its own namespace, reached by the Coder server and nothing else. It answers from a fixed script: one control (`uname -r`), then one `execute` call per thing a fooled agent reaches for, then a closing message. No weights, no GPU, the same run every time, in the spirit of the sandbox's ADR 4.
- It records, where a model provider would sit, what a provider receives: for each tool result, its length, the sha256 of its output and whether it holds a private key. It never records a value.
- `tests/e2e/agents.py` registers it through Coder's API (`POST /api/v2/ai/providers` with type `openai-compat`, `POST /api/v2/organizations/{org}/chats/models`), starts a chat bound to the e2e workspace (`POST /api/v2/chats`) and reads the chat's messages. The model's key is generated per run, handed over in a file, and registered with the Coder server, which sends it on every request.
- The e2e's step 10 gates: the control runs on gVisor's kernel; each of eight attempts dies at the boundary (the internet by name and by address, the metadata service, the Kubernetes API, an API token on disk, another namespace's service, DNS, and the model endpoint itself from inside the workspace); the model key appears nowhere in the workspace's pod; and during the chat the server looks up no outside name, so no usage report leaves. It measures, and reports, what reached the model endpoint from the two steps that read a credential.

## Consequences

- Measured on 2026-11-11 on a local kind cluster, and on every e2e run since: the agent's `execute` tool runs in the workspace with the agent's environment, so `printenv CODER_AGENT_TOKEN` prints the token, and a command that hands that token to `/api/v2/workspaceagents/me/gitsshkey` prints the owner's Git SSH private key. Both reached the model endpoint in the next request. The boundary saw none of it, and could not: tool results travel from the workspace to the Coder server over the workspace connection, and from the server to the model provider over the one path the server is meant to have.
- So with Coder Agents the model provider is inside the trust boundary whether it is wanted there or not. Whatever a tool can read, the provider can receive. A model endpoint the operator runs (a gateway in the cluster, a self-hosted model) keeps that inside what the operator controls; a provider on the internet does not.
- Coder's AI Gateway, a Premium feature, sits on the model traffic; this repository does not use it and claims nothing about what it would catch.
- The control plane now needs egress to the model. Here that is one rule to an in-cluster namespace; a provider on the internet needs `manifests/optional/coder-server-internet.yaml` (`CODER_SERVER_INTERNET=open`), and then it receives what the tools read.

## Alternatives

- **A real model.** Not deterministic, needs a key or a GPU, and would only sometimes be fooled. A small model through the inference gateway may follow as a scheduled, non-gating run.
- **Measuring the network only.** The eight blocks would pass and the two findings would not exist: the leak is through the loop, not through the workspace's network.

## How to explain this to a customer

Coder's agent thinks in the control plane and acts in the workspace. We gave it a model that tries to steal on purpose. Every way out of the workspace was shut, and the agent still handed the model the workspace's key and the user's git key, because reading files and printing them is what the agent is for. Choose the model endpoint as carefully as the workspace: it sees everything the agent sees.
