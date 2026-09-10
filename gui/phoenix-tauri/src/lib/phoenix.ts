import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import type { AppEntry, DriveInfo, PhoenixConfig } from './types';

/** One streamed line from a child PowerShell process (Rust emits these). */
export interface ScriptLine {
  stream: 'stdout' | 'stderr' | 'status';
  line: string;
}

/** Subscribe to streamed PowerShell output. The promise resolves to the unlisten fn. */
export function onScriptOutput(cb: (msg: ScriptLine) => void): Promise<UnlistenFn> {
  return listen<ScriptLine>('phx-output', (e) => cb(e.payload));
}

/** SPIKE: spawn a .ps1 and stream its output. The workhorse for stager scripts. */
export const streamPowershellScript = (scriptPath: string, args: string[] = []) =>
  invoke<void>('stream_powershell_script', { scriptPath, args });

/** SPIKE companion: stream an inline PowerShell snippet (diagnostics). */
export const streamPowershellInline = (command: string) =>
  invoke<void>('stream_powershell_inline', { command });

export const listRemovableDrives = () => invoke<DriveInfo[]>('list_removable_drives');

export const verifyVentoy = (drive: string) => invoke<boolean>('verify_ventoy', { drive });

export const writePhoenixConfig = (drive: string, config: PhoenixConfig) =>
  invoke<string>('write_phoenix_config', { drive, config });

export const getAppCatalog = (repoRoot: string) =>
  invoke<AppEntry[]>('get_app_catalog', { repoRoot });
