import type { LogLine, PhoenixConfig } from './types';

/**
 * Shared wizard + build state (Svelte 5 runes).
 * Password lives here as plaintext in memory only: never logged (see log()),
 * cleared after the build (see clearPassword()).
 */
export const setup = $state({
  computerName: '',
  username: '',
  password: '',
  timeZone: '',
  edition: 'Pro',
  productKey: '',
  locale: 'en-US',
  skipOobe: true,
  disableWpbt: true,
  stageUpdates: false,
  driverProfile: '',
  imageTargetPath: '',
  quarantineLabel: 'QUARANTINE-INFECTED-<date>',
  castleTarget: '',
  requireVerifiedImage: true,
  apps: [] as string[],
  modules: ['analyze', 'backup', 'reinstall'] as string[],
  drive: 'E:',
  repoRoot: '',
});

export const logLines = $state<LogLine[]>([]);

const SECRET_KEYS = /(password|secret|token|productkey)/i;

/** Append to the GUI log. Any data key that looks like a secret is redacted. */
export function log(level: LogLine['level'], text: string, data?: Record<string, unknown>) {
  let line = text;
  if (data) {
    const parts = Object.entries(data).map(([k, v]) =>
      SECRET_KEYS.test(k) ? `${k}=***REDACTED***` : `${k}=${v}`,
    );
    line += ' | ' + parts.join(' ');
  }
  logLines.push({ t: new Date().toLocaleTimeString(), level, text: line });
}

/** Build the OS-agnostic phoenix-config.json payload from wizard state. */
export function buildConfig(): PhoenixConfig {
  return {
    version: 1,
    platform: 'windows',
    credentials: { username: setup.username, password: setup.password },
    apps: [...setup.apps],
    options: { timeZone: setup.timeZone, locale: setup.locale },
    backup: {
      imageTargetPath: setup.imageTargetPath,
      quarantineLabel: setup.quarantineLabel,
      castleTarget: setup.castleTarget,
      requireVerifiedImage: setup.requireVerifiedImage,
    },
    platformOptions: {
      windows: {
        computerName: setup.computerName,
        edition: setup.edition,
        productKey: setup.productKey,
        skipOobe: setup.skipOobe,
        disableWpbt: setup.disableWpbt,
        stageUpdates: setup.stageUpdates,
        driverProfile: setup.driverProfile,
      },
    },
    modules: [...setup.modules],
  };
}

/** Shrink the plaintext-password window after the build. */
export function clearPassword() {
  setup.password = '';
}
