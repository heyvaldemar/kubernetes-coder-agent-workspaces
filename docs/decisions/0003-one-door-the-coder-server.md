# 3. One door: the Coder server, every connection relayed

- Status: accepted
- Date: 2026-11-10

## Context

A Coder workspace's agent connects out to the server for its API and to a relay (DERP) for every session: the CLI, SSH, the IDEs, port forwards. By default the server also hands clients five Google STUN servers, so a client and an agent can find a direct, peer-to-peer path to each other. A direct path is an inbound connection to the workspace from wherever the client is, and an outbound one to the STUN servers on the internet.

## Decision

- `CODER_BLOCK_DIRECT=true` and `CODER_DERP_SERVER_STUN_ADDRESSES=disable` on the server (`helm/values.yaml`). Every connection to a workspace is relayed by the server's embedded DERP relay, which listens on the server's own HTTP port. No outside relay is configured (`CODER_DERP_CONFIG_URL` stays empty, its default).
- A workspace's egress is two rules (`manifests/network-policies.yaml`): DNS to the workspaces' resolver, and TCP 8080 to the Coder server's pods. Its ingress is none.
- The resolver answers for `cluster.local` and relays nothing (the sandbox's `agent-dns.yaml`), so a name outside the cluster is not resolved and a lookup carries nothing out.
- The Coder server takes connections from workspaces and from itself. It reaches its Postgres, the cluster's DNS, the API server, and the internet on TCP 443 except private, carrier-grade NAT and link-local ranges: the metadata service and the rest of the cluster are not on its list. What it dials there is measured (ADR 6).
- Postgres takes connections from the Coder server only; `corp` refuses every namespace labelled as a sandbox. Both are second walls: they hold if a workspace's own policy is opened by mistake.
- People and the CLI reach the server through whatever the cluster offers. Here it is `kubectl port-forward`, which enters the pod's network namespace directly; a real deployment puts an Ingress or a Gateway in front and adds that controller's namespace to the server's ingress rule.

## Consequences

- The e2e shows both halves from inside a workspace: the Coder server answers, and the internet by name and by address, the Kubernetes API by name and by Service address, the metadata service, another namespace's service, Coder's Postgres and both DNS paths do not. A pod outside the boundary reaches each of them (the metadata service is a stand-in on the node, since kind has none).
- Sessions that could have gone direct are relayed: more latency for a person on a laptop, nothing for an agent working inside the workspace.
- The access URL is plain HTTP inside the cluster. The agent's token and the agent binary travel over it. A deployment with TLS on the access URL closes that, and needs a certificate the workspaces trust.

## Alternatives

- **STUN on, direct connections allowed.** Lower latency for people far from the server. It needs the workspace to take inbound UDP from anywhere and reach STUN servers on the internet, and the egress allowlist stops being one rule.
- **An outside DERP map.** Tailscale's or a company's relays; more places a session's traffic goes, and more names on the allowlist.

## How to explain this to a customer

A workspace talks to exactly one thing, the Coder server, and everything a person or a tool does in it travels through that server. It cannot reach the internet, the cluster's control plane, the cloud's credential service, other teams' systems or Coder's own database, and the systems that matter most also refuse it themselves.
