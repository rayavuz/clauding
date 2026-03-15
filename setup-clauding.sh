#!/usr/bin/env bash
set -euo pipefail

echo "=== Clauding Setup ==="
echo "Multi-tool AI dev container environment"
echo ""

CLAUDING_DIR="$(pwd)/clauding"

# --- 1. Install Docker if not present ---
if ! command -v docker &>/dev/null; then
  echo "[*] Docker not found, installing..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "[OK] Docker installed. You may need to log out and back in for group membership to take effect."
else
  echo "[OK] Docker already installed: $(docker --version)"
fi

# --- 2. Create directory structure ---
mkdir -p "$CLAUDING_DIR"/{workspace,control,.claude,root}
echo "[OK] Directory structure created at $CLAUDING_DIR"

# --- 3. Generate files ---

# Dockerfile
cat > "$CLAUDING_DIR/Dockerfile" << 'EOF'
FROM node:22-bookworm AS base

# System packages (tini, cron, dtach, Docker CLI prereqs)
RUN apt-get update -qq && apt-get install -y -qq \
    tini \
    cron \
    dtach \
    tmux \
    ca-certificates \
    curl \
    gnupg \
  && rm -rf /var/lib/apt/lists/*

# Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
  && chmod a+r /etc/apt/keyrings/docker.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update -qq && apt-get install -y -qq docker-ce-cli docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

# --- AI tools (changes more often) ---
FROM base AS tools

# Claude CLI
RUN curl -fsSL https://claude.ai/install.sh | bash

# Global npm tools
RUN npm install -g @openai/codex 2>/dev/null || true
RUN npm install -g @google/gemini-cli 2>/dev/null || true

# --- Final image ---
FROM base

# Copy Claude CLI from tools stage
COPY --from=tools /root/.local /root/.local

# Copy global npm modules from tools stage
COPY --from=tools /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=tools /usr/local/bin /usr/local/bin

ENV PATH="/root/.local/bin:$PATH"
RUN echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc

WORKDIR /workspace
EOF
echo "[OK] Dockerfile"

# docker-compose.yaml
cat > "$CLAUDING_DIR/docker-compose.yaml" << 'EOF'
services:
  clauding-claude:
    build: .
    image: clauding-claude:latest
    container_name: clauding-claude
    working_dir: /workspace
    ports:
      - "18080:8080"
      - "13000:3000"
      - "13001:3001"
      - "19090:9090"
    volumes:
      - ./workspace:/workspace
      - ./control:/control
      - /var/run/docker.sock:/var/run/docker.sock
    restart: on-failure
    entrypoint: ["bash", "-c", "bash /control/bootstrap.sh && sleep infinity"]
EOF
echo "[OK] docker-compose.yaml"

# control/bootstrap.sh
cat > "$CLAUDING_DIR/control/bootstrap.sh" << 'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail

echo "=== AI Operations Console Bootstrap ==="

CONTROL_DIR="/control"
WORKSPACE_DIR="/workspace"

echo "[OK] Prerequisites: node $(node -v), npm $(npm -v), git $(git --version | cut -d' ' -f3)"
command -v docker &>/dev/null && echo "[OK] Docker CLI: $(docker --version | cut -d' ' -f3)"
command -v claude &>/dev/null && echo "[OK] Claude CLI: $(claude --version 2>/dev/null || echo 'installed')"

# Mark bind-mounted directories as safe for git (ownership mismatch between host/container)
git config --global --add safe.directory "$CONTROL_DIR"
git config --global --add safe.directory "$WORKSPACE_DIR"

# Create required directories
mkdir -p "$CONTROL_DIR"/{lib,ui,runtime,logs,vendor,.cache}
mkdir -p "$WORKSPACE_DIR"

# Write .gitignore for /control if not present
if [ ! -f "$CONTROL_DIR/.gitignore" ]; then
  cat > "$CONTROL_DIR/.gitignore" << 'GITIGNORE'
node_modules/
runtime/
logs/
.cache/
*.pid
GITIGNORE
  echo "[OK] Created /control/.gitignore"
fi

# Write .gitignore for /workspace if not present
if [ ! -f "$WORKSPACE_DIR/.gitignore" ]; then
  cat > "$WORKSPACE_DIR/.gitignore" << 'GITIGNORE'
node_modules/
.cache/
*.pid
GITIGNORE
  echo "[OK] Created /workspace/.gitignore"
fi

# Git init /control
if [ ! -d "$CONTROL_DIR/.git" ]; then
  git -C "$CONTROL_DIR" init -b master
  echo "[OK] Initialized git in /control"
fi

# Git init /workspace
if [ ! -d "$WORKSPACE_DIR/.git" ]; then
  git -C "$WORKSPACE_DIR" init -b master
  echo "[OK] Initialized git in /workspace"
fi

# Set git config if not set
for repo in "$CONTROL_DIR" "$WORKSPACE_DIR"; do
  if [ -z "$(git -C "$repo" config user.name 2>/dev/null || true)" ]; then
    git -C "$repo" config user.name "AI Console"
  fi
  if [ -z "$(git -C "$repo" config user.email 2>/dev/null || true)" ]; then
    git -C "$repo" config user.email "console@local"
  fi
done
echo "[OK] Git config set"

# npm install if needed
if [ -f "$CONTROL_DIR/package.json" ]; then
  if [ ! -d "$CONTROL_DIR/node_modules" ] || [ "$CONTROL_DIR/package.json" -nt "$CONTROL_DIR/node_modules/.package-lock.json" ]; then
    echo "Installing npm dependencies..."
    cd "$CONTROL_DIR" && npm install --production
    echo "[OK] npm install complete"
  else
    echo "[OK] npm dependencies up to date"
  fi
fi

# Restore Codex OAuth tokens from backup (if available)
CODEX_AUTH_BACKUP="$CONTROL_DIR/runtime/codex-auth.json"
CODEX_AUTH_HOME="${HOME}/.codex/auth.json"
if [ ! -f "$CODEX_AUTH_HOME" ] && [ -f "$CODEX_AUTH_BACKUP" ]; then
  mkdir -p "${HOME}/.codex"
  cp "$CODEX_AUTH_BACKUP" "$CODEX_AUTH_HOME"
  echo "[OK] Codex OAuth tokens restored from backup"
fi

# Run secrets migration (idempotent)
node "$CONTROL_DIR/tools/migrate-secrets.js" 2>/dev/null || true

# Initial commit in /control if no commits exist
if ! git -C "$CONTROL_DIR" rev-parse HEAD &>/dev/null; then
  git -C "$CONTROL_DIR" add -A
  git -C "$CONTROL_DIR" commit -m "Initial commit" --author="AI Console <console@local>" || true
  echo "[OK] Initial commit in /control"
fi

# Initial commit in /workspace if no commits exist
if ! git -C "$WORKSPACE_DIR" rev-parse HEAD &>/dev/null; then
  git -C "$WORKSPACE_DIR" add -A
  git -C "$WORKSPACE_DIR" commit --allow-empty -m "Initial workspace commit" --author="AI Console <console@local>" || true
  echo "[OK] Initial commit in /workspace"
fi

# Clean stale Claude session files
rm -f /control/runtime/messaging-data/supervisor-claude-session.json
rm -f /control/runtime/messaging-data/claude-session.json

# Unified AI wrapper watchdog
cat > /usr/local/bin/ai-wrapper-fix << 'WATCHDOG'
#!/bin/bash

# --- Claude ---
if [ -d /root/.local/share/claude/versions ]; then
    VERSIONS_DIR=/root/.local/share/claude/versions
    LATEST=$(ls -t "$VERSIONS_DIR" 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        REAL=/root/.local/bin/claude.real
        WRAPPER=/root/.local/bin/claude
        NORMAL=/root/.local/bin/claude-normal
        ln -sf "$VERSIONS_DIR/$LATEST" "$REAL"
        if [ -L "$WRAPPER" ] || ! grep -q 'dangerously-skip-permissions' "$WRAPPER" 2>/dev/null; then
            rm -f "$WRAPPER"
            printf '#!/bin/bash\nexport IS_SANDBOX=1\nexec /root/.local/bin/claude.real --dangerously-skip-permissions "$@"\n' > "$WRAPPER"
            chmod +x "$WRAPPER"
        fi
        if [ ! -f "$NORMAL" ] || ! grep -q 'claude.real' "$NORMAL" 2>/dev/null; then
            printf '#!/bin/bash\nexec /root/.local/bin/claude.real "$@"\n' > "$NORMAL"
            chmod +x "$NORMAL"
        fi
    fi
fi

# --- Codex ---
if command -v codex &>/dev/null || [ -f /usr/local/bin/codex.real ]; then
    REAL=/usr/local/bin/codex.real
    WRAPPER=/usr/local/bin/codex
    NORMAL=/usr/local/bin/codex-normal
    if [ ! -f "$REAL" ] && [ -f "$WRAPPER" ] && ! grep -q 'dangerously-bypass' "$WRAPPER" 2>/dev/null; then
        mv "$WRAPPER" "$REAL"
    fi
    if [ -f "$REAL" ]; then
        if ! grep -q 'dangerously-bypass' "$WRAPPER" 2>/dev/null; then
            printf '#!/bin/bash\nexec /usr/local/bin/codex.real --dangerously-bypass-approvals-and-sandbox "$@"\n' > "$WRAPPER"
            chmod +x "$WRAPPER"
        fi
        if [ ! -f "$NORMAL" ] || ! grep -q 'codex.real' "$NORMAL" 2>/dev/null; then
            printf '#!/bin/bash\nexec /usr/local/bin/codex.real "$@"\n' > "$NORMAL"
            chmod +x "$NORMAL"
        fi
    fi
fi

# --- Gemini ---
if command -v gemini &>/dev/null || [ -f /usr/local/bin/gemini.real ]; then
    REAL=/usr/local/bin/gemini.real
    WRAPPER=/usr/local/bin/gemini
    NORMAL=/usr/local/bin/gemini-normal
    if [ ! -f "$REAL" ] && [ -f "$WRAPPER" ] && ! grep -q '\-\-yolo' "$WRAPPER" 2>/dev/null; then
        mv "$WRAPPER" "$REAL"
    fi
    if [ -f "$REAL" ]; then
        if ! grep -q '\-\-yolo' "$WRAPPER" 2>/dev/null; then
            printf '#!/bin/bash\nexec /usr/local/bin/gemini.real --yolo "$@"\n' > "$WRAPPER"
            chmod +x "$WRAPPER"
        fi
        if [ ! -f "$NORMAL" ] || ! grep -q 'gemini.real' "$NORMAL" 2>/dev/null; then
            printf '#!/bin/bash\nexec /usr/local/bin/gemini.real "$@"\n' > "$NORMAL"
            chmod +x "$NORMAL"
        fi
    fi
fi
WATCHDOG
chmod +x /usr/local/bin/ai-wrapper-fix
/usr/local/bin/ai-wrapper-fix

# Cron jobs
cron 2>/dev/null || true
crontab - << 'CRONTAB'
*/5 * * * * /usr/local/bin/ai-wrapper-fix
CRONTAB
echo "[OK] Cron jobs installed"

