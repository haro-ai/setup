### Installation

```sh
curl -fsSL https://raw.githubusercontent.com/haro-ai/setup/refs/heads/main/setup.sh | bash
```

### First login after installation

After the requested reboot, the first SSH login intentionally remains in Bash rather than opening `pi`. Use it to finish host setup, including Tailscale authentication. Later SSH logins open `pi` by default.

To get a Bash login again for a future SSH connection, run:

```sh
touch ~/.pi/first-login-bash
```

For a one-off Bash login without creating the marker, run the environment variable on the remote host:

```sh
ssh -t pi@host 'NO_PI=1 bash --login'
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

4. Authenticate pi
```sh
pi
# then run: /login
```
