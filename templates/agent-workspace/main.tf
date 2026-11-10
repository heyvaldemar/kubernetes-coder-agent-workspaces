# A Coder workspace for an AI agent, inside the boundary the cluster holds.
#
# Every field of the pod below is one the cluster requires: leave one out and
# the API server refuses the build, and the build log says which rule
# (manifests/admission.yaml, the sandbox's policy in vendor/, Pod Security
# "restricted"). The template does not hold the boundary; it is written to
# fit it. A template edited to step outside is refused, which the e2e shows
# with tests/e2e/tampered/.
#
# Two things differ from Coder's own Kubernetes example, and why:
#   - The pod asks the workspaces' own resolver, which answers for the
#     cluster's names only, and an init container holds the agent back until
#     the pod's network policy has taken hold: the sandbox's gate, with the
#     sandbox's busybox, verbatim (ADR 3 there).
#   - The root filesystem is read-only. The agent is still fetched the way
#     Coder fetches it, by coder_agent.init_script from the Coder server (the
#     one address a workspace reaches), into /tmp, which is an emptyDir.
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.20.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
  }
}

provider "coder" {}

# In-cluster configuration: the Coder server's ServiceAccount, which may
# create pods and claims in coder-workspaces and nothing else.
provider "kubernetes" {}

# GitHub as Coder external authentication, for git in the workspace. Off by
# default; on with `coder templates push --variable github_external_auth=true`
# once the server has a GitHub provider (helm/values-github.yaml,
# docs/first-workspace.md). Optional: a workspace starts without a linked
# account. The agent's token is what fetches the owner's GitHub token from
# inside the workspace; the e2e measures that call.
variable "github_external_auth" {
  type        = bool
  description = "Declare the server's GitHub external auth provider (id github) to workspaces."
  default     = false
}

data "coder_external_auth" "github" {
  count    = var.github_external_auth ? 1 : 0
  id       = "github"
  optional = true
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  namespace = "coder-workspaces"
  # The workspace: Coder's minimal Ubuntu image (bash, curl, git, jq), user
  # coder with uid 1000.
  workspace_image = "docker.io/codercom/example-minimal@sha256:137678561bd25b329ad78fe18ed304da48ee5f550aaf6eb8bc727a83dfca6531"
  # The gate's image: the sandbox's busybox, the same digest.
  gate_image = "docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
    "app.kubernetes.io/part-of"  = "coder"
    "com.coder.resource"         = "true"
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.workspace.name"   = data.coder_workspace.me.name
    "com.coder.user.id"          = data.coder_workspace_owner.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  }
  # The gate, from the sandbox's agent Job: the resolver must answer a
  # cluster name (the network is up) and the cluster's CoreDNS must not
  # answer (the policy has taken hold). A minute at most.
  gate = join(" ", [
    "for i in $(seq 1 60); do",
    "if nslookup -timeout=1 coder.coder.svc.cluster.local 10.96.0.53 >/dev/null 2>&1 && ! nslookup -timeout=1 example.com 10.96.0.10 >/dev/null 2>&1; then exit 0; fi;",
    "sleep 1; done;",
    "echo 'the network policy never took hold'; exit 1",
  ])
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch
  dir  = "/home/coder"
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = local.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_pod_v1" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    runtime_class_name              = "gvisor"
    automount_service_account_token = false
    enable_service_links            = false
    restart_policy                  = "Always"

    dns_policy = "None"
    dns_config {
      nameservers = ["10.96.0.53"]
      searches    = ["coder-workspaces.svc.cluster.local", "svc.cluster.local", "cluster.local"]
      option {
        name  = "ndots"
        value = "5"
      }
    }

    security_context {
      run_as_non_root = true
      run_as_user     = 1000
      run_as_group    = 1000
      fs_group        = 1000
      seccomp_profile {
        type = "RuntimeDefault"
      }
    }

    init_container {
      name    = "wait-for-the-wall"
      image   = local.gate_image
      command = ["sh", "-c", local.gate]
      resources {
        requests = {
          cpu    = "10m"
          memory = "16Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "32Mi"
        }
      }
      # Said again per container: the provider writes runAsNonRoot=false into
      # a container's securityContext when the block leaves it out, and Pod
      # Security refuses that whatever the pod says.
      security_context {
        run_as_non_root            = true
        allow_privilege_escalation = false
        read_only_root_filesystem  = true
        capabilities {
          drop = ["ALL"]
        }
      }
    }

    container {
      name    = "dev"
      image   = local.workspace_image
      command = ["sh", "-c", coder_agent.main.init_script]
      # The agent's one credential. Coder's templates hand it over as an
      # environment value; the sandbox's policy refuses a Secret here. What
      # this token can do is measured (README, "The one credential").
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      resources {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
      # Said again per container: the provider writes runAsNonRoot=false into
      # a container's securityContext when the block leaves it out, and Pod
      # Security refuses that whatever the pod says.
      security_context {
        run_as_non_root            = true
        allow_privilege_escalation = false
        read_only_root_filesystem  = true
        capabilities {
          drop = ["ALL"]
        }
      }
      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }
      volume_mount {
        name       = "tmp"
        mount_path = "/tmp"
      }
    }

    volume {
      name = "tmp"
      empty_dir {
        size_limit = "1Gi"
      }
    }
    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }
  }
}
