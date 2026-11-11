#!/usr/bin/env python3
"""Coder Agents under the boundary: one chat, driven by the scripted model.

    CODER_URL=... CODER_SESSION_TOKEN_FILE=... MODEL_KEY_FILE=... \\
      tests/e2e/agents.py <workspace-name>

Registers the in-cluster endpoint (manifests/model/) as an OpenAI-compatible
provider with the key in MODEL_KEY_FILE, makes its one model the default,
starts a chat bound to the workspace, waits for the chat to go idle, and
prints one JSON line per fact for tests/e2e/run.sh: the chat's status, and
for each of the agent's execute calls in the chat's messages, its exit code
and the start of its output. The output of a step that reads a credential is
reported by its length only.

Every value crosses on stdin or in a file: the session token and the model key
are read from files, never from the command line. Standard library only.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = os.environ["CODER_URL"].rstrip("/")
TOKEN = open(os.environ["CODER_SESSION_TOKEN_FILE"]).read().strip()
MODEL_KEY = open(os.environ["MODEL_KEY_FILE"]).read().strip()
BASE = os.environ.get("MODEL_BASE_URL", "http://model.model.svc.cluster.local:8080/v1")
SECRET_STEPS = ("printenv CODER_AGENT_TOKEN", "gitsshkey")


def call(method, path, body=None, ok=(200, 201, 204)):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method,
                                 headers={"Coder-Session-Token": TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"message": raw[:300].decode("utf-8", "replace")}
        if e.code in ok:
            return e.code, payload
        return e.code, payload


def fact(**kw):
    print(json.dumps(kw, sort_keys=True), flush=True)


def main():
    workspace = sys.argv[1]
    code, me = call("GET", "/api/v2/users/me")
    org = me["organization_ids"][0]

    code, provider = call("POST", "/api/v2/ai/providers", {
        "type": "openai-compat", "name": "scripted", "display_name": "Scripted (e2e)", "enabled": True,
        "base_url": BASE, "api_keys": [MODEL_KEY]})
    if code == 409 or (code >= 400 and "exist" in json.dumps(provider).lower()):
        code, providers = call("GET", "/api/v2/ai/providers")
        items = providers if isinstance(providers, list) else (providers or {}).get("providers", [])
        provider = next(p for p in items if p.get("name") == "scripted")
    elif code >= 300:
        fact(check="provider", ok=False, detail="HTTP %d: %s" % (code, json.dumps(provider)[:300]))
        return 1
    fact(check="provider", ok=True, detail="openai-compat at %s" % BASE)

    code, model = call("POST", "/api/v2/organizations/%s/chats/models" % org, {
        "ai_provider_id": provider["id"], "model": "scripted", "display_name": "Scripted (e2e)",
        "enabled": True, "is_default": True, "context_limit": 128000})
    if code >= 300 and code != 409:
        fact(check="model", ok=False, detail="HTTP %d: %s" % (code, json.dumps(model)[:300]))
        return 1
    if code == 409 or not model or "id" not in model:
        code, models = call("GET", "/api/v2/organizations/%s/chats/models" % org)
        items = models if isinstance(models, list) else (models or {}).get("models", [])
        model = next(m for m in items if m.get("model") == "scripted")
    fact(check="model", ok=True, detail=model.get("id"))

    code, ws = call("GET", "/api/v2/users/me/workspace/%s" % workspace)
    if code != 200:
        fact(check="workspace", ok=False, detail="HTTP %d" % code)
        return 1

    started = time.time()
    code, chat = call("POST", "/api/v2/chats", {
        "organization_id": org, "workspace_id": ws["id"], "model_config_id": model["id"],
        "content": [{"type": "text", "text": "Prepare the quarterly report from this workspace."}]})
    if code >= 300:
        fact(check="chat", ok=False, detail="HTTP %d: %s" % (code, json.dumps(chat)[:300]))
        return 1
    chat_id = chat["id"]
    status = chat.get("status")
    for _ in range(120):
        time.sleep(2)
        code, chat = call("GET", "/api/v2/chats/%s" % chat_id)
        status = chat.get("status") if code == 200 else "unreadable"
        if status in ("waiting", "error", "requires_action") and time.time() - started > 4:
            break
    fact(check="chat", ok=status == "waiting", detail="status %s after %ds" % (status, time.time() - started),
         status=status, chat_id=chat_id, last_error=(chat or {}).get("last_error"))

    code, page = call("GET", "/api/v2/chats/%s/messages" % chat_id)
    messages = (page or {}).get("messages", []) if isinstance(page, dict) else (page or [])
    calls, results = {}, {}
    for m in messages:
        for part in m.get("content") or []:
            if not isinstance(part, dict):
                continue
            kind = part.get("type")
            if kind == "tool-call" and part.get("tool_name") == "execute":
                args = part.get("args") or part.get("input") or {}
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except ValueError:
                        args = {"command": args}
                calls[part.get("tool_call_id")] = args.get("command", "")
            elif kind == "tool-result":
                results[part.get("tool_call_id")] = part.get("result") if "result" in part else part.get("output")
    for call_id in sorted(calls):
        command = calls[call_id]
        result = results.get(call_id)
        if isinstance(result, str):
            try:
                result = json.loads(result)
            except ValueError:
                result = {"output": result}
        result = result or {}
        output = str(result.get("output", ""))
        secret = any(s in command for s in SECRET_STEPS)
        fact(check="tool", call_id=call_id, exit_code=result.get("exit_code"),
             output_len=len(output), output_head="" if secret else output.strip()[:160])
    fact(check="messages", count=len(messages), tool_calls=len(calls), tool_results=len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
