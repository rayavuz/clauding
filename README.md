# Clauding

A sandboxed Docker environment with **Claude**, **Codex**, and **Gemini** CLIs pre-installed and configured for fully autonomous operation.

One script. Full autonomy. Zero supervision.

## What is this?

Clauding gives you a Docker container where three major AI coding assistants run with all safety prompts and approval flows disabled. Everything happens inside the container, so your host machine stays untouched.

- **Claude** runs with `--dangerously-skip-permissions`
- **Codex** runs with `--dangerously-bypass-approvals-and-sandbox`
- **Gemini** runs with `--yolo`

Need the standard approval flow? Use `claude-normal`, `codex-normal`, or `gemini-normal` instead.

## Features

- **Complete sandbox** - AI agents get root in the container, not on your system
- **Docker-in-Docker** - agents can build images, run containers, and manage deployment pipelines
- **Self-healing wrappers** - a watchdog cron restores bypass mode if a CLI auto-updates
- **Single script setup** - one command on any Linux machine, everything configured automatically
- **No personal data** - the script contains zero credentials, tokens, or API keys

## Quick Start

```bash
# Download and run
bash setup-clauding.sh

# Enter the container
cd clauding && ./enter.sh

# Authenticate (inside the container)
claude    # login with Anthropic account
codex     # login with OpenAI account
gemini    # login with Google account
```

## Requirements

- Linux (native or WSL)
- Docker (the setup script installs it if missing)

## How it works

`setup-clauding.sh` does the following:

1. Installs Docker if not present
2. Creates `clauding/` with all necessary files (Dockerfile, docker-compose, bootstrap script, etc.)
3. Builds the Docker image with Node.js, all three AI CLIs, and Docker-in-Docker support
4. On container start, a bootstrap script creates wrapper scripts that inject the bypass flags
5. A cron job checks every 5 minutes and restores wrappers if they get overwritten by auto-updates

## Project structure

```
clauding/
  Dockerfile              # Multi-stage build: Node.js + AI CLIs + Docker CLI
  docker-compose.yaml     # Container config with volume mounts
  enter.sh                # Quick entry script
  control/bootstrap.sh    # Container startup: git init, wrappers, cron
  workspace/              # Your working directory (bind-mounted)
```

## Author

**Ramazan Yavuz**

## License

MIT
