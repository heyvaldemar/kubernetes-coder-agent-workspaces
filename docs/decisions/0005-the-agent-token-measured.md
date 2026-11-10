# 5. The workspace's one credential, measured rather than described

- Status: accepted
- Date: 2026-11-10

## Context

A Coder workspace cannot work without its agent's token: it is how the agent proves to the server which workspace it is. Coder's Kubernetes templates hand it to the pod as an environment value, `CODER_AGENT_TOKEN`. The agent then sets it in the environment of every process it starts ("Specific Coder subcommands require the agent token exposed!", `agent/agent.go` at v2.38.6), so an AI agent's shell in the workspace holds it. It is the one credential the boundary cannot take away, so what it can do has to be known, not assumed.

## Decision

The e2e measures the token from both sides on every run, and the README reports what it finds:

- From inside the workspace (`tests/e2e/inside.sh`): the token is in the shell's environment and in PID 1's; the Coder API refuses it as a user's session at `/api/v2/users/me`, `/api/v2/workspaces`, `/api/v2/templates` and `/api/v2/users`; it fetches the owner's Git SSH private key from `/api/v2/workspaceagents/me/gitsshkey`; and it asks `/api/v2/workspaceagents/me/external-auth?id=github` for the owner's GitHub token. The key is reported by its length and the hash of its public half, never by its value.
- From outside: the token sits in the pod spec, readable by whoever may `get pods` in `coder-workspaces` (the provisioner may, and cluster administrators); the Kubernetes API refuses it; the public half of the key it fetched is the owner's own; and a token taken out before a rebuild is asked for the key again afterwards.
- The token stays an environment value. A Secret is what the sandbox's policy refuses in an agent pod, and a file would be written by the same template from the same value.

## Consequences

- What a fooled agent gets from the token is stated in numbers: the owner's Git SSH key, which Coder generates per user for git in workspaces, and the owner's external-auth tokens once the owner links an account. In CI nobody links one, so the call is answered with a sign-in link and an empty token; that the same call returns the token after linking is Coder's design for git in a workspace (`workspaceAgentsExternalAuth` in `coderd/workspaceagents.go`), read in the code, not measured here.
- The token cannot leave the boundary on its own: the only thing a workspace reaches is the Coder server. It is the key's reach inside Coder that matters, and an exfiltration through the Coder server itself (a workspace app, a port forward a person opens) is out of what the network can see.
- The Git SSH key works wherever the owner registered its public half. That is a decision for whoever registers it, and the threat model says so.

## Alternatives

- **Not measuring it.** Every other line of the README would then rest on a credential nobody looked at.
- **A per-workspace identity with less reach.** That is Coder's design to change, not this repository's; the measurement is what a conversation about it would start from.

## How to explain this to a customer

Every workspace holds one key, the one that lets it talk to Coder. We checked what that key opens: it cannot act as a user, list workspaces or touch Kubernetes, but it can read the owner's git key and, once the owner connects GitHub, their GitHub token. So the git key a workspace uses should open only what an agent working in it may touch.
