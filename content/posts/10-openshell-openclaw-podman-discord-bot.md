---
title: Running AI Agents inside OpenShell Sandboxes with Rootless Podman
---

I've been running AI agents on my workstation for a while now. First it was [[03-ollama-rootless-podman-quadlet|Ollama under rootless Podman]], then Hermes Agent with Vertex AI. Recently I wanted to run both [OpenClaw](https://openclaw.ai/) and [Hermes Agent](https://github.com/NousResearch/hermes-agent) as Discord bots, but I didn't want to just run them as bare containers. If an AI agent is going to have network access and API credentials, I want something between it and the outside world.

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) provides exactly that: sandboxed runtimes for AI agents with kernel-level isolation, policy-enforced network egress, and credential injection. The agent never sees your real API keys. The proxy intercepts every outbound connection and evaluates it against a YAML policy before anything leaves the box.

The catch is that OpenShell's local deployment path (`openshell gateway start`) spins up a full k3s cluster inside a container, which doesn't work on Fedora Atomic with rootless Podman (kubelet needs `/dev/kmsg`, which rootless containers can't access). So I set up the gateway as a plain container on a Podman bridge network instead.

I haven't seen anyone else running this exact combination, so I thought I would share how it all fits together.

## The architecture

There are three pieces:

1. **OpenShell gateway** runs as a Podman Quadlet systemd service. It manages sandbox lifecycle, mTLS, JWT auth, provider credentials, and network policy.
2. **Agent sandboxes** are created by the gateway via the Podman driver. Each runs inside an OpenShell supervisor with a network namespace, transparent proxy, Landlock filesystem restrictions, and credential injection.
3. **NemoClaw images** are the container images. They're built from [NVIDIA's NemoClaw](https://github.com/NVIDIA/NemoClaw) repo (which bundles agents with security hardening and proxy preload scripts), then layered with Discord config.

The gateway and sandboxes sit on the same Podman bridge network (`openshell`) so they can communicate directly. The gateway is published on `0.0.0.0:8080` so I can reach it from other machines on my Tailscale network.

## Setting up the gateway

The gateway runs as a containerized service via a [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) unit file:

```ini
[Unit]
Description=OpenShell Gateway
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/nvidia/openshell/gateway:latest
ContainerName=openshell-gateway

PublishPort=0.0.0.0:8080:8080
Network=openshell

Volume=openshell-state:/var/openshell:Z
Volume=%t/podman/podman.sock:/var/run/podman.sock
Volume=%h/.config/openshell/gateway.toml:/etc/openshell/gateway.toml:ro
Volume=%h/.local/state/openshell/tls:/etc/openshell-tls:ro
Volume=%h/.local/state/openshell/tls/jwt:/etc/openshell-jwt:ro
Volume=%h/.local/state:%h/.local/state:Z

Environment=OPENSHELL_DRIVERS=podman
Environment=OPENSHELL_PODMAN_SOCKET=/var/run/podman.sock
Environment=OPENSHELL_DB_URL=sqlite:/var/openshell/openshell.db
Environment=OPENSHELL_GATEWAY_CONFIG=/etc/openshell/gateway.toml
Environment=XDG_STATE_HOME=%h/.local/state

User=0
SecurityLabelDisable=true

[Service]
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=default.target
```

A few things worth calling out:

- `SecurityLabelDisable=true` is needed because SELinux blocks the container from accessing the Podman socket, even with `:Z` relabeling. Since this is rootless Podman, running as `User=0` inside the container is safe (it maps to your unprivileged UID on the host).
- `XDG_STATE_HOME` is set to the host path so the gateway writes sandbox JWT tokens where the host Podman daemon can find them. Without this, the gateway writes tokens inside its own container filesystem, and Podman can't bind-mount them into sandbox containers.
- The `Network=openshell` line puts the gateway on a named bridge network. Sandbox containers join the same network, so they reach the gateway at `openshell-gateway:8080` by container name.

## TLS and authentication

The gateway needs mTLS certificates and JWT signing keys. OpenShell ships a `generate-certs` command for this:

```bash
mkdir -p ~/.local/state/openshell/tls

podman run --rm --user 0 \
  -v "$HOME/.local/state/openshell:/output:Z" \
  -v "$HOME/.config/openshell:/config:Z" \
  --security-opt label=disable \
  ghcr.io/nvidia/openshell/gateway:latest \
  generate-certs \
    --output-dir /output/tls \
    --server-san openshell-gateway \
    --server-san $(hostname)
```

The `--server-san` flags add Subject Alternative Names to the server certificate. I added my Tailscale hostname so I can reach the gateway from other machines. The client certs go in `~/.config/openshell/gateways/` for the CLI to pick up automatically.

The gateway TOML config references these certs and tells the Podman driver where to find the client TLS material on the host filesystem (not inside the gateway container):

```toml
[openshell]
version = 1

[openshell.gateway]
bind_address = "0.0.0.0:8080"

[openshell.gateway.tls]
cert_path = "/etc/openshell-tls/server/tls.crt"
key_path = "/etc/openshell-tls/server/tls.key"
client_ca_path = "/etc/openshell-tls/ca.crt"

[openshell.gateway.gateway_jwt]
signing_key_path = "/etc/openshell-jwt/signing.pem"
public_key_path = "/etc/openshell-jwt/public.pem"
kid_path = "/etc/openshell-jwt/kid"
gateway_id = "openshell"
ttl_secs = 3600

[openshell.drivers.podman]
grpc_endpoint = "https://openshell-gateway:8080"
guest_tls_ca = "/home/shanemcd/.local/state/openshell/tls/ca.crt"
guest_tls_cert = "/home/shanemcd/.local/state/openshell/tls/client/tls.crt"
guest_tls_key = "/home/shanemcd/.local/state/openshell/tls/client/tls.key"
```

The `guest_tls_*` paths are host filesystem paths because the Podman driver bind-mounts them into sandbox containers. If you put container-internal paths here, the host Podman daemon won't find the files.

## Creating providers

OpenShell providers hold credentials and inject them into sandboxes as opaque placeholders. The agent process never sees the real values. The proxy resolves placeholders at egress time.

```bash
openshell provider create --name openrouter --type openai \
  --credential "OPENAI_API_KEY=$(secret-tool lookup service openshell key openrouter-api-key)" \
  --credential "OPENROUTER_API_KEY=$(secret-tool lookup service openshell key openrouter-api-key)" \
  --config "OPENAI_BASE_URL=https://openrouter.ai/api/v1"

openshell provider create --name discord --type generic \
  --credential "DISCORD_BOT_TOKEN=$(secret-tool lookup service openshell key discord-bot-token)"
```

The OpenRouter provider needs both `OPENAI_API_KEY` and `OPENROUTER_API_KEY` because different agents read different env vars. OpenClaw uses `OPENROUTER_API_KEY`. Hermes uses the OpenAI SDK which reads `OPENAI_API_KEY`. Having both means the same provider works for either agent.

## The network policy

This is where OpenShell earns its keep. Every outbound connection from the sandbox goes through the transparent proxy and is evaluated against the policy. If there's no matching rule, the connection is denied with a 403.

```yaml
version: 1

filesystem_policy:
  read_only: [/usr, /lib, /etc]
  read_write: [/sandbox, /tmp, /dev/null, /dev/urandom]

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

network_policies:
  discord_gateway:
    name: discord-gateway
    endpoints:
      - host: "*.discord.gg"
        port: 443
        protocol: websocket
        enforcement: enforce
        access: full
        websocket_credential_rewrite: true
    binaries:
      - path: /usr/local/bin/node
      - path: /usr/bin/python3.13

  discord_api:
    name: discord-api
    endpoints:
      - host: discord.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: full
      - host: discordapp.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: full
    binaries:
      - path: /usr/local/bin/node
      - path: /usr/bin/python3.13

  openrouter:
    name: openrouter
    endpoints:
      - host: openrouter.ai
        port: 443
        protocol: rest
        enforcement: enforce
        access: full
    binaries:
      - path: /usr/local/bin/node
      - path: /usr/bin/python3.13
```

The Discord WebSocket endpoint needs `websocket_credential_rewrite: true` so the proxy can resolve the bot token placeholder in the WebSocket IDENTIFY payload. Without this, Discord rejects the connection with error code 4004 (authentication failed) because it receives the placeholder string instead of the real token.

I've included both `node` and `python3.13` in the binary allowlists so the same policy works for OpenClaw (Node.js) and Hermes (Python). You could split these into separate policy files per agent if you want tighter binary restrictions.

The policy is hot-reloadable. If you need to add a new endpoint, you update the YAML and run:

```bash
openshell policy set <sandbox-name> --policy policy.yaml
```

No sandbox restart needed. The proxy picks up the new rules within seconds.

## OpenClaw

OpenClaw is a Node.js agent. The image is a two-layer build: the NemoClaw base from source, then a config layer with the Discord plugin.

### Building the NemoClaw base

```bash
git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git /tmp/nemoclaw-src

podman build -t nemoclaw-discord:latest \
  --build-arg NEMOCLAW_MODEL=openrouter/anthropic/claude-sonnet-5 \
  --build-arg NEMOCLAW_PROVIDER_KEY=openrouter \
  --build-arg NEMOCLAW_UPSTREAM_PROVIDER=openrouter \
  --build-arg NEMOCLAW_PRIMARY_MODEL_REF=openrouter/anthropic/claude-sonnet-5 \
  --build-arg NEMOCLAW_INFERENCE_BASE_URL=https://openrouter.ai/api/v1 \
  --build-arg NEMOCLAW_INFERENCE_API=openai-completions \
  -f /tmp/nemoclaw-src/Dockerfile \
  /tmp/nemoclaw-src
```

### Config layer

```dockerfile
FROM localhost/nemoclaw-discord:latest

USER root
ENV HOME=/sandbox

# Disable managed proxy during build (points at sandbox proxy that doesn't exist yet)
RUN node -e ' \
  const fs = require("fs"); \
  const p = "/sandbox/.openclaw/openclaw.json"; \
  const c = JSON.parse(fs.readFileSync(p, "utf8")); \
  c.proxy.enabled = false; \
  fs.writeFileSync(p, JSON.stringify(c, null, 2)); \
' && \
    NPM_CONFIG_OFFLINE=false openclaw plugins install npm:@openclaw/discord@2026.6.10 && \
    node -e ' \
  const fs = require("fs"); \
  const p = "/sandbox/.openclaw/openclaw.json"; \
  const c = JSON.parse(fs.readFileSync(p, "utf8")); \
  c.proxy.enabled = true; \
  fs.writeFileSync(p, JSON.stringify(c, null, 2)); \
'

RUN openclaw doctor --fix 2>/dev/null; \
    openclaw config set gateway.mode local && \
    openclaw models set openrouter/anthropic/claude-sonnet-5 && \
    openclaw config set agents.defaults.memorySearch.enabled false

# Pre-configure Discord channel and owner
RUN node -e ' \
  const fs = require("fs"); \
  const p = "/sandbox/.openclaw/openclaw.json"; \
  const c = JSON.parse(fs.readFileSync(p, "utf8")); \
  c.channels = c.channels || {}; \
  c.channels.discord = { \
    enabled: true, \
    accounts: { \
      default: { \
        enabled: true, \
        dmPolicy: "allowlist", \
        allowFrom: ["YOUR_DISCORD_USER_ID"], \
        healthMonitor: { enabled: false } \
      } \
    } \
  }; \
  c.commands = c.commands || {}; \
  c.commands.ownerAllowFrom = ["discord:YOUR_DISCORD_USER_ID"]; \
  c.plugins = c.plugins || {}; \
  c.plugins.entries = c.plugins.entries || {}; \
  c.plugins.entries.discord = { enabled: true }; \
  c.skills = c.skills || {}; \
  c.skills.entries = c.skills.entries || {}; \
  c.skills.entries.discord = { enabled: true }; \
  fs.writeFileSync(p, JSON.stringify(c, null, 2)); \
'

RUN chown -R sandbox:sandbox /sandbox/.openclaw

USER sandbox
WORKDIR /sandbox
```

The proxy toggle during the plugin install is necessary because the NemoClaw base image bakes in a managed proxy config pointing at `10.200.0.1:3128` (the OpenShell sandbox proxy). That proxy doesn't exist at build time, so npm would hang trying to route through it.

The owner and allowed users are baked into the image because once the sandbox is running, Landlock filesystem restrictions prevent the OpenClaw CLI from writing to its SQLite database.

### Creating the sandbox

```bash
openshell sandbox create \
  --name clankr \
  --from localhost/nemoclaw-discord-configured:latest \
  --provider openrouter \
  --provider discord \
  --policy policy.yaml \
  --no-tty \
  -- /usr/local/bin/nemoclaw-start
```

The `nemoclaw-start` entrypoint is important for OpenClaw. It handles privilege separation, gateway auth token generation, and most critically, it loads a Node.js preload script (`http-proxy-fix.js`) that patches `https.request()` to properly route WebSocket CONNECT tunnels through the sandbox proxy. Without this preload, Node.js tries to resolve DNS directly (which is blocked by nftables in the sandbox network namespace) and you get `EAI_AGAIN` errors on every connection.

## Hermes Agent

Hermes is a Python agent. The setup is simpler because Python's `httpx` (used by the OpenAI SDK) natively respects the transparent proxy without needing preload hacks.

### Building the image

The NemoClaw base for Hermes:

```bash
podman build -t nemoclaw-hermes:latest \
  -f /tmp/nemoclaw-src/agents/hermes/Dockerfile \
  /tmp/nemoclaw-src
```

Then a config layer using Hermes's native `config set` commands:

```dockerfile
FROM localhost/nemoclaw-hermes:latest

USER root
ENV HOME=/sandbox

RUN mkdir -p /sandbox/.hermes && \
    hermes config set model.default anthropic/claude-sonnet-5 && \
    hermes config set model.provider custom && \
    hermes config set model.base_url https://openrouter.ai/api/v1 && \
    hermes config set providers.custom.api https://openrouter.ai/api/v1 && \
    hermes config set providers.custom.default_model anthropic/claude-sonnet-5 && \
    hermes config set platforms.discord.enabled true && \
    hermes config set discord.require_mention 1 && \
    hermes config set discord.auto_thread true && \
    hermes config set discord.reactions true

# Remove api_key fields so the OpenAI SDK falls back to OPENAI_API_KEY env var
RUN sed -i '/api_key:/d' /sandbox/.hermes/config.yaml

RUN printf 'DISCORD_ALLOWED_USERS=YOUR_DISCORD_USER_ID\nDISCORD_ALLOW_ALL_USERS=false\n' \
    > /sandbox/.hermes/.env

RUN chown -R sandbox:sandbox /sandbox/.hermes

USER sandbox
WORKDIR /sandbox
```

The `sed` to remove `api_key` lines is the key trick. The NemoClaw base bakes in `sk-OPENSHELL-PROXY-REWRITE` as a static placeholder that NemoClaw's own proxy would resolve, but the OpenShell proxy doesn't know about it. With no `api_key` in the config, the OpenAI SDK falls back to the `OPENAI_API_KEY` environment variable, which OpenShell injects as a credential placeholder. The proxy resolves that placeholder in the `Authorization: Bearer` header at egress time.

### Creating the sandbox

```bash
openshell sandbox create \
  --name hermes \
  --from localhost/nemoclaw-hermes-configured:latest \
  --provider openrouter \
  --provider discord \
  --policy policy.yaml \
  --no-tty \
  -- hermes gateway run --force
```

Unlike OpenClaw, Hermes can skip the `nemoclaw-start` entrypoint and run `hermes gateway run --force` directly. Python handles the transparent proxy correctly without preload scripts. The tradeoff is losing NemoClaw's privilege separation and config integrity checks, but for a personal Discord bot, the OpenShell sandbox provides more than enough isolation.

## What it looks like running

After about 30 seconds, the bot comes online on Discord. You can verify from the proxy logs:

```bash
openshell logs <sandbox-name>
```

```
NET:OPEN  [INFO] ALLOWED /usr/local/bin/node(428) -> discord.com:443 [policy:discord_api engine:opa]
HTTP:GET  [INFO] ALLOWED GET http://discord.com:443/api/v10/users/@me [policy:discord_api engine:l7]
NET:UPGRADE [INFO] gateway-us-east1-c.discord.gg:443
NET:OTHER [INFO] ALLOWED gateway-us-east1-c.discord.gg:443 [policy:discord_gateway engine:l7-websocket]
HTTP:POST [INFO] ALLOWED POST http://openrouter.ai:443/api/v1/chat/completions [policy:openrouter engine:l7]
HTTP:POST [INFO] ALLOWED POST http://discord.com:443/api/v10/channels/.../messages [policy:discord_api engine:l7]
```

Every connection is logged with the policy rule that allowed it, the engine that evaluated it (OPA for L4, l7 for HTTP, l7-websocket for WebSocket), and the binary that initiated it. Anything not in the policy gets a 403 and an OCSF log entry.

## Gotchas

A few things I ran into that aren't obvious:

- **The containerized gateway can't bind-mount its own internal files into sibling containers.** The Podman driver calls the host Podman daemon to create sandbox containers, so any paths the driver references (client TLS certs, JWT tokens) must exist on the host filesystem, not inside the gateway container.
- **`/dev/null` must be in the filesystem policy's `read_write` list.** The NemoClaw startup script redirects to `/dev/null`, and Landlock blocks it by default. Without this, every shell initialization line fails with "Permission denied."
- **OpenRouter models in OpenClaw use the format `openrouter/<author>/<slug>`**, not `openrouter:author/slug`. The colon-separated format causes OpenClaw to treat the model name as a filesystem path and crash with a "Bundled plugin dirName must be a single directory" error.
- **After regenerating TLS certs, you must recreate sandboxes.** Running sandboxes have the old certs mounted and lose connectivity to the gateway. The supervisor can't fetch policy updates, so hot-reload stops working.
- **Wildcard the Discord gateway hostname.** The policy needs `*.discord.gg`, not just `gateway.discord.gg`. Discord uses regional gateways like `gateway-us-east1-c.discord.gg` for reconnections, and the bot goes offline when the proxy denies the regional hostname.
- **Hermes needs `api_key` fields removed from config, not set to empty.** The NemoClaw base bakes in a static proxy placeholder. Empty string makes the OpenAI SDK send an empty Bearer token. Removing the field entirely makes it fall back to the `OPENAI_API_KEY` env var, which OpenShell injects as a resolvable placeholder.
- **One Discord bot token, one consumer.** If you run both agents with the same bot token, only the last one to connect will receive messages. Use a separate bot token per agent if you want both online simultaneously.

## Source

Everything is in my [clankr](https://github.com/shanemcd/clankr) repo under `agents/openclaw/` and `agents/hermes/`. The gateway quadlet and config live in my [dotfiles](https://github.com/shanemcd/dotfiles).
