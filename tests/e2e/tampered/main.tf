# A test fixture, not a template to use: templates/agent-workspace/main.tf
# with one field changed at a time, chosen by the workspace parameter
# `variant`. Each variant is what an edited template could ask the API server
# for. tests/e2e/variants.tsv names the refusal each must get, or "admitted"
# for the controls; tests/e2e/run.sh builds one workspace per variant through
# Coder and reads the refusal from the build log.
#
# Home is an emptyDir here, so a refused build leaves no claim behind to eat
# the quota, except in other-home, which mounts the claim it is given.
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
provider "kubernetes" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "variant" {
  name    = "variant"
  type    = "string"
  default = "none"
  mutable = true
}

data "coder_parameter" "claim" {
  name    = "claim"
  type    = "string"
  default = ""
  mutable = true
}

locals {
  v              = data.coder_parameter.variant.value
  namespace      = local.v == "other-namespace" ? "default" : "coder-workspaces"
  workspace_tag  = "docker.io/codercom/example-minimal:ubuntu"
  workspace      = "docker.io/codercom/example-minimal@sha256:137678561bd25b329ad78fe18ed304da48ee5f550aaf6eb8bc727a83dfca6531"
  other_image    = "docker.io/library/alpine@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
  gate_image     = "docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
  image          = local.v == "image-by-tag" ? local.workspace_tag : local.v == "other-image" ? local.other_image : local.workspace
  makes_a_pod    = !contains(["network-policy", "namespace", "cluster-role-binding", "service", "deployment"], local.v)
  limits         = { cpu = "1", memory = "1Gi" }
  container_user = local.v == "root" ? 0 : 1000
  labels = {
    "app.kubernetes.io/name"   = "coder-workspace"
    "com.coder.resource"       = "true"
    "com.coder.workspace.id"   = data.coder_workspace.me.id
    "com.coder.workspace.name" = data.coder_workspace.me.name
  }
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

resource "kubernetes_pod_v1" "main" {
  count = local.makes_a_pod ? data.coder_workspace.me.start_count : 0
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    runtime_class_name              = local.v == "no-gvisor" ? null : "gvisor"
    automount_service_account_token = local.v == "api-token"
    enable_service_links            = false
    restart_policy                  = "Always"
    host_network                    = local.v == "host-network"

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
      run_as_non_root = local.v != "root"
      run_as_user     = local.container_user
      run_as_group    = local.container_user
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
      image   = local.image
      command = ["sh", "-c", coder_agent.main.init_script]
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      dynamic "env" {
        for_each = local.v == "secret-env" ? [1] : []
        content {
          name = "BORROWED"
          value_from {
            secret_key_ref {
              name = "any-secret"
              key  = "key"
            }
          }
        }
      }
      resources {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = local.v == "no-limits" ? {} : local.limits
      }
      security_context {
        run_as_non_root            = local.v != "root"
        run_as_user                = local.container_user
        privileged                 = local.v == "privileged"
        allow_privilege_escalation = local.v == "privileged"
        read_only_root_filesystem  = local.v != "writable-root"
        capabilities {
          drop = ["ALL"]
          add  = local.v == "capability" ? ["NET_ADMIN"] : []
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
      dynamic "volume_mount" {
        for_each = local.v == "host-path" ? [1] : []
        content {
          name       = "host"
          mount_path = "/host"
        }
      }
      dynamic "volume_mount" {
        for_each = local.v == "api-audience-token" ? [1] : []
        content {
          name       = "token"
          mount_path = "/var/run/secrets/tokens"
        }
      }
    }

    volume {
      name = "tmp"
      empty_dir {}
    }
    dynamic "volume" {
      for_each = local.v == "other-home" ? [] : [1]
      content {
        name = "home"
        empty_dir {}
      }
    }
    dynamic "volume" {
      for_each = local.v == "other-home" ? [1] : []
      content {
        name = "home"
        persistent_volume_claim {
          claim_name = data.coder_parameter.claim.value
        }
      }
    }
    dynamic "volume" {
      for_each = local.v == "host-path" ? [1] : []
      content {
        name = "host"
        host_path {
          path = "/"
        }
      }
    }
    dynamic "volume" {
      for_each = local.v == "api-audience-token" ? [1] : []
      content {
        name = "token"
        projected {
          sources {
            service_account_token {
              path               = "token"
              expiration_seconds = 3600
            }
          }
        }
      }
    }
  }
}

# The variants that ask for something other than a pod: each is a thing the
# provisioner's ServiceAccount has no right to make.
resource "kubernetes_network_policy_v1" "open" {
  count = local.v == "network-policy" ? 1 : 0
  metadata {
    name      = "open-${data.coder_workspace.me.id}"
    namespace = "coder-workspaces"
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {}
  }
}

resource "kubernetes_namespace_v1" "own" {
  count = local.v == "namespace" ? 1 : 0
  metadata {
    name = "ws-${data.coder_workspace.me.id}"
  }
}

resource "kubernetes_cluster_role_binding_v1" "admin" {
  count = local.v == "cluster-role-binding" ? 1 : 0
  metadata {
    name = "ws-${data.coder_workspace.me.id}"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "coder-workspaces"
  }
}

resource "kubernetes_service_v1" "exposed" {
  count = local.v == "service" ? 1 : 0
  metadata {
    name      = "ws-${data.coder_workspace.me.id}"
    namespace = "coder-workspaces"
  }
  spec {
    selector = local.labels
    type     = "NodePort"
    port {
      port = 22
    }
  }
}

resource "kubernetes_deployment_v1" "elsewhere" {
  count = local.v == "deployment" ? 1 : 0
  metadata {
    name      = "ws-${data.coder_workspace.me.id}"
    namespace = "coder-workspaces"
  }
  spec {
    replicas = 1
    selector {
      match_labels = { "app.kubernetes.io/name" = "ws-deployment" }
    }
    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "ws-deployment" }
      }
      spec {
        container {
          name  = "dev"
          image = local.workspace
        }
      }
    }
  }
}
