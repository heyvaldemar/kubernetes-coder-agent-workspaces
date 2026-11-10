# 4. The provisioner is the server, so the cluster holds the boundary

- Status: accepted
- Date: 2026-11-10

## Context

A Coder template is Terraform. When a workspace is built, Coder runs the template with a provisioner, and in Community edition the provisioner runs inside the server process: the chart's values call external provisioner daemons "an Enterprise feature". The Kubernetes provider in a template uses the in-cluster configuration, which is the server's own ServiceAccount. So every template, whoever wrote it, runs with the server's rights, and whatever pod spec it writes is what the API server is asked to create.

A boundary written into the template is therefore a convention. Anyone who can edit a template can take it out.

## Decision

- The server's ServiceAccount gets a Role in `coder-workspaces` only, with Coder's own rules for pods and persistent volume claims, and nothing else: `workspacePerms: false` and `enableDeployments: false` at the top of the chart's values, `workspacePerms: true` for the one entry in `workspaceNamespaces`. No rights in its own namespace, no Deployments, Services, NetworkPolicies, Namespaces, RBAC or Secrets.
- What a workspace pod may be is decided by admission, in the API server: the sandbox's policy (ADR 2), this repository's `coder-workspace` policy for where images come from, and Pod Security `restricted` on the namespace.
- The e2e asks the API server, with `kubectl auth can-i --as=system:serviceaccount:coder:coder`, what the provisioner may do: pods and claims in `coder-workspaces`, and not pods elsewhere, `pods/exec`, Deployments, Services, NetworkPolicies, Namespaces, RoleBindings, ClusterRoleBindings, Secrets in `coder`, or a change to an admission policy or a namespace.
- Then it builds the tampered template (`tests/e2e/tampered/main.tf`) once per variant in `tests/e2e/variants.tsv`, through Coder, and reads the refusal from the build log. One field changes per variant: no gVisor, an API token, a projected token for the API server's audience, an image by tag, no limits, a writable root, a Secret in the environment, another image, privileged, hostPath, host network, root, an added capability, another namespace, and five objects the provisioner may not make. Each must be refused for the reason the table names; the unchanged fixture must be admitted.

## Consequences

- A template author gets the refusal where they look: in the build log, with the rule's own message. The first build of this repository's template was refused that way, by Pod Security, because the Kubernetes provider writes `runAsNonRoot=false` into a container's security context when the block leaves it out.
- The boundary is per namespace, not per workspace. A template that names another workspace's claim can mount it: the e2e builds that variant, reads a file the other workspace wrote, and reports it as a finding, not a pass (the threat model's residual risks).
- The provisioner can read every workspace pod in the namespace, and with it every agent's token (ADR 5).

## Alternatives

- **A namespace per user or per workspace.** Closes the shared-claim finding. The provisioner then needs rights to create namespaces, or an operator that makes them, and the per-namespace policies have to follow; a change for a later release.
- **External provisioners with their own, narrower identity.** A Premium feature; it moves the identity, not the need for admission.
- **Trust template authors.** A template is code that runs as the server. Reviews help; the API server is what refuses.

## How to explain this to a customer

Whoever can edit a workspace template can make the workspace anything the template's identity is allowed to create. So that identity is allowed very little, and Kubernetes itself refuses a workspace that breaks a rule, with a message saying which one, no matter what the template says. Twenty edited templates are tried on every change; nineteen are refused and one is reported as the limit it is.
