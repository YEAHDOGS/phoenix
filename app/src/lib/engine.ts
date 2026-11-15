/**
 * Typed client for the Phoenix engine (docs/ARCHITECTURE.md).
 *
 * The Rust side spawns scripts/engine/phoenix.ps1 and forwards each NDJSON line as an
 * `engine-event`; every run ends with `engine-exit`. Nothing here builds
 * PowerShell: commands are names from a fixed allowlist plus a JSON args object.
 */
import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';

export type EngineCommand =
  | 'version' | 'profile' | 'packs' | 'plan' | 'apply' | 'undo' | 'snapshots' | 'scan'
  | 'state' | 'mark' | 'runbook' | 'drives' | 'unattend' | 'loadout' | 'fetch'
  | 'usb-build' | 'usb-verify' | 'choco-search' | 'launch' | 'unattend-schema' | 'unattend-defaults';

export type Level = 'info' | 'warn' | 'error';
export type Risk = 'safe' | 'caution' | 'danger';
export type PhaseId = 'admin' | 'admin-post' | 'user-offline' | 'user-online';

export interface LogEvent { t: 'log'; ts: string; level: Level; msg: string }
export interface StepEvent { t: 'step'; ts: string; step: string; status: 'start' | 'ok' | 'skip' | 'fail'; msg?: string }
export interface ChangeEvent {
  t: 'change'; ts: string; step: string; key: string;
  current: unknown; target: unknown;
  action: 'set' | 'remove' | 'disable' | 'enable' | 'add' | 'skip';
  applied: boolean; msg?: string;
}
export interface ProgressEvent { t: 'progress'; ts: string; step?: string; pct: number; msg?: string }
export interface ResultEvent<T = unknown> { t: 'result'; ts: string; ok: boolean; data: T }
export type EngineEvent = LogEvent | StepEvent | ChangeEvent | ProgressEvent | ResultEvent;

export interface EngineError { error: string; needsAdmin?: boolean; at?: string; exitCode?: number }

export interface RunRecord {
  id: number;
  command: EngineCommand;
  elevated: boolean;
  startedAt: number;
  exitCode?: number;
}

export interface Envelope { runId: number; event: EngineEvent }

// ------------------------------------------------------------------ event bus

type Handler = (e: EngineEvent) => void;
const perRun = new Map<number, Set<Handler>>();
const exitWaiters = new Map<number, Set<(code: number) => void>>();
const globalHandlers = new Set<(env: Envelope) => void>();
const exitHandlers = new Set<(runId: number, code: number) => void>();
/** Recent runs' events + exit codes, so a subscriber that registers after a
 *  fast run already finished still sees everything. */
const history = new Map<number, { events: EngineEvent[]; exit?: number }>();
const HISTORY_RUNS = 64;
let started: Promise<UnlistenFn[]> | null = null;

function hist(runId: number) {
  let h = history.get(runId);
  if (!h) {
    h = { events: [] };
    history.set(runId, h);
    if (history.size > HISTORY_RUNS) history.delete(history.keys().next().value as number);
  }
  return h;
}

/** Starts the single global listener. Safe to call repeatedly. */
export function startEventBus(): Promise<UnlistenFn[]> {
  if (!started) {
    started = Promise.all([
      listen<Envelope>('engine-event', ({ payload }) => {
        const h = hist(payload.runId);
        if (h.events.length < 20000) h.events.push(payload.event);
        for (const g of globalHandlers) g(payload);
        perRun.get(payload.runId)?.forEach((fn) => fn(payload.event));
      }),
      listen<{ runId: number; command: EngineCommand; elevated: boolean }>('engine-start', ({ payload }) => {
        runRegistry.notify({ id: payload.runId, command: payload.command, elevated: payload.elevated, startedAt: Date.now() });
      }),
      listen<{ runId: number; code: number }>('engine-exit', ({ payload }) => {
        hist(payload.runId).exit = payload.code;
        for (const g of exitHandlers) g(payload.runId, payload.code);
        exitWaiters.get(payload.runId)?.forEach((w) => w(payload.code));
        exitWaiters.delete(payload.runId);
        perRun.delete(payload.runId);
      }),
    ]);
  }
  return started;
}

