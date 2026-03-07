# DigitalOcean Migration Guide

This guide moves OpenClaw from Cloudflare Sandbox to a persistent DigitalOcean VM.

## Why This Fixes Your Issue

Cloudflare Sandbox can restart on deploys, secret changes, or platform resets.  
On a VM, your process may restart, but your disk state persists (`/opt/openclaw`), and `systemd` brings the service back automatically.

## 1) Create Droplet

Recommended baseline:
- Ubuntu 24.04 LTS
- 2 vCPU / 4 GB RAM
- 80+ GB disk
- Add SSH key auth (disable password auth later)

Open inbound firewall ports:
- `22/tcp` (SSH)
- `18789/tcp` (OpenClaw gateway) or keep closed and use SSH tunnel/reverse proxy

## 2) Install Docker + Compose

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Re-login once so group permissions apply.

## 3) Copy Repo + Configure Env

```bash
sudo mkdir -p /opt
sudo chown "$USER":"$USER" /opt
cd /opt
git clone <YOUR_FORK_URL> moltworker
cd /opt/moltworker
cp deploy/digitalocean/.env.example deploy/digitalocean/.env
```

Edit `deploy/digitalocean/.env` with at least:
- `OPENCLAW_GATEWAY_TOKEN`
- one provider key (`ANTHROPIC_API_KEY`, `ZAI_API_KEY`, or `OPENAI_API_KEY`)
- optional channel tokens (`TELEGRAM_BOT_TOKEN`, etc.)

For a lower-cost Anthropic setup on a droplet, start with:

```bash
OPENCLAW_HEARTBEAT_EVERY=3h
OPENCLAW_CONTEXT_TOKENS=80000
OPENCLAW_CONTEXT_PRUNING_MODE=cache-ttl
OPENCLAW_CONTEXT_PRUNING_TTL=1h
OPENCLAW_HEARTBEAT_MODEL=zai/glm-4.7
# Keep your main chat model higher quality unless you want all chats cheaper too:
# OPENCLAW_DEFAULT_MODEL=zai/glm-4.7
# OPENCLAW_MAX_CONCURRENT=1
# OPENCLAW_SUBAGENT_MAX_CONCURRENT=1
```

Notes:
- `agents.defaults.contextTokens` is the OpenClaw knob for context budget. If you were planning to run `openclaw config set agents.defaults.maxContextTokens ...`, use `OPENCLAW_CONTEXT_TOKENS` instead.
- Using a cheaper `OPENCLAW_HEARTBEAT_MODEL` is usually a better first move than downgrading the main model for all conversations.
- `zai/glm-4.7` is a documented budget model in OpenClaw. If you use it for heartbeat/sub-agents, set `ZAI_API_KEY` in the same `.env`.
- If you do not need proactive heartbeat behavior, increase `OPENCLAW_HEARTBEAT_EVERY` further or set the equivalent config value to `0m` to disable it.

## 4) Start OpenClaw on VM

```bash
cd /opt/moltworker/deploy/digitalocean
mkdir -p /opt/openclaw/config /opt/openclaw/workspace /opt/openclaw-backups
docker compose --env-file .env up -d --build
docker compose logs -f openclaw
```

Gateway URL:
- `http://<droplet-ip>:18789/?token=<OPENCLAW_GATEWAY_TOKEN>`

## 5) Make It 24/7 (systemd)

```bash
sudo cp /opt/moltworker/deploy/digitalocean/systemd/openclaw-compose.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-compose.service
sudo systemctl status openclaw-compose.service
```

## 6) Enable Frequent Backups

```bash
chmod +x /opt/moltworker/deploy/digitalocean/scripts/backup-openclaw.sh
chmod +x /opt/moltworker/deploy/digitalocean/scripts/restore-openclaw.sh
sudo cp /opt/moltworker/deploy/digitalocean/systemd/openclaw-backup.service /etc/systemd/system/
sudo cp /opt/moltworker/deploy/digitalocean/systemd/openclaw-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-backup.timer
sudo systemctl list-timers | grep openclaw-backup
```

Local backup output:
- `/opt/openclaw-backups/openclaw-<timestamp>.tar.gz`

Optional DigitalOcean Spaces upload:
- Install `aws` CLI and set these env vars in the backup service:
  - `DO_SPACES_REGION` (for example `nyc3`)
  - `DO_SPACES_BUCKET`
  - `DO_SPACES_PREFIX` (optional)
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

## 7) Remote Browser/Desktop Access

If you want full remote desktop and browser login flows:

```bash
sudo apt-get update
sudo apt-get install -y xfce4 xfce4-goodies xrdp firefox
echo xfce4-session > ~/.xsession
sudo systemctl enable --now xrdp
```

Then connect via RDP client to `<droplet-ip>:3389`.

If you do not need full desktop, use SSH tunnel for gateway access:

```bash
ssh -L 18789:127.0.0.1:18789 root@<droplet-ip>
```

Then open:
- `http://127.0.0.1:18789/?token=<OPENCLAW_GATEWAY_TOKEN>`

## 8) Optional Cutover Checklist

1. Stop Cloudflare-triggered client traffic.
2. Confirm VM has valid OpenClaw state under `/opt/openclaw`.
3. Confirm Telegram/other channels respond via VM deployment.
4. Confirm backups exist in `/opt/openclaw-backups`.
5. Point DNS/reverse proxy to VM endpoint.

## Operations Cheatsheet

```bash
# Service health
sudo systemctl status openclaw-compose.service
docker ps

# Logs
cd /opt/moltworker/deploy/digitalocean
docker compose logs -f openclaw

# Restart
cd /opt/moltworker/deploy/digitalocean
docker compose --env-file .env restart openclaw

# Manual backup
/opt/moltworker/deploy/digitalocean/scripts/backup-openclaw.sh
```
