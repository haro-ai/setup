#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

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
  fd-find

echo "==> Configuring Git identity"
git config --global user.name "Haro"
git config --global user.email "haro-bot@kivlor.com"

# Optional convenience: make `fd` available as `fd` (Debian ships `fdfind`)
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

# ----------------------------
# Docker (official repo)
# ----------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"

  sudo install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  fi

  sudo apt-get update -y
  sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  sudo systemctl enable --now docker
fi

# Allow current user to run docker without sudo (takes effect after re-login)
sudo usermod -aG docker "$USER" || true

# ----------------------------
# mise
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

if ! command -v codex >/dev/null 2>&1; then
  echo "==> Installing Codex CLI"
  npm install -g @openai/codex
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

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1) Reboot: sudo reboot"
echo "  2) After reboot, authenticate Tailscale: sudo tailscale up"
echo "  3) Log out/in (or reboot) for docker group to apply (so you can run docker without sudo)."
echo ""
