#!/usr/bin/env bash
# Startup script for self-hosted VM deployments (DigitalOcean, etc.)
#
# This script:
# 1) Ensures persistent paths exist
# 2) Seeds default skills on first boot
# 3) Runs non-interactive onboarding if config does not exist
# 4) Patches channel/gateway config from env vars
# 5) Starts the OpenClaw gateway

set -euo pipefail

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/root/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/root/clawd}"
SKILLS_DIR="${WORKSPACE_DIR}/skills"
DEFAULT_SKILLS_DIR="/opt/default-skills"
CONFIG_FILE="${CONFIG_DIR}/openclaw.json"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_BIND="${OPENCLAW_BIND:-0.0.0.0}"

echo "Config directory: ${CONFIG_DIR}"
echo "Workspace directory: ${WORKSPACE_DIR}"

# Kimi (Moonshot) compatibility aliases.
# If KIMI_* is set, map to OPENAI-compatible env vars used below.
if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${KIMI_API_KEY:-}" ]; then
  export OPENAI_API_KEY="${KIMI_API_KEY}"
fi
if [ -z "${OPENAI_BASE_URL:-}" ] && [ -n "${KIMI_BASE_URL:-}" ]; then
  export OPENAI_BASE_URL="${KIMI_BASE_URL}"
fi
if [ -z "${OPENAI_MODEL:-}" ] && [ -n "${KIMI_MODEL:-}" ]; then
  export OPENAI_MODEL="${KIMI_MODEL}"
fi

mkdir -p "${CONFIG_DIR}" "${WORKSPACE_DIR}" "${SKILLS_DIR}"

if [ -d "${DEFAULT_SKILLS_DIR}" ] && [ -z "$(ls -A "${SKILLS_DIR}" 2>/dev/null)" ]; then
  echo "Seeding default skills..."
  cp -a "${DEFAULT_SKILLS_DIR}/." "${SKILLS_DIR}/"
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "No existing config found, running openclaw onboard..."

  AUTH_ARGS=()
  if [ -n "${CLOUDFLARE_AI_GATEWAY_API_KEY:-}" ] \
    && [ -n "${CF_AI_GATEWAY_ACCOUNT_ID:-}" ] \
    && [ -n "${CF_AI_GATEWAY_GATEWAY_ID:-}" ]; then
    AUTH_ARGS=(
      --auth-choice cloudflare-ai-gateway-api-key
      --cloudflare-ai-gateway-account-id "${CF_AI_GATEWAY_ACCOUNT_ID}"
      --cloudflare-ai-gateway-gateway-id "${CF_AI_GATEWAY_GATEWAY_ID}"
      --cloudflare-ai-gateway-api-key "${CLOUDFLARE_AI_GATEWAY_API_KEY}"
    )
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    AUTH_ARGS=(--auth-choice apiKey --anthropic-api-key "${ANTHROPIC_API_KEY}")
  elif [ -n "${ZAI_API_KEY:-}" ]; then
    AUTH_ARGS=(--auth-choice zai-api-key --zai-api-key "${ZAI_API_KEY}")
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    AUTH_ARGS=(--auth-choice openai-api-key --openai-api-key "${OPENAI_API_KEY}")
  fi

  openclaw onboard --non-interactive --accept-risk \
    --mode local \
    "${AUTH_ARGS[@]}" \
    --gateway-port "${GATEWAY_PORT}" \
    --gateway-bind lan \
    --skip-channels \
    --skip-skills \
    --skip-health

  echo "Onboard completed"
else
  echo "Using existing config"
fi

node << 'EOFPATCH'
const fs = require('fs');

const configPath = process.env.OPENCLAW_CONFIG_DIR
  ? `${process.env.OPENCLAW_CONFIG_DIR}/openclaw.json`
  : '/root/.openclaw/openclaw.json';
const gatewayPort = Number(process.env.OPENCLAW_GATEWAY_PORT || '18789');

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch {
  console.log('No valid config found, starting with defaults');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

function ensureAgentDefaults() {
  config.agents = config.agents || {};
  config.agents.defaults = config.agents.defaults || {};
  return config.agents.defaults;
}

function ensurePrimaryModelConfig(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value;
  }
  if (typeof value === 'string' && value) {
    return { primary: value };
  }
  return {};
}

function parsePositiveInt(value, envName) {
  if (!value) return undefined;
  const parsed = Number(value);
  if (Number.isInteger(parsed) && parsed > 0) {
    return parsed;
  }
  console.log(`Ignoring invalid ${envName}: expected a positive integer, got "${value}"`);
  return undefined;
}

config.gateway.port = gatewayPort;
config.gateway.mode = 'local';

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
  config.gateway.auth = config.gateway.auth || {};
  config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
  config.gateway.controlUi = config.gateway.controlUi || {};
  config.gateway.controlUi.allowInsecureAuth = true;
}

if (process.env.CF_AI_GATEWAY_MODEL) {
  const raw = process.env.CF_AI_GATEWAY_MODEL;
  const slashIdx = raw.indexOf('/');
  if (slashIdx > 0) {
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);
    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;
    let baseUrl;

    if (accountId && gatewayId) {
      baseUrl = `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}/${gwProvider}`;
      if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
      baseUrl = `https://api.cloudflare.com/client/v4/accounts/${process.env.CF_ACCOUNT_ID}/ai/v1`;
    }

    if (baseUrl && apiKey) {
      const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
      const providerName = `cf-ai-gw-${gwProvider}`;

      config.models = config.models || {};
      config.models.providers = config.models.providers || {};
      config.models.providers[providerName] = {
        baseUrl,
        apiKey,
        api,
        models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
      };
      const defaults = ensureAgentDefaults();
      const model = ensurePrimaryModelConfig(defaults.model);
      model.primary = `${providerName}/${modelId}`;
      defaults.model = model;
    }
  }
}

