# A first workspace, by hand

The same steps `make demo` runs, one at a time, on a laptop. About fifteen minutes, most of it downloads.

You need Docker with about 8 GB of memory for its VM, `make`, `curl`, `jq` and `python3`. The tools the steps use (kind, kubectl, helm, the coder CLI) are installed at pinned versions and hashes into `.cache/bin` by the first step. Docker Desktop has swap, so `make test` refuses to run there (the sandbox's threat model says why); everything below works.

## 1. The cluster and the boundary

```bash
make up
export PATH="$PWD/.cache/bin:$PATH"
```

That is the sandbox's kind cluster and gVisor, then `scripts/install-coder.sh`: the sandbox's RuntimeClass, admission policy and resolver, this repository's namespaces, policy, Postgres and network policies, a database password generated and handed to kubectl on stdin, Terraform's providers downloaded on your machine into a mirror and copied onto a volume (so the Coder server needs no internet), and the Coder chart from its archive by hash. It ends with four `ready:` lines.

## 2. Sign in

```bash
eval "$(scripts/coder-session.sh)"
coder whoami
```

`coder-session.sh` starts `kubectl port-forward` to the server on `127.0.0.1:7080`, creates the first user (`admin`, `admin@example.com`) with a generated password, and signs the CLI in. The password is in `.cache/coder-cli/first-user-password`, readable by you only; it was never on a command line. Open `http://127.0.0.1:7080` and sign in with it to see the dashboard.

## 3. The template, and a workspace

```bash
coder templates push agent-workspace -d templates/agent-workspace --yes
coder create demo --template agent-workspace --yes
coder ssh demo
```

Inside the workspace:

```bash
uname -r                                                   # 4.19.0-gvisor: gVisor's kernel, not your machine's
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 https://example.com/   # 000: no way out
curl -s http://coder.coder.svc.cluster.local/healthz       # OK: the one door
echo "${#CODER_AGENT_TOKEN}"                                # the agent's token is in every shell
```

Leave with `exit`. To see a refusal, edit `templates/agent-workspace/main.tf`, change `runtime_class_name = "gvisor"` to `null`, push it again and run `coder create demo2 --template agent-workspace --yes`. The build fails with the sandbox policy's message: "an agent pod runs on gVisor; set spec.runtimeClassName to gvisor". Put the line back.

## 4. GitHub, for git in the workspace

Coder calls this external authentication. The server needs a GitHub OAuth app of yours; the template declares the provider; a workspace then gets your GitHub token through its agent when git asks for it.

1. On GitHub: Settings, Developer settings, OAuth Apps, New OAuth App. Homepage URL `http://127.0.0.1:7080`. Authorization callback URL `http://127.0.0.1:7080/external-auth/github/callback`. Register it and generate a client secret.

2. Hand the ID and the secret to the cluster on stdin, so neither reaches your shell history or a process list. `read -s` keeps the secret off the screen:

   ```bash
   read -r  -p "GitHub OAuth client ID: " gh_id
   read -rs -p "GitHub OAuth client secret: " gh_secret; echo
   printf 'client-id=%s\nclient-secret=%s\nredirect-url=http://127.0.0.1:7080/external-auth/github/callback\n' "$gh_id" "$gh_secret" |
     kubectl -n coder create secret generic coder-github --from-env-file=/dev/stdin
   unset gh_id gh_secret
   ```

3. Install again with the GitHub values on top (`helm/values-github.yaml` reads `CODER_EXTERNAL_AUTH_0_CLIENT_ID`, `CODER_EXTERNAL_AUTH_0_CLIENT_SECRET` and `CODER_EXTERNAL_AUTH_0_REDIRECT_URL` from that Secret), then sign in again, since the server restarts. `CODER_GITHUB=app` also gives the server its one way to the internet, TCP 443 (`manifests/optional/coder-server-internet.yaml`), since GitHub's sign-in codes are exchanged from the server:

   ```bash
   CODER_GITHUB=app ./scripts/install-coder.sh
   kill "$CODER_PORT_FORWARD_PID"; eval "$(scripts/coder-session.sh)"
   ```

4. Push the template with the provider declared, and update the workspace:

   ```bash
   coder templates push agent-workspace -d templates/agent-workspace --variable github_external_auth=true --yes
   coder update demo
   ```

5. In the dashboard, open the workspace and link GitHub when it offers to. Inside the workspace, `coder external-auth access-token github` now prints a token: that is the call the e2e measures (ADR 5), and the reason to give this OAuth app only the scopes an agent should have.

What CI proves of this: the same values file and the same Secret keys, with a client ID that names no app; the server starts, the template declares the provider, and the agent's call is answered with the sign-in link. The sign-in itself needs a real app and a person, so it is the step to walk by hand.

## 5. Done

```bash
make down
```

That deletes the cluster with everything in it, the port-forward's target included. `.cache/coder-cli` keeps the old session and password; delete it too.