export function onAnyEvent(h: (env: Envelope) => void): () => void {
  globalHandlers.add(h);
  return () => globalHandlers.delete(h);
}

export function onAnyExit(h: (runId: number, code: number) => void): () => void {
  exitHandlers.add(h);
  return () => exitHandlers.delete(h);
}

// ------------------------------------------------------------------ runs

export interface Run<T = unknown> {
  id: number;
  /** Resolves with the result event when the run exits. */
  done: Promise<ResultEvent<T | EngineError>>;
  cancel: () => Promise<boolean>;
}

/**
 * Starts a streaming run. `onEvent` sees every event of this run, including
 * any emitted before the run id came back over IPC (replayed from history).
 */
export async function run<T = unknown>(
  command: EngineCommand,
  args: Record<string, unknown> = {},
  opts: { elevated?: boolean; onEvent?: Handler } = {},
): Promise<Run<T>> {
  await startEventBus();
  const id = await invoke<number>(opts.elevated ? 'engine_run_elevated' : 'engine_run', { command, args });
  let result: ResultEvent<T | EngineError> | null = null;
  const handler: Handler = (e) => {
    if (e.t === 'result') result = e as ResultEvent<T | EngineError>;
    opts.onEvent?.(e);
  };
  const done = new Promise<ResultEvent<T | EngineError>>((resolve) => {
    const settle = (code: number) =>
      resolve(
        result ?? {
          t: 'result', ts: new Date().toISOString(), ok: false,
          data: { error: `Engine exited (${code}) without a result.`, exitCode: code },
        },
      );
    // Replay anything that arrived before we subscribed (all synchronous, so no
    // live event can interleave), then subscribe for the rest.
    const past = history.get(id);
    past?.events.forEach(handler);
    if (past?.exit !== undefined) { settle(past.exit); return; }
    if (!perRun.has(id)) perRun.set(id, new Set());
    perRun.get(id)!.add(handler);
    if (!exitWaiters.has(id)) exitWaiters.set(id, new Set());
    exitWaiters.get(id)!.add(settle);
  });
  return { id, done, cancel: () => invoke<boolean>('engine_cancel', { runId: id }) };
}

/** Runs to completion and returns the result event. */
export async function call<T = unknown>(
  command: EngineCommand,
  args: Record<string, unknown> = {},
  elevated = false,
): Promise<ResultEvent<T | EngineError>> {
  await startEventBus();
  return invoke<ResultEvent<T | EngineError>>('engine_call', { command, args, elevated });
}

/** Unwraps a result: data on success, throws EngineFailure otherwise. */
export class EngineFailure extends Error {
  constructor(public detail: EngineError, public command: string) {
    super(detail?.error ?? `${command} failed`);
  }
  get needsAdmin() { return !!this.detail?.needsAdmin; }
  get notImplemented() { return /not implemented|Unknown command/i.test(this.message); }
}

export function unwrap<T>(command: string, r: ResultEvent<T | EngineError>): T {
  if (!r.ok) throw new EngineFailure(r.data as EngineError, command);
  return r.data as T;
}

export async function get<T>(command: EngineCommand, args: Record<string, unknown> = {}): Promise<T> {
  return unwrap<T>(command, await call<T>(command, args));
}

/** Calls un-elevated; if the engine says it needs admin, retries through UAC. */
export async function getMaybeElevated<T>(command: EngineCommand, args: Record<string, unknown> = {}): Promise<T> {
  const r = await call<T>(command, args);
  if (!r.ok && (r.data as EngineError)?.needsAdmin) return unwrap<T>(command, await call<T>(command, args, true));
  return unwrap<T>(command, r);
}

