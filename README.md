### Installation

```sh
curl -fsSL https://raw.githubusercontent.com/haro-ai/setup/refs/heads/main/setup.sh | bash
```

### Setup

1. Generate an SSH key (ed25519)
```sh
ssh-keygen -t ed25519 -C "haro-bot@kivlor.com"
# Press Enter to accept default path (~/.ssh/id_ed25519)
# Optionally set a passphrase
```

2. Start ssh-agent and add the key
```sh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

3. Add the public key to GitHub
```sh
gh auth login --git-protocol ssh
```

4. Authenticate codex
```sh
codex login --device-auth
```
