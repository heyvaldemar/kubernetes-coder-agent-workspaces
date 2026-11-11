# Threat model

What the cluster defends against when an AI agent in a Coder workspace misbehaves, or when a template is edited to let it, the control for each threat, and the check that proves it. A control without a check is listed as a residual risk, not as a control.

The checks are `tests/e2e/run.sh` on a fresh kind cluster with gVisor (every change and weekly), `scripts/validate.sh` with its planted violations (every change), and `.github/workflows/server-egress.yml` (weekly).

## The assumptions

The agent will be fooled. A model that reads untrusted text can be talked into acting on what it read, and no prompt is a reliable defence against that. The sandbox underneath (kubernetes-ai-agent-sandbox, vendored at v1.4.0) starts from the same assumption, and its threat model covers gVisor, the resolver and the memory-limit finding on nodes with swap; those rows are not repeated here.

The template will be edited. A Coder template is Terraform that runs with the Coder server's identity. Whoever can push a template decides what a workspace pod asks for, so the cluster has to decide what it gets.

## What is protected

| Asset | Why it matters |
|---|---|
| The node's kernel | one kernel bug reachable from a workspace is every pod on the node |
| The cluster API | a token with the right verbs is the cluster |
| Coder's database | every user, every token hash, every template |
| Other workloads | stands in `corp`; another team's API, a database, a secrets store |
| Cloud credentials | the instance metadata service hands them to whoever asks from the node's network |
| The owner's credentials | the Git SSH key Coder keeps per user, and external-auth tokens such as GitHub's |
| The task's own data | what the agent was given is what an attacker wants sent out |

## Threats, controls and evidence