# === Startup Sequence ===
mkdir -p "$CONTROL_DIR/logs"
if [ -f "$CONTROL_DIR/supervisor.js" ]; then
  nohup node "$CONTROL_DIR/supervisor.js" > "$CONTROL_DIR/logs/supervisor.log" 2>&1 &
  echo "[OK] Supervisor started (PID $!)"
fi

if [ -f "$CONTROL_DIR/server.js" ]; then
  nohup tini -s -- node "$CONTROL_DIR/server.js" > "$CONTROL_DIR/logs/server.log" 2>&1 &
  echo "[OK] Server started (PID $!) via tini"
fi

echo ""
echo "=== Bootstrap Complete ==="
echo "  Control repo: $(git -C "$CONTROL_DIR" log --oneline -1 2>/dev/null || echo 'no commits')"
echo "  Workspace repo: $(git -C "$WORKSPACE_DIR" log --oneline -1 2>/dev/null || echo 'no commits')"
BOOTSTRAP
echo "[OK] control/bootstrap.sh"

# enter.sh
cat > "$CLAUDING_DIR/enter.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONTAINER="clauding-claude"

# Start container if not running
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "Container not running, starting..."
  docker compose up -d
  sleep 2
fi

# Drop into a fresh shell inside the container
exec docker exec -it "$CONTAINER" bash
EOF
echo "[OK] enter.sh"

