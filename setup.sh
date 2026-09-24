#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ----------------------------
# Agent identity (override via env)
# ----------------------------
DEVICE_NAME="${DEVICE_NAME:-haro}"
HUMAN_NAME="${HUMAN_NAME:-kivlor}"
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
  figlet \
  xz-utils

echo "==> Configuring Git identity"
git config --global user.name "Haro"
git config --global user.email "haro-bot@kivlor.com"

# Optional convenience: make `fd` available as `fd` (Debian ships `fdfind`)
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

# ----------------------------
# Node.js LTS (official nodejs.org distribution; includes npm)
# ----------------------------
# Remove the shell activation line written by older versions of this setup.
if [ -f "$HOME/.bashrc" ]; then
  sed -i '\|^eval "\$(~/.local/bin/mise activate bash)"$|d' "$HOME/.bashrc"
fi

case "$(uname -m)" in
  aarch64|arm64) NODE_ARCH="arm64" ;;
  armv7l) NODE_ARCH="armv7l" ;;
  x86_64) NODE_ARCH="x64" ;;
  *)
    echo "ERROR: Unsupported architecture for the official Node.js binary: $(uname -m)"
    exit 1
    ;;
esac

NODE_VERSION="${NODE_VERSION:-$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')}"
case "$NODE_VERSION" in
  v[0-9]*) ;;
  *)
    echo "ERROR: Could not determine the latest Node.js LTS version."
    exit 1
    ;;
esac

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || [ "$(node --version)" != "$NODE_VERSION" ]; then
  echo "==> Installing Node.js $NODE_VERSION (official LTS distribution)"
  NODE_DIST="node-${NODE_VERSION}-linux-${NODE_ARCH}"
  NODE_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$NODE_TMP_DIR"' EXIT

  curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" -o "$NODE_TMP_DIR/SHASUMS256.txt"
  curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${NODE_DIST}.tar.xz" -o "$NODE_TMP_DIR/${NODE_DIST}.tar.xz"
  (
    cd "$NODE_TMP_DIR"
    grep -F "  ${NODE_DIST}.tar.xz" SHASUMS256.txt | sha256sum --check --
  )
  sudo tar -xJf "$NODE_TMP_DIR/${NODE_DIST}.tar.xz" -C /usr/local --strip-components=1
  hash -r
fi

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: Node.js or npm is not on PATH after installation."
  exit 1
fi

# ----------------------------
# Pi CLI
# ----------------------------
if ! command -v pi >/dev/null 2>&1; then
  echo "==> Installing Pi CLI"
  sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent
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

# The first SSH login after setup stays in Bash so the user can finish setup.
# To repeat this bypass later: touch ~/.pi/first-login-bash
if [ -n "${SSH_CONNECTION:-}" ] && [ -f "$HOME/.pi/first-login-bash" ]; then
  rm -f "$HOME/.pi/first-login-bash"
  export NO_PI=1
fi

# SSH logins drop straight into the pi agent (set NO_PI=1 to skip)
if [ -n "${SSH_CONNECTION:-}" ] && [ -z "${NO_PI:-}" ]; then
  exec pi
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
fetch_file files/AGENTS.md "$AGENT_DIR/AGENTS.md"

# Preserve the identity an agent has completed on a previous setup run.
if [ ! -f "$AGENT_DIR/SOUL.md" ]; then
  fetch_file files/SOUL.md "$AGENT_DIR/SOUL.md"
fi

# Memory extension + empty memory log (append-only JSONL; SOUL.md is written
# by the agent itself on first interaction, guided by AGENTS.md)
fetch_file files/memory.ts "$AGENT_DIR/extensions/memory.ts"
touch "$AGENT_DIR/memories.txt"

# Let the first SSH login after the requested reboot remain in Bash. The
# ~/.bashrc snippet above consumes this marker and then future SSH logins open pi.
touch "$HOME/.pi/first-login-bash"

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1) Reboot: sudo reboot"
echo "  2) The first SSH login after reboot stays in Bash; authenticate Tailscale: sudo tailscale up"
echo "     (To get Bash instead of pi later, run: touch ~/.pi/first-login-bash)"
echo ""
