import type { Blade } from './types';

/**
 * Blade registry. "Multiple smart interfaces" = ONE Tauri app whose
 * interfaces register here. Today there is exactly one blade; adding a
 * second (e.g. a macOS startosinstall/MDM blade) is a registry entry +
 * its Svelte view, no app rewrite.
 */
export const BLADES: Blade[] = [
  {
    id: 'usb-builder',
    label: 'USB Builder',
    platforms: ['windows'],
    description:
      'Stage Ventoy ISOs (SystemRescue / Rescuezilla / ShredOS / WinPE+Win ISO) and write phoenix-config.json to the USB. Boot side stays headless.',
  },
  // Future blades plug in here, e.g.:
  // { id: 'mac-blade', label: 'Mac Provisioner', platforms: ['macos'],
  //   description: 'startosinstall / MDM path - Apple Silicon Macs cannot boot the Ventoy USB.' },
];

export const ACTIVE_BLADE: Blade = BLADES[0];
