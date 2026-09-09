/**
 * Phoenix config schema + app types.
 *
 * OS-AGNOSTIC BY DESIGN (founder requirement): the top level carries no
 * Windows-only keys. A `platform` discriminator selects the OS, and anything
 * platform-specific nests under `platformOptions`. A future macOS blade
 * (startosinstall/MDM path - Apple Silicon Macs can't boot the Ventoy USB,
 * so it's a separate blade, not the same stick) plugs into this same schema
 * with platform: 'macos' + platformOptions.macos.
 */

export interface AppEntry {
  package: string;
  description: string;
  category: string;
  defaultSelected: boolean;
}

export interface BootModule {
  id: 'analyze' | 'backup' | 'nuke' | 'reinstall';
  label: string;
  /** ISO staged onto the Ventoy USB for this option */
  isoLabel: string;
  description: string;
  defaultStaged: boolean;
  dangerous: boolean;
}

export interface PhoenixCredentials {
  username: string;
  /** Plaintext on the USB by necessity (unattend requires it; WinPE can't use
   *  the build machine's DPAPI key). Policy: throwaway install-time credential,
   *  changed after first logon. Never written to the GUI log. */
  password: string;
}

export interface WindowsPlatformOptions {
  computerName: string;
  edition: string;
  productKey: string;
  skipOobe: boolean;
  disableWpbt: boolean;
  stageUpdates: boolean;
  driverProfile: string;
}

export interface PhoenixBackupConfig {
  /** Direct-attached USB target for the full-disk image (air-gapped, Phase 2) */
  imageTargetPath: string;
  /** Quarantine folder label pattern for the infected image, e.g. QUARANTINE-INFECTED-<date> */
  quarantineLabel: string;
  /** Long-term copy target on Castle (SMB share/path) for the quarantined image */
  castleTarget: string;
  /** The boot menu must refuse NUKE without proof of a verified image */
  requireVerifiedImage: boolean;
}

export interface PhoenixConfig {
  version: 1;
  platform: 'windows'; // | 'macos' | 'linux' - future blades
  credentials: PhoenixCredentials;
  apps: string[];
  options: {
    timeZone: string;
    locale: string;
  };
  backup: PhoenixBackupConfig;
  platformOptions: {
    windows?: WindowsPlatformOptions;
    macos?: Record<string, unknown>; // future blade
  };
  /** Boot modules to stage, e.g. ['analyze','backup','reinstall'] */
  modules: string[];
}

/**
 * A "smart interface" blade. The app ships ONE blade today (USB Builder);
 * the registry is the seam more blades plug into later.
 */
export interface Blade {
  id: string;
  label: string;
  platforms: string[];
  description: string;
}

export interface LogLine {
  t: string;
  level: 'info' | 'warn' | 'error' | 'success' | 'stdout' | 'stderr';
  text: string;
}

export interface DriveInfo {
  letter: string;
  label: string;
}
