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

### Agent setup

Authenticate Pi:

```sh
pi
# then run: /login
```
