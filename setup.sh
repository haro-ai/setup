#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ----------------------------
# Agent identity (override via env)
# ----------------------------
DEVICE_NAME="${DEVICE_NAME:-Haro}"
HUMAN_NAME="${HUMAN_NAME:-Kivlor}"
AGENT_USER="$(id -un)"

# ----------------------------
# System updates & core
# ----------------------------
echo "==> Updating system"
sudo apt-get update -y
sudo apt-get upgrade -y

echo "==> Installing core packages"
sudo apt-get install -y \
  git \
  gh \
  jq \
  curl \
  wget \
  unzip \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release \
  apt-transport-https \
  openssh-server \
  htop \
  tmux \
  ncdu \
  tree \
  bind9-dnsutils \
  net-tools \
  ripgrep \
  fd-find \
  figlet

echo "==> Configuring Git identity"
git config --global user.name "Haro"
git config --global user.email "haro-bot@kivlor.com"

# Optional convenience: make `fd` available as `fd` (Debian ships `fdfind`)
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

# ----------------------------
# Mise
# ----------------------------
if [ ! -x "$HOME/.local/bin/mise" ]; then
  echo "==> Installing mise"
  curl -fsSL https://mise.run | sh
fi

if ! grep -q 'mise activate bash' "$HOME/.bashrc" 2>/dev/null; then
  echo 'eval "$(~/.local/bin/mise activate bash)"' >> "$HOME/.bashrc"
fi

export PATH="$HOME/.local/bin:$PATH"
# Shell activation for this run (ok if it prints nothing)
eval "$(mise activate bash 2>/dev/null || true)"

# ----------------------------
# JS tooling (via mise)
# ----------------------------
echo "==> Installing JS tooling via mise"
mise use -g node@lts npm@latest pnpm@latest bun@latest deno@latest

# Make sure this shell sees mise shims/paths
eval "$(mise activate bash 2>/dev/null || true)"
hash -r

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is not on PATH. Try re-login or run: eval \"\$(mise activate bash)\""
  exit 1
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "ERROR: pnpm is not on PATH. Try re-login or run: eval \"\$(mise activate bash)\""
  exit 1
fi

# ----------------------------
# Pi CLI
# ----------------------------
if ! command -v pi >/dev/null 2>&1; then
  echo "==> Installing Pi CLI"
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
fi

# ----------------------------
# Tailscale
# ----------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  echo "==> Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

sudo systemctl enable --now tailscaled

# ----------------------------
# SSH
# ----------------------------
sudo systemctl enable --now ssh

# ----------------------------
# Passwordless sudo
# ----------------------------
if [ ! -f "/etc/sudoers.d/010_${AGENT_USER}-nopasswd" ]; then
  echo "==> Configuring passwordless sudo"
  echo "${AGENT_USER} ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/010_${AGENT_USER}-nopasswd" >/dev/null
  sudo chmod 440 "/etc/sudoers.d/010_${AGENT_USER}-nopasswd"
fi

# ----------------------------
# MOTD banner (figlet, small font)
# ----------------------------
motd_banner=$(figlet -f small "$DEVICE_NAME" 2>/dev/null || figlet "$DEVICE_NAME")
current_motd="$(cat /etc/motd 2>/dev/null || true)"
if [ "$current_motd" != "$motd_banner" ]; then
  echo "==> Installing MOTD banner"
  printf '%s\n' "$motd_banner" | sudo tee /etc/motd >/dev/null
fi

# ----------------------------
# Shell: start in ~/core, SSH logins drop into pi agent
# ----------------------------
if ! grep -q 'Start interactive shells in' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

# Start interactive shells in the core directory
[ -d "$HOME/core" ] && cd "$HOME/core"

# SSH logins drop straight into the pi agent (set NO_PI=1 to skip)
if [ -n "${SSH_CONNECTION:-}" ] && [ -z "${NO_PI:-}" ]; then
  exec ~/.local/share/mise/installs/node/lts/bin/pi
fi
EOF
fi

# ----------------------------
# Pi agent config (~/.pi/agent)
# ----------------------------
echo "==> Bootstrapping pi agent config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
REPO_RAW="https://raw.githubusercontent.com/haro-ai/setup/refs/heads/main"

fetch_file() {
  # usage: fetch_file <repo-relative-path> <dest>
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$1" ]; then
    cp -f "$SCRIPT_DIR/$1" "$2"
  else
    echo "==> Fetching $1 from GitHub"
    mkdir -p "$(dirname "$2")"
    curl -fsSL "$REPO_RAW/$1" -o "$2"
  fi
}

AGENT_DIR="$HOME/.pi/agent"
mkdir -p "$AGENT_DIR/extensions"
tmp_agents="$(mktemp)"
fetch_file files/AGENTS.md "$tmp_agents"

# AGENTS.md — templated with device/human names
sed -e "s/{{DEVICE_NAME}}/$DEVICE_NAME/g" \
    -e "s/{{HUMAN_NAME}}/$HUMAN_NAME/g" \
    -e "s/{{AGENT_USER}}/$AGENT_USER/g" \
    "$tmp_agents" > "$AGENT_DIR/AGENTS.md"
rm -f "$tmp_agents"

# Memory extension + empty memory log (append-only JSONL; SOUL.md is written
# by the agent itself on first interaction, guided by AGENTS.md)
fetch_file files/memory.ts "$AGENT_DIR/extensions/memory.ts"
touch "$AGENT_DIR/memories.txt"

# ----------------------------
# Telegram bridge (optional)
# Installs tgbridge.ts + systemd unit. Only enables the service if
# ~/.pi/agent/tg.json exists (token + allowed chat ids).
# ----------------------------
if [ ! -f "$HOME/.pi/agent/tools/tgbridge.ts" ]; then
  echo "==> Installing telegram bridge"
  mkdir -p "$HOME/.pi/agent/tools"
  fetch_file files/tgbridge.ts "$HOME/.pi/agent/tools/tgbridge.ts"
  BRIDGE_RUNTIME="$(command -v bun || true)"
  if [ -z "$BRIDGE_RUNTIME" ]; then
    mise use -g bun@latest >/dev/null 2>&1 || true
    eval "$(mise activate bash 2>/dev/null || true)"; hash -r
    BRIDGE_RUNTIME="$(command -v bun || command -v node)"
  fi

  sudo tee /etc/systemd/system/tgbridge.service >/dev/null <<EOF2
[Unit]
Description=Telegram <-> pi agent bridge (tgbridge.ts)
After=network-online.target
Wants=network-online.target

[Service]
User=${AGENT_USER}
ExecStart=${BRIDGE_RUNTIME} ${HOME}/.pi/agent/tools/tgbridge.ts
Restart=always
RestartSec=15
WorkingDirectory=${HOME}/.pi/agent

[Install]
WantedBy=multi-user.target
EOF2
  sudo systemctl daemon-reload
  if [ -f "$HOME/.pi/agent/tg.json" ]; then
    sudo systemctl enable --now tgbridge
  else
    echo "    tg.json not found — unit installed but not enabled."
    echo "    Add ~/.pi/agent/tg.json: {\"token\": \"...\", \"allowed\": [<chat id>]}"
    echo "    then: sudo systemctl enable --now tgbridge"
  fi
fi

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1) Set a real password: passwd"
echo "  2) Reboot: sudo reboot"
echo "  3) After reboot, authenticate Tailscale: sudo tailscale up"
echo "  4) Authenticate pi: run 'pi', then /login"
echo "     On first interaction, pi will generate its identity file (SOUL.md)."
echo ""