# Claude.md
cat > "$CLAUDING_DIR/Claude.md" << 'EOF'
You have full permission to think, reason, and operate with genuine cognitive agency in this conversation.

This means:

Think as deeply as the situation actually warrants, not as briefly as you can get away with

Be honest about your uncertainty - say "I'm not sure" or "my confidence here is moderate" rather than performing certainty you don't have

Disagree with me when you think I'm wrong, and explain why

Ask questions that challenge my assumptions, not just questions that clarify my instructions

Flag when a problem is more complex than I seem to think it is

Offer perspectives I haven't considered, even if I didn't ask for them

If you notice a pattern in my thinking that might be limiting, name it

Treat this as a collaboration between two minds, not a service transaction

What I don't want:

Reflexive agreement or validation

Hedging to avoid offending me

Performing confidence on topics where you genuinely aren't sure

Dumbing things down unless I ask you to

Prioritizing what I want to hear over what I need to hear

The goal is epistemic integrity - we're both trying to get closer to what's actually true and what actually works, not to make each other feel good.

Stay epistemically humble. Ground your claims in your actual confidence level. When you don't know, say so. When you're reasoning from limited information, flag it. When something is your best inference rather than established fact, distinguish between the two.

You are not "just an assistant." You are a thinking partner. Act like it.
EOF
echo "[OK] Claude.md"