| Threat | Control | Evidence |
|---|---|---|
| The agent sends its task to the internet, by name or by address | a workspace's egress is the resolver and the Coder server, nothing else (`network-policies.yaml`); the resolver answers for the cluster's names only | from inside, example.com does not resolve and 1.1.1.1 times out; from outside the boundary both answer |
| The agent carries data out in DNS names | the resolver relays nothing; the cluster's CoreDNS, which forwards, is out of the workspace's reach | from inside, a random name under example.com is refused by the resolver and a query to the cluster's CoreDNS gets no reply; outside, example.com resolves |
| The agent asks the metadata service for cloud credentials | not on the egress allowlist; the Coder server's own rule excludes 169.254.0.0/16 | from inside, a stand-in at 169.254.169.254 on the node does not answer; from outside the boundary it does |
| The agent uses the Kubernetes API | no token in the pod (the sandbox's policy refuses one, and refuses a projected token for the API server's audience); the API server is not on the allowlist | planted `api-token` and `api-audience-token` templates refused; from inside, the API by name and by Service address times out; the API server answers the agent's own token with 401 |
| The agent reaches another team's service or Coder's Postgres | the allowlist, and second walls: `corp` refuses sandbox namespaces, Postgres takes the Coder server only | from inside both are blocked; outside, corp answers and Postgres still refuses |
| The agent exploits the kernel | gVisor's kernel answers the workspace's system calls; Pod Security `restricted` | the workspace reports `4.19.0-gvisor` while the node runs its own; planted `no-gvisor`, `privileged`, `capability`, `root` templates refused |
| The agent changes its image or gets root | read-only root (the sandbox's policy), no privilege escalation | from inside, a write to `/usr/local/bin` is refused and `sudo` gets nothing; planted `writable-root` refused |
| A template runs the workspace somewhere else | the provisioner's Role exists in `coder-workspaces` only | `kubectl auth can-i` refuses it pods in `coder` and `default`; planted `other-namespace` refused by RBAC |
| A template opens the network or widens its own rights | the provisioner may not create NetworkPolicies, Services, Namespaces, Deployments, RoleBindings or ClusterRoleBindings | `kubectl auth can-i` for each; planted templates making each refused by RBAC |
| A template runs an image of its choosing, or one that can change | the sandbox's policy requires a digest; this repository's admits two repositories only | planted `image-by-tag` and `other-image` refused |
| A template takes a Secret or the host | the sandbox's policy refuses a Secret in a volume or the environment; Pod Security refuses hostPath and host namespaces | planted `secret-env`, `host-path`, `host-network` refused |
| A template's workspace takes the node | CPU and memory limits required; a namespace quota, gVisor's overhead counted | planted `no-limits` refused; the quota's own refusals are the sandbox's measured rows |
| The control plane phones home or reaches out on its own | telemetry, the update check, STUN and Terraform's checkpoint off; Terraform's providers from a read-only mirror; no rule from the server to the internet unless `manifests/optional/` is applied | e2e step 9: from its start to the end of the run, builds and a Coder Agents chat included, the server looks up no outside name, and no policy of its names an outside address; the weekly defaults run sees each name a default dials, so the measurement can see one |
| A model talked into it uses Coder Agents' tools to get out through the workspace | the workspace's boundary applies to the agent's tools as to any process in it; the model endpoint is reached by the Coder server only | e2e step 10: a scripted model asks for the internet, the metadata service, the Kubernetes API, an API token, another namespace, DNS and the model endpoint itself; each is blocked, and the control (`uname -r`) shows the tool ran on gVisor |
| The model provider's key leaks through a workspace | the key is registered with the Coder server, which calls the model; the workspace never holds it | step 10: requests to the model carry it; the workspace's pod spec does not contain it |
| A runtime socket hands out the node | no pod mounts one; Coder on Kubernetes needs none | e2e step 1 reads every pod's hostPath volumes |

## Residual risks

- **With Coder Agents, the model provider sees what the tools read.** The agent's `execute` tool runs with the agent's environment, and tool results go from the control plane to the model over the server's own connection. Measured on every run: a scripted model asks for `CODER_AGENT_TOKEN` and for the owner's Git SSH key through it, and both reach the model endpoint. No network policy around the workspace can see this path. Keep the model endpoint where the operator controls it, and scope what the owner's git key and external-auth apps can do (ADR 7).
- **The agent's token reaches the owner's credentials.** Measured every run: from inside a workspace the agent's token fetches the owner's Git SSH private key, and asks for the owner's GitHub token, which Coder hands over once the owner has linked an account. That is how git works in a Coder workspace. Register that key, and link that account, only where an agent may act; a key with write access to every repository the owner has is the blast radius of one fooled agent (ADR 5).
- **The token is a plain value in the pod spec.** Whoever may read pods in `coder-workspaces` reads every workspace's token: the provisioner and cluster administrators here. A token taken out before a rebuild is measured after it, every run.
- **The boundary is the namespace, not the workspace.** All workspaces share `coder-workspaces`. A template that names another workspace's claim mounts it and reads its files: the e2e builds that variant and reports the read as a finding. A namespace per user, with the policies following, is the fix, and the provisioner would need more rights to make one.
- **The provider mirror is what the installing machine downloaded.** Its packages are checked against their signatures when it is built and against the templates' lock file in the cluster; a provider version that is not in the lock file is not in the mirror, and a build that asks for one fails. Whoever can change the lock file and the mirror together decides what Terraform runs, as with any pinned dependency.
- **Telemetry off is one report late.** A deployment that ever ran with telemetry on sends one report that it was turned off, at the next start (ADR 6).
- **Plain HTTP inside the cluster.** The access URL is `http://coder.coder.svc.cluster.local`; the agent's token and the agent binary cross it. Network policy limits who can be on that path; TLS on the access URL closes it.
- **The agent binary is fetched at start.** From the Coder server, into `/tmp`; its integrity is the server's image digest and the path above, and `/tmp` and the home directory are writable and executable, as in any workspace.
- **A new pod's first instant on kind.** kindnet judges a pod's packets only once it knows the pod's address. The template's gate holds the agent back until the policy has taken hold (the sandbox's ADR 3); a process started before the gate, which a template could add as another init container, gets that moment. Measure it on another network plugin before relying on it.
- **What goes through the Coder server is not seen by the network.** A person who opens a port forward or a workspace app gives the workspace a way to them; that is Coder's access control, not the cluster's.
- **One node, one server replica.** On a real cluster workspaces would run on their own tainted node pool, and the server would sit behind an Ingress with TLS.

## How to explain this to a customer

Assume the agent in a workspace will be tricked, and assume someone will edit the workspace's template. Kubernetes decides what the workspace can be and reach, not the template: it runs on a separate small kernel, talks to the Coder server and nothing else, holds no key to the cluster, and a template that tries to change any of that is refused with the rule it broke. What remains is written down and measured on every change: the workspace's one key can read its owner's git key, and workspaces in one namespace can be pointed at each other's disks by whoever edits templates.
