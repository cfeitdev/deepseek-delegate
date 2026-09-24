"""Header filter between LiteLLM and OpenCode.

LiteLLM's Anthropic provider replaces the configured api_key with the client's
Anthropic OAuth token whenever one is present, which would send the Claude login
to OpenCode. Every DeepSeek route points at this filter instead: it forwards only
an allowlist of headers, always authenticates with OPENCODE_API_KEY, and streams
the response back unchanged.

It also rewrites the few Anthropic-only request features OpenCode rejects (see
normalize_messages).

Usage: python opencode-filter.py [port] [upstream]
Set OPENCODE_FILTER_DUMP=1 to save the latest failed request (conversation
included) next to this file as last-failed-request.json, for debugging.
"""
import http.client
import http.server
import json
import os
import sys
import urllib.parse
import winreg

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4011
UPSTREAM = urllib.parse.urlsplit(sys.argv[2] if len(sys.argv) > 2 else "https://opencode.ai/zen/go")

# Only these request headers ever leave the machine. Anything else, including
# authorization, cookies and x-litellm-*, is dropped.
ALLOWED = {"content-type", "accept", "accept-encoding", "anthropic-version", "anthropic-beta", "x-opencode-session"}


def _user_env(name):
    value = os.environ.get(name)
    if not value:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
                value = winreg.QueryValueEx(k, name)[0]
        except OSError:
            value = None
    return value


KEY = _user_env("OPENCODE_API_KEY")
if not KEY:
    sys.exit("opencode-filter: OPENCODE_API_KEY is not set")
DUMP_FAILED = _user_env("OPENCODE_FILTER_DUMP") == "1"
FAILED_DUMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "last-failed-request.json")


def _blocks(content):
    return [{"type": "text", "text": content}] if isinstance(content, str) else list(content)


def _drop_patterns(schema):
    """Remove JSON Schema `pattern` keywords (not properties that happen to be named "pattern")."""
    if isinstance(schema, list):
        return [_drop_patterns(s) for s in schema]
    if not isinstance(schema, dict):
        return schema
    out = {}
    for k, v in schema.items():
        if k == "pattern" and isinstance(v, str):
            continue
        if k in ("properties", "patternProperties", "$defs", "definitions") and isinstance(v, dict):
            out[k] = {name: _drop_patterns(sub) for name, sub in v.items()}
        else:
            out[k] = _drop_patterns(v)
    return out


def normalize_messages(body):
    """Rewrite Anthropic-only message features OpenCode rejects.

    - role "system" messages inside `messages` (Claude Code's mid-conversation notices,
      e.g. after plan approval) -> 400. They become <system-reminder> user text.
    - redacted_thinking blocks in history -> 422. They are dropped.
    - regex `pattern` keywords in tool schemas -> 400 (e.g. Artifact's "^[^\\0]*$").
      They are dropped; Claude Code validates tool input itself.
    Consecutive same-role messages are then merged so user/assistant turns alternate.
    """
    try:
        req = json.loads(body)
    except ValueError:
        return body
    changed = False
    for tool in req.get("tools", []):
        if isinstance(tool, dict) and "input_schema" in tool:
            cleaned = _drop_patterns(tool["input_schema"])
            if cleaned != tool["input_schema"]:
                tool["input_schema"] = cleaned
                changed = True
    messages = req.get("messages")
    if not isinstance(messages, list):
        return json.dumps(req).encode() if changed else body
    out = []
    for msg in messages:
        role, content = msg.get("role"), msg.get("content")
        if role == "system":
            text = content if isinstance(content, str) else "\n".join(
                b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
            msg = {"role": "user", "content": [{"type": "text", "text": "<system-reminder>\n" + text + "\n</system-reminder>"}]}
            changed = True
        elif isinstance(content, list):
            kept = [b for b in content if not (isinstance(b, dict) and b.get("type") == "redacted_thinking")]
            if len(kept) != len(content):
                msg = dict(msg, content=kept or [{"type": "text", "text": "(thinking omitted)"}])
                changed = True
        if out and out[-1].get("role") == msg.get("role"):
            prev = out[-1]
            # tool_result blocks must lead a user message, so merged text goes after them.
            out[-1] = dict(prev, content=_blocks(prev["content"]) + _blocks(msg["content"]))
            changed = True
        else:
            out.append(msg)
    if not changed:
        return body
    req["messages"] = out
    return json.dumps(req).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # response ends when the connection closes; fine for streaming

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_error(404)

    def do_POST(self):
        body = normalize_messages(self.rfile.read(int(self.headers.get("content-length", 0))))
        headers = {k: v for k, v in self.headers.items() if k.lower() in ALLOWED}
        if "anthropic-beta" in {k.lower() for k in headers}:
            name = next(k for k in headers if k.lower() == "anthropic-beta")
            betas = [b.strip() for b in headers[name].split(",") if b.strip() and not b.strip().startswith("oauth")]
            if betas:
                headers[name] = ",".join(betas)
            else:
                del headers[name]
        headers["x-api-key"] = KEY
        headers["content-length"] = str(len(body))

        conn_cls = http.client.HTTPSConnection if UPSTREAM.scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(UPSTREAM.netloc, timeout=600)
        try:
            conn.request("POST", UPSTREAM.path.rstrip("/") + self.path, body=body, headers=headers)
            resp = conn.getresponse()
            if resp.status >= 400:
                self._relay_error(resp, body)
                return
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in {"transfer-encoding", "connection", "content-length"}:
                    self.send_header(k, v)
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            conn.close()

    def _relay_error(self, resp, request_body):
        """Log OpenCode's error and the request's shape (no message content), then relay it."""
        data = resp.read()
        if DUMP_FAILED:
            with open(FAILED_DUMP, "wb") as f:  # local only, overwritten each time
                f.write(request_body)
        try:
            req = json.loads(request_body)
            shape = {k: (v if k in ("model", "max_tokens", "thinking", "output_config", "temperature",
                                    "tool_choice", "context_management", "stream") else type(v).__name__)
                     for k, v in req.items()}
            shape["tool_types"] = sorted({t.get("type", "custom") for t in req.get("tools", [])})
            shape["n_tools"] = len(req.get("tools", []))
        except Exception as e:
            shape = {"unparseable": str(e)}
        sys.stderr.write("opencode-filter: UPSTREAM %d %s\n  request shape: %s\n"
                         % (resp.status, data[:2000].decode("utf-8", "replace"), json.dumps(shape)))
        self.send_response(resp.status)
        self.send_header("content-type", resp.getheader("content-type", "application/json"))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("opencode-filter: " + (fmt % args) + "\n")


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