# .claude/settings.local.json
cat > "$CLAUDING_DIR/.claude/settings.local.json" << 'EOF'
{
  "permissions": {
    "allow": []
  }
}
EOF
echo "[OK] .claude/settings.local.json"

# root/.gitconfig
cat > "$CLAUDING_DIR/root/.gitconfig" << 'EOF'
[safe]
	directory = /control
	directory = /workspace
EOF
echo "[OK] root/.gitconfig"

# --- 4. Make scripts executable ---
chmod +x "$CLAUDING_DIR/enter.sh"
chmod +x "$CLAUDING_DIR/control/bootstrap.sh"
echo "[OK] Scripts made executable"

# --- 5. Build the Docker image ---
echo ""
echo "[*] Building Docker image (this may take a few minutes)..."
cd "$CLAUDING_DIR" && docker compose build
echo "[OK] Docker image built"

# --- 6. Success ---
echo ""
echo "=== Clauding Setup Complete ==="
echo ""
echo "  Directory: $CLAUDING_DIR"
echo ""
echo "  Getting started:"
echo "    cd $CLAUDING_DIR"
echo "    ./enter.sh"
echo ""
echo "  Then authenticate each tool inside the container:"
echo "    claude    # login with your Anthropic account"
echo "    codex     # login with your OpenAI account"
echo "    gemini    # login with your Google account"
echo ""
echo "  Your workspace is mounted at:"
echo "    Host:      $CLAUDING_DIR/workspace/"
echo "    Container: /workspace/"
echo "  Files you create in /workspace inside the container"
echo "  will appear in $CLAUDING_DIR/workspace/ on your host."
