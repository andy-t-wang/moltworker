import type { Sandbox } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { R2_MOUNT_PATH } from '../config';
import { mountR2Storage } from './r2';
import { waitForProcess } from './utils';

export interface SyncResult {
  success: boolean;
  lastSync?: string;
  error?: string;
  details?: string;
}

const TRANSIENT_SYNC_ERROR_FRAGMENTS = [
  'durable object reset because its code was updated',
  'network connection lost',
] as const;
const TRANSIENT_SYNC_RETRY_DELAYS_MS = [250, 500, 1000] as const;

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

function isTransientSyncError(error: unknown): boolean {
  const message = getErrorMessage(error).toLowerCase();
  return TRANSIENT_SYNC_ERROR_FRAGMENTS.some((fragment) => message.includes(fragment));
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function withTransientSyncRetry<T>(
  operationName: string,
  operation: () => Promise<T>,
  attempt: number = 0,
): Promise<T> {
  try {
    return await operation();
  } catch (error) {
    if (!isTransientSyncError(error) || attempt >= TRANSIENT_SYNC_RETRY_DELAYS_MS.length) {
      throw error;
    }

    const delayMs = TRANSIENT_SYNC_RETRY_DELAYS_MS[attempt];
    console.warn(
      `[sync] ${operationName} hit transient error; retrying in ${delayMs}ms (attempt ${attempt + 1}/${TRANSIENT_SYNC_RETRY_DELAYS_MS.length + 1})`,
    );
    await sleep(delayMs);
    return withTransientSyncRetry(operationName, operation, attempt + 1);
  }
}

async function fileExists(sandbox: Sandbox, path: string): Promise<boolean> {
  const proc = await withTransientSyncRetry('file-exists-check', async () =>
    sandbox.startProcess(`if [ -f '${path}' ]; then echo exists; else echo missing; fi`),
  );
  await waitForProcess(proc, 5000);
  const logs = await withTransientSyncRetry('file-exists-logs', async () => proc.getLogs());
  return logs.stdout?.trim().toLowerCase().includes('exists') ?? false;
}

/**
 * Sync OpenClaw config and workspace from container to R2 for persistence.
 *
 * This function:
 * 1. Mounts R2 if not already mounted
 * 2. Verifies source has critical files (prevents overwriting good backup with empty data)
 * 3. Runs rsync to copy config, workspace, and skills to R2
 * 4. Writes a timestamp file for tracking
 *
 * Syncs three directories:
 * - Config: /root/.openclaw/ (or /root/.clawdbot/) → R2:/openclaw/
 * - Workspace: /root/clawd/ → R2:/workspace/ (IDENTITY.md, MEMORY.md, memory/, assets/)
 * - Skills: /root/clawd/skills/ → R2:/skills/
 *
 * @param sandbox - The sandbox instance
 * @param env - Worker environment bindings
 * @returns SyncResult with success status and optional error details
 */
export async function syncToR2(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  return withTransientSyncRetry('syncToR2', async () => syncToR2Once(sandbox, env));
}

async function syncToR2Once(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  // Check if R2 is configured
  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY || !env.CF_ACCOUNT_ID) {
    return { success: false, error: 'R2 storage is not configured' };
  }

  // Mount R2 if not already mounted
  const mounted = await mountR2Storage(sandbox, env);
  if (!mounted) {
    return { success: false, error: 'Failed to mount R2 storage' };
  }

  // Determine which config directory exists
  // Check new path first, fall back to legacy
  let configDir: string | null = '/root/.openclaw';
  try {
    const hasOpenClawConfig = await fileExists(sandbox, '/root/.openclaw/openclaw.json');
    if (!hasOpenClawConfig) {
      const hasLegacyConfig = await fileExists(sandbox, '/root/.clawdbot/clawdbot.json');
      if (hasLegacyConfig) {
        configDir = '/root/.clawdbot';
      } else {
        // Don't fail the entire sync; keep backing up workspace/skills so user data persists.
        // We intentionally skip config rsync to avoid deleting existing config backup with empty data.
        console.warn('[sync] No config file found; syncing workspace/skills only');
        configDir = null;
      }
    }
  } catch (err) {
    return {
      success: false,
      error: 'Failed to verify source files',
      details: err instanceof Error ? err.message : 'Unknown error',
    };
  }

  // Sync to the new openclaw/ R2 prefix (even if source is legacy .clawdbot)
  // Also sync workspace directory (excluding skills since they're synced separately)
  const syncParts: string[] = [];
  if (configDir) {
    syncParts.push(
      `rsync -r --no-times --delete --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' ${configDir}/ ${R2_MOUNT_PATH}/openclaw/`,
    );
  }
  syncParts.push(
    `rsync -r --no-times --delete --exclude='skills' /root/clawd/ ${R2_MOUNT_PATH}/workspace/`,
  );
  syncParts.push(`rsync -r --no-times --delete /root/clawd/skills/ ${R2_MOUNT_PATH}/skills/`);
  syncParts.push(`date -Iseconds > ${R2_MOUNT_PATH}/.last-sync`);
  const syncCmd = syncParts.join(' && ');

  try {
    const proc = await withTransientSyncRetry('sync-start-process', async () =>
      sandbox.startProcess(syncCmd),
    );
    await waitForProcess(proc, 30000); // 30 second timeout for sync

    // Check for success by reading the timestamp file
    const timestampProc = await withTransientSyncRetry('sync-timestamp-process', async () =>
      sandbox.startProcess(`cat ${R2_MOUNT_PATH}/.last-sync`),
    );
    await waitForProcess(timestampProc, 5000);
    const timestampLogs = await withTransientSyncRetry('sync-timestamp-logs', async () =>
      timestampProc.getLogs(),
    );
    const lastSync = timestampLogs.stdout?.trim();

    if (lastSync && lastSync.match(/^\d{4}-\d{2}-\d{2}/)) {
      return { success: true, lastSync };
    } else {
      const logs = await withTransientSyncRetry('sync-process-logs', async () => proc.getLogs());
      return {
        success: false,
        error: 'Sync failed',
        details: logs.stderr || logs.stdout || 'No timestamp file created',
      };
    }
  } catch (err) {
    return {
      success: false,
      error: 'Sync error',
      details: err instanceof Error ? err.message : 'Unknown error',
    };
  }
}