// A tiny registry so the log drawer can label runs.
export const runRegistry = {
  listeners: new Set<(r: RunRecord) => void>(),
  notify(r: RunRecord) { for (const l of this.listeners) l(r); },
};

// ------------------------------------------------------------------ app backend

export interface AppContext {
  kitRoot: string | null;
  engineFound: boolean;
  engineError: string | null;
  isUsbKit: boolean;
  isInstalledKit: boolean;
  configPath: string | null;
  userConfigPath: string | null;
  exePath: string | null;
}

export const backend = {
  context: () => invoke<AppContext>('app_context'),
  configLoad: () => invoke<{ path: string; isUserConfig: boolean; config: PhoenixConfig }>('config_load'),
  configSave: (config: PhoenixConfig) => invoke<string>('config_save', { config }),
  packRead: (id: string) => invoke<Pack>('pack_read', { id }),
  packSave: (id: string, value: Pack) => invoke<string>('pack_save', { id, value }),
  packImport: (path: string, overwrite = false) => invoke<string>('pack_import', { path, overwrite }),
  packExport: (id: string, path: string) => invoke<void>('pack_export', { id, path }),
  catalogLoad: () => invoke<{ source: string | null; apps: CatalogEntry[] }>('catalog_load'),
  secretsWrite: (value: Secrets) => invoke<string>('secrets_write', { value }),
  secretsDiscard: (path: string) => invoke<void>('secrets_discard', { path }),
  tmpFile: (prefix: string, ext: string) => invoke<string>('tmp_file', { prefix, ext }),
  tmpReadText: (path: string) => invoke<string>('tmp_read_text', { path }),
  tmpSaveAs: (path: string, dest: string, keep = false) => invoke<void>('tmp_save_as', { path, dest, keep }),
  tmpDiscard: (path: string) => invoke<void>('tmp_discard', { path }),
  readFileBase64: (path: string) =>
    invoke<{ name: string | null; sizeBytes: number; base64: string }>('read_file_base64', { path }),
  openPath: (path: string) => invoke<void>('open_path', { path }),
  openUrl: (url: string) => invoke<void>('open_url', { url }),
};

// ------------------------------------------------------------------ contract types

export interface Account { name: string }
export interface PhoenixConfig {
  schema: number;
  machine: {
    computerName: string; timeZone: string; edition: string; productKey: string;
    uiLanguage: string; systemLocale: string; userLocale: string; inputLocale: string;
    diskNumber: number;
  };
  accounts: { admin: Account; lead: Account; users: Account[] };
  packs: string[];
  overrides: {
    steps: Record<string, { enabled?: boolean }>;
    items: Record<string, { key: string; enabled?: boolean }[]>;
  };
  apps: string[];
  loadout: string[];
  usb: { label: string };
  /** Schneegans unattend-generator DTO (see ARCHITECTURE.md "Answer file"). */
  unattend?: Record<string, unknown>;
  /** Accounts + FirstLogon handoff come from Profile (default true). */
  unattendAccountsFromProfile?: boolean;
  [k: string]: unknown;
}

export interface Secrets { admin: string; lead: string; users: Record<string, string> }

export interface StepItem {
  key?: string;
  why?: string;
  risk?: Risk;
  enabled?: boolean;
  [k: string]: unknown;
}

export interface Step {
  id: string;
  phase: PhaseId | string;
  kind: string;
  title?: string;
  why?: string;
  risk?: Risk;
  enabled?: boolean;
  items?: StepItem[];
  instructions?: string;
  [k: string]: unknown;
}

export interface Pack { id: string; name?: string; description?: string; version?: number; steps: Step[] }
export interface PackInfo { id: string; name?: string; description?: string; stepCount?: number; steps?: number; [k: string]: unknown }