if (process.env.OPENAI_API_KEY && process.env.OPENAI_BASE_URL && process.env.OPENAI_MODEL) {
  const providerName = 'openai-compatible';

  config.models = config.models || {};
  config.models.providers = config.models.providers || {};
  config.models.providers[providerName] = {
    baseUrl: process.env.OPENAI_BASE_URL,
    apiKey: process.env.OPENAI_API_KEY,
    api: 'openai-completions',
    models: [{ id: process.env.OPENAI_MODEL, name: process.env.OPENAI_MODEL, contextWindow: 131072, maxTokens: 8192 }],
  };
  const defaults = ensureAgentDefaults();
  const model = ensurePrimaryModelConfig(defaults.model);
  model.primary = `${providerName}/${process.env.OPENAI_MODEL}`;
  defaults.model = model;
}

// Cost-tuning overrides for VM deployments. These are applied on every boot so
// a simple .env change + container restart is enough to persist the policy.
const defaultModelOverride = process.env.OPENCLAW_DEFAULT_MODEL;
const heartbeatEveryOverride = process.env.OPENCLAW_HEARTBEAT_EVERY;
const heartbeatModelOverride = process.env.OPENCLAW_HEARTBEAT_MODEL;
const contextTokensOverride = parsePositiveInt(
  process.env.OPENCLAW_CONTEXT_TOKENS,
  'OPENCLAW_CONTEXT_TOKENS',
);
const maxConcurrentOverride = parsePositiveInt(
  process.env.OPENCLAW_MAX_CONCURRENT,
  'OPENCLAW_MAX_CONCURRENT',
);
const subagentMaxConcurrentOverride = parsePositiveInt(
  process.env.OPENCLAW_SUBAGENT_MAX_CONCURRENT,
  'OPENCLAW_SUBAGENT_MAX_CONCURRENT',
);
const contextPruningModeOverride = process.env.OPENCLAW_CONTEXT_PRUNING_MODE;
const contextPruningTtlOverride = process.env.OPENCLAW_CONTEXT_PRUNING_TTL;
const subagentModelOverride = process.env.OPENCLAW_SUBAGENT_MODEL;

if (
  defaultModelOverride ||
  heartbeatEveryOverride ||
  heartbeatModelOverride ||
  contextTokensOverride !== undefined ||
  maxConcurrentOverride !== undefined ||
  subagentMaxConcurrentOverride !== undefined ||
  contextPruningModeOverride ||
  contextPruningTtlOverride ||
  subagentModelOverride
) {
  const defaults = ensureAgentDefaults();

  if (defaultModelOverride) {
    const model = ensurePrimaryModelConfig(defaults.model);
    model.primary = defaultModelOverride;
    defaults.model = model;
  }

  if (heartbeatEveryOverride || heartbeatModelOverride) {
    defaults.heartbeat = defaults.heartbeat || {};
    if (heartbeatEveryOverride) {
      defaults.heartbeat.every = heartbeatEveryOverride;
    }
    if (heartbeatModelOverride) {
      defaults.heartbeat.model = heartbeatModelOverride;
    }
  }

  if (contextTokensOverride !== undefined) {
    defaults.contextTokens = contextTokensOverride;
  }

  if (maxConcurrentOverride !== undefined) {
    defaults.maxConcurrent = maxConcurrentOverride;
  }

  if (contextPruningModeOverride || contextPruningTtlOverride) {
    defaults.contextPruning = defaults.contextPruning || {};
    if (contextPruningModeOverride) {
      defaults.contextPruning.mode = contextPruningModeOverride;
    }
    if (contextPruningTtlOverride) {
      defaults.contextPruning.ttl = contextPruningTtlOverride;
    }
  }

  if (subagentModelOverride || subagentMaxConcurrentOverride !== undefined) {
    defaults.subagents = defaults.subagents || {};
    if (subagentModelOverride) {
      defaults.subagents.model = subagentModelOverride;
    }
    if (subagentMaxConcurrentOverride !== undefined) {
      defaults.subagents.maxConcurrent = subagentMaxConcurrentOverride;
    }
  }
}

if (process.env.TELEGRAM_BOT_TOKEN) {
  const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
  config.channels.telegram = {
    botToken: process.env.TELEGRAM_BOT_TOKEN,
    enabled: true,
    dmPolicy,
  };
  if (process.env.TELEGRAM_DM_ALLOW_FROM) {
    config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',')
      .map((v) => v.trim())
      .filter(Boolean);
  } else if (dmPolicy === 'open') {
    config.channels.telegram.allowFrom = ['*'];
  }
}

if (process.env.DISCORD_BOT_TOKEN) {
  const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
  const dm = { policy: dmPolicy };
  if (dmPolicy === 'open') {
    dm.allowFrom = ['*'];
  }
  config.channels.discord = {
    token: process.env.DISCORD_BOT_TOKEN,
    enabled: true,
    dm,
  };
}

if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
  config.channels.slack = {
    botToken: process.env.SLACK_BOT_TOKEN,
    appToken: process.env.SLACK_APP_TOKEN,
    enabled: true,
  };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

echo "Starting OpenClaw gateway on port ${GATEWAY_PORT}..."
CMD=(openclaw gateway --port "${GATEWAY_PORT}" --allow-unconfigured --bind "${GATEWAY_BIND}")
if [ "${OPENCLAW_VERBOSE:-false}" = "true" ]; then
  CMD+=(--verbose)
fi
if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  CMD+=(--token "${OPENCLAW_GATEWAY_TOKEN}")
fi

exec "${CMD[@]}"
