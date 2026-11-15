/**
 * App-wide reactive state (Svelte 5 runes). One instance, imported everywhere.
 */
import {
  backend, get, onAnyEvent, onAnyExit, runRegistry, startEventBus, describeError,
  type AppContext, type EngineCommand, type EngineEvent, type PackInfo, type PhaseId,
  type PhoenixConfig, type RunRecord, type VersionInfo,
} from './engine';

export type Screen = 'runbook' | 'profile' | 'answer' | 'packs' | 'plan' | 'apps' | 'usb';

export interface LogLine {
  seq: number;
  runId: number;
  command: string;
  at: number;
  level: 'info' | 'warn' | 'error' | 'debug';
  text: string;
  event: EngineEvent;
}

export interface Toast { id: number; kind: 'ok' | 'warn' | 'error' | 'info'; text: string }

export const DEFAULT_CONFIG: PhoenixConfig = {
  schema: 1,
  machine: {
    computerName: 'THE-MACHINE', timeZone: 'Central Standard Time', edition: 'Windows 11 Pro',
    productKey: '', uiLanguage: 'en-US', systemLocale: 'en-001', userLocale: 'en-001',
    inputLocale: '0409:00000409', diskNumber: 0,
  },
  accounts: { admin: { name: 'BigMan' }, lead: { name: 'Main' }, users: [] },
  packs: ['base', 'tier-balanced'],
  overrides: { steps: {}, items: {} },
  apps: [],
  loadout: [],
  usb: { label: 'PHOENIX' },
};

/** Fills any missing sections so screens can bind without null checks. */
export function normalizeConfig(c: Partial<PhoenixConfig> | null | undefined): PhoenixConfig {
  const d = structuredClone(DEFAULT_CONFIG);
  if (!c) return d;
  return {
    ...d,
    ...c,
    machine: { ...d.machine, ...(c.machine ?? {}) },
    accounts: {
      admin: { ...d.accounts.admin, ...(c.accounts?.admin ?? {}) },
      lead: { ...d.accounts.lead, ...(c.accounts?.lead ?? {}) },
      users: Array.isArray(c.accounts?.users) ? c.accounts!.users : [],
    },
    packs: Array.isArray(c.packs) ? c.packs : d.packs,
    overrides: {
      steps: { ...(c.overrides?.steps ?? {}) },
      items: { ...(c.overrides?.items ?? {}) },
    },
    apps: Array.isArray(c.apps) ? c.apps : [],
    loadout: Array.isArray(c.loadout) ? c.loadout : [],
    usb: { ...d.usb, ...(c.usb ?? {}) },
  };
}

const MAX_LOG = 4000;

function eventText(e: EngineEvent): { level: LogLine['level']; text: string } {
  switch (e.t) {
    case 'log': return { level: e.level, text: e.msg };
    case 'step': return {
      level: e.status === 'fail' ? 'error' : 'info',
      text: `[${e.step}] ${e.status}${e.msg ? ` — ${e.msg}` : ''}`,
    };
    case 'change': return {
      level: 'debug',
      text: `[${e.step}] ${e.action} ${e.key}: ${fmt(e.current)} → ${fmt(e.target)}${e.applied ? ' ✓' : ''}${e.msg ? ` (${e.msg})` : ''}`,
    };
    case 'progress': return { level: 'debug', text: `${e.step ? `[${e.step}] ` : ''}${e.pct}%${e.msg ? ` ${e.msg}` : ''}` };
    case 'result': {
      const err = !e.ok ? (e.data as { error?: string })?.error : '';
      return { level: e.ok ? 'info' : 'error', text: e.ok ? 'done' : `failed: ${err ?? 'unknown error'}` };
    }
  }
}

export function fmt(v: unknown): string {
  if (v === null || v === undefined) return '∅';
  if (typeof v === 'string') return v;
  try { return JSON.stringify(v); } catch { return String(v); }
}

class AppState {
  screen = $state<Screen>('runbook');
  ctx = $state<AppContext | null>(null);
  version = $state<VersionInfo | null>(null);
  versionError = $state<string | null>(null);