export interface CatalogEntry {
  package?: string; id?: string; name?: string; title?: string;
  description?: string; category?: string; defaultSelected?: boolean; default?: boolean;
}

export interface ChocoResult { id: string; title?: string; version?: string; summary?: string; downloads?: number }

export interface Drive {
  number: number; letter: string | null; label: string | null; sizeBytes: number;
  busType?: string; fileSystem?: string | null; isBoot?: boolean; isSystem?: boolean;
  [k: string]: unknown;
}

export interface LoadoutItem {
  id: string; name?: string; category?: string; description?: string;
  cached?: boolean; version?: string | null; sha256?: string | null; sizeBytes?: number | null;
  [k: string]: unknown;
}

export interface VersionInfo {
  engineVersion: string; psVersion: string; isAdmin: boolean; os: string; kitRoot: string; commands: string[];
}

/** Item key per the contract's default-key table. */
export function itemKey(kind: string, item: StepItem): string {
  if (typeof item.key === 'string' && item.key) return item.key;
  const pick = (f: string) => (typeof item[f] === 'string' ? (item[f] as string) : undefined);
  switch (kind) {
    case 'setting': return pick('setting') ?? JSON.stringify(item);
    case 'services': case 'features': case 'autoruns': case 'firewall': return pick('name') ?? JSON.stringify(item);
    case 'devices': return JSON.stringify(item.match ?? item);
    case 'tasks': return pick('path') ?? JSON.stringify(item);
    case 'appx': return pick('pattern') ?? JSON.stringify(item);
    case 'registry': return `${pick('path') ?? ''}\\${pick('name') ?? ''}`;
    case 'network': return pick('binding') ?? JSON.stringify(item);
    case 'tools': return pick('loadout') ?? pick('env') ?? pick('profileSnippet') ?? JSON.stringify(item);
    default: return pick('name') ?? JSON.stringify(item);
  }
}

/** One-line human label for an item. */
export function itemLabel(kind: string, item: StepItem): string {
  const s = (f: string) => (item[f] === undefined ? '' : String(item[f]));
  switch (kind) {
    case 'setting': return `${s('setting')}: ${s('value')}`;
    case 'services': return `${s('name')} → ${s('startup') || 'Disabled'}${item.stop ? ' (stop)' : ''}`;
    case 'devices': {
      const m = (item.match ?? {}) as Record<string, string>;
      const what = Object.entries(m).map(([k, v]) => `${k}: ${v}`).join(', ');
      return `${s('action') || 'disable'} · ${what}`;
    }
    case 'tasks': return `${s('action') || 'disable'} · ${s('path')}`;
    case 'features': return `${s('action') || 'remove'} · ${s('name')}`;
    case 'appx': return `${s('action') || 'remove'} · ${s('pattern')}`;
    case 'registry': return `${s('path')}\\${s('name')} = ${JSON.stringify(item.value)} (${s('type')}${item.scope ? `, ${s('scope')}` : ''})`;
    case 'autoruns': return `${s('action') || 'disable'} · ${s('name')}`;
    case 'firewall': return `${s('action') || 'Allow'} ${s('direction')} · ${s('name')}${item.program ? ` (${s('program')})` : ''}`;
    case 'network': return `${s('binding')} → ${item.enabled === false ? 'off' : 'on'}`;
    case 'tools':
      if (item.loadout) return `copy ${s('loadout')} → ${s('dest')}`;
      if (item.env) return `env ${s('env')} = ${s('value')}`;
      return `$PROFILE snippet`;
    default: return itemKey(kind, item);
  }
}

export function formatBytes(n?: number | null): string {
  if (n === undefined || n === null || !isFinite(n)) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0; let v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
}

export function describeError(e: unknown): string {
  if (e instanceof EngineFailure) {
    if (e.notImplemented) return `The engine doesn't implement "${e.command}" yet.`;
    return e.message;
  }
  if (e instanceof Error) return e.message;
  return String(e);
}
