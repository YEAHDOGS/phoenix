/** Runbook stage model (scripts/engine/runbook.json, merged with state by the engine). */
import type { PhaseId } from './engine';

export interface Stage {
  id: string;
  title: string;
  kind: 'build' | 'manual' | 'phase' | string;
  phase?: PhaseId;
  who?: 'admin' | 'lead' | 'any' | string;
  network?: 'online' | 'offline' | string;
  next?: string | null;
  instructions?: string;
  warnings?: string[];
  launch?: { loadout: string; args?: string[] };
  status?: string;
  at?: string;
}

export interface StateDoc { stages?: Record<string, { status?: string; at?: string }> }

/** Used only when the engine can't serve runbook.json (keeps the app usable). */
export const FALLBACK_STAGES: Stage[] = [
  { id: 'prepare', title: 'Build the Phoenix USB', kind: 'build', who: 'any', network: 'online',
    instructions: 'Configure **Profile**, **Packs** and **Apps**, then build the stick on the **USB** screen.' },
  { id: 'wifi-out', title: 'Remove the Wi-Fi card', kind: 'manual', who: 'any', network: 'offline',
    instructions: 'Power off, unplug, and remove the M.2 Wi-Fi card. The install stays air-gapped.' },
  { id: 'bios-wipe', title: 'BIOS: wipe the SSD', kind: 'manual', who: 'any', network: 'offline',
    instructions: 'Run the firmware secure erase for the SSD, then boot from the Windows 11 USB.' },
  { id: 'install', title: 'Install Windows (unattended)', kind: 'manual', who: 'any', network: 'offline',
    instructions: 'Plug in both USBs. Setup reads `autounattend.xml` from the Phoenix USB and runs to the desktop.' },
  { id: 'admin', title: 'Admin phase (automatic)', kind: 'phase', phase: 'admin', who: 'admin', network: 'offline',
    instructions: 'Runs at first logon from the Phoenix USB, then powers off.' },
  { id: 'playbook', title: 'Dogs Playbook', kind: 'manual', who: 'admin', network: 'offline',
    launch: { loadout: 'ame-wizard' }, instructions: 'Unplug the Windows USB, log on as the admin and run Dogs Playbook in AME Wizard.' },
  { id: 'admin-post', title: 'Defender, ASR, BitLocker', kind: 'phase', phase: 'admin-post', who: 'admin', network: 'offline',
    instructions: 'Turns Defender back on, loads offline signatures, applies ASR rules, optionally enables BitLocker.' },
  { id: 'user-offline', title: 'Lead user setup (offline)', kind: 'phase', phase: 'user-offline', who: 'lead', network: 'offline',
    instructions: 'Per-user privacy, tools, environment and `$PROFILE`.' },
  { id: 'wifi-in', title: 'Put the Wi-Fi card back', kind: 'manual', who: 'any', network: 'online',
    instructions: 'Power off, reinstall the Wi-Fi card, boot and log on as the lead user.' },
  { id: 'user-online', title: 'Network, firewall, apps', kind: 'phase', phase: 'user-online', who: 'lead', network: 'online',
    instructions: 'Adapter bindings, a time-boxed firewall window for Chocolatey, then your apps.' },
  { id: 'breathe', title: 'Breathe', kind: 'manual', who: 'any', network: 'online', instructions: 'You did it.' },
];

export function isFinished(status?: string) {
  return status === 'done' || status === 'skipped' || status === 'ok' || status === 'skip';
}