  config = $state<PhoenixConfig>(structuredClone(DEFAULT_CONFIG));
  configPath = $state<string | null>(null);
  isUserConfig = $state(false);
  configError = $state<string | null>(null);
  dirty = $state(false);

  packs = $state<PackInfo[]>([]);
  packsError = $state<string | null>(null);

  logs = $state<LogLine[]>([]);
  runs = $state<Record<number, RunRecord>>({});
  logOpen = $state(false);
  unseenErrors = $state(0);

  toasts = $state<Toast[]>([]);

  /** Phase the Plan screen should preselect when opened from the runbook. */
  planPhase = $state<PhaseId | ''>('');
  planAutoRun = $state(false);

  private seq = 0;
  private toastSeq = 0;
  private booted = false;

  async boot() {
    if (this.booted) return;
    this.booted = true;
    await startEventBus();
    runRegistry.listeners.add((r) => { this.runs[r.id] = r; });
    onAnyExit((id, code) => { if (this.runs[id]) this.runs[id].exitCode = code; });
    onAnyEvent(({ runId, event }) => {
      const { level, text } = eventText(event);
      const line: LogLine = {
        seq: ++this.seq, runId, command: this.runs[runId]?.command ?? '…', at: Date.now(), level, text, event,
      };
      this.logs.push(line);
      if (this.logs.length > MAX_LOG) this.logs.splice(0, this.logs.length - MAX_LOG);
      if (level === 'error' && !this.logOpen) this.unseenErrors++;
    });

    try { this.ctx = await backend.context(); } catch (e) { this.ctx = null; this.versionError = describeError(e); }
    await Promise.all([this.loadConfig(), this.loadVersion(), this.loadPacks()]);
  }

  async loadVersion() {
    try {
      this.version = await get<VersionInfo>('version');
      this.versionError = null;
    } catch (e) {
      this.versionError = describeError(e);
    }
  }

  async loadConfig() {
    try {
      const r = await backend.configLoad();
      this.config = normalizeConfig(r.config);
      this.configPath = r.path;
      this.isUserConfig = r.isUserConfig;
      this.configError = null;
    } catch (e) {
      this.config = normalizeConfig(null);
      this.configError = describeError(e);
    }
    this.dirty = false;
  }

  async saveConfig(): Promise<boolean> {
    try {
      const path = await backend.configSave($state.snapshot(this.config) as PhoenixConfig);
      this.configPath = path;
      this.isUserConfig = true;
      this.dirty = false;
      this.toast('ok', 'Config saved');
      return true;
    } catch (e) {
      this.toast('error', `Could not save config: ${describeError(e)}`);
      return false;
    }
  }

  /** Saves first if there are unsaved edits, so engine runs see what the user sees. */
  async ensureSaved(): Promise<boolean> {
    if (!this.dirty && this.isUserConfig) return true;
    return this.saveConfig();
  }

  markDirty() { this.dirty = true; }

  async loadPacks() {
    try {
      const r = await get<PackInfo[] | { packs: PackInfo[] }>('packs');
      this.packs = Array.isArray(r) ? r : (r?.packs ?? []);
      this.packsError = null;
    } catch (e) {
      this.packs = [];
      this.packsError = describeError(e);
    }
  }

  go(s: Screen) { this.screen = s; }

  openPlan(phase: PhaseId | '', autoRun = false) {
    this.planPhase = phase;
    this.planAutoRun = autoRun;
    this.screen = 'plan';
  }

  toast(kind: Toast['kind'], text: string, ms = 4200) {
    const id = ++this.toastSeq;
    this.toasts.push({ id, kind, text });
    setTimeout(() => { this.toasts = this.toasts.filter((t) => t.id !== id); }, ms);
  }

  clearLogs() { this.logs = []; this.unseenErrors = 0; }

  commandOf(runId: number): EngineCommand | undefined { return this.runs[runId]?.command; }
}

export const app = new AppState();
