<script lang="ts">
  import { onMount } from 'svelte';
  import { ask, open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog';
  import { app } from '$lib/app.svelte';
  import { backend, describeError, get, itemKey, itemLabel, type Pack, type Step, type StepItem } from '$lib/engine';
  import PageHeader from '$lib/components/PageHeader.svelte';
  import Notice from '$lib/components/Notice.svelte';
  import RiskBadge from '$lib/components/RiskBadge.svelte';
  import Toggle from '$lib/components/Toggle.svelte';
  import Icon from '$lib/components/Icon.svelte';

  type Source = '__resolved' | string;
  let source = $state<Source>('__resolved');
  let steps = $state<Step[]>([]);
  let pack = $state<Pack | null>(null);
  let packDirty = $state(false);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let query = $state('');
  let phaseFilter = $state('');
  let open = $state<Record<string, boolean>>({});

  const resolved = $derived(source === '__resolved');
  const PHASES = ['admin', 'admin-post', 'user-offline', 'user-online'];
  const phaseTitle: Record<string, string> = {
    admin: 'Admin phase · air-gapped, automatic at first logon',
    'admin-post': 'Admin, after the playbook · Defender, ASR, BitLocker',
    'user-offline': 'Lead user · offline',
    'user-online': 'Lead user · online (Wi-Fi back in)',
    other: 'Other',
  };

  async function load() {
    loading = true;
    error = null;
    open = {};
    try {
      if (resolved) {
        if (app.dirty) await app.saveConfig();
        const r = await get<{ steps: Step[] }>('profile', {});
        steps = r?.steps ?? [];
        pack = null;
      } else {
        pack = await backend.packRead(source);
        steps = pack.steps ?? [];
      }
      packDirty = false;
    } catch (e) {
      error = describeError(e);
      steps = [];
    }
    loading = false;
  }

  // ----- effective values (resolved view reflects unsaved overrides too)
  const ov = $derived(app.config.overrides);
  function stepEnabled(s: Step): boolean {
    if (resolved && ov.steps[s.id]?.enabled !== undefined) return !!ov.steps[s.id].enabled;
    return s.enabled !== false && !(!resolved && s.risk === 'danger' && s.enabled === undefined);
  }
  function itemEnabled(s: Step, it: StepItem): boolean {
    if (resolved) {
      const k = itemKey(s.kind, it);
      const o = ov.items[s.id]?.find((x) => x.key === k);
      if (o?.enabled !== undefined) return !!o.enabled;
    }
    return it.enabled !== false;
  }

  function setStep(s: Step, v: boolean) {
    if (resolved) {
      app.config.overrides.steps[s.id] = { ...(app.config.overrides.steps[s.id] ?? {}), enabled: v };
      app.markDirty();
    } else {
      s.enabled = v;
      packDirty = true;
    }
  }
  function setItem(s: Step, it: StepItem, v: boolean) {
    if (resolved) {
      const k = itemKey(s.kind, it);
      const list = (app.config.overrides.items[s.id] ??= []);
      const o = list.find((x) => x.key === k);
      if (o) o.enabled = v;
      else list.push({ key: k, enabled: v });
      app.markDirty();
    } else {
      it.enabled = v;
      packDirty = true;
    }
  }

  function overridden(s: Step) {
    return resolved && (ov.steps[s.id] !== undefined || (ov.items[s.id]?.length ?? 0) > 0);
  }
  function clearOverrides(s: Step) {
    delete app.config.overrides.steps[s.id];
    delete app.config.overrides.items[s.id];
    app.markDirty();
  }

  // ----- filtering + grouping
  const q = $derived(query.trim().toLowerCase());
  function matches(s: Step) {
    if (phaseFilter && s.phase !== phaseFilter) return false;
    if (!q) return true;
    const hay = [s.id, s.title, s.kind, s.why, ...(s.items ?? []).map((i) => itemLabel(s.kind, i) + ' ' + (i.why ?? ''))]
      .join(' ')
      .toLowerCase();
    return hay.includes(q);
  }
  const groups = $derived.by(() => {
    const m = new Map<string, Step[]>();
    for (const s of steps.filter(matches)) {
      const ph = PHASES.includes(String(s.phase)) ? String(s.phase) : 'other';
      if (!m.has(ph)) m.set(ph, []);
      m.get(ph)!.push(s);
    }
    return [...PHASES, 'other'].filter((p) => m.has(p)).map((p) => ({ phase: p, steps: m.get(p)! }));
  });
  const visibleItems = (s: Step) =>
    (s.items ?? []).filter((i) => !q || (itemLabel(s.kind, i) + ' ' + (i.why ?? '') + ' ' + s.title + ' ' + s.id).toLowerCase().includes(q));

  // ----- pack file ops
  async function savePack() {
    if (!pack) return;
    try {
      await backend.packSave(pack.id, $state.snapshot(pack) as Pack);
      packDirty = false;
      app.toast('ok', `Saved pack ${pack.id}`);
      app.loadPacks();
    } catch (e) {
      app.toast('error', describeError(e));
    }
  }
  async function importPack() {
    const path = await openDialog({ multiple: false, filters: [{ name: 'Phoenix pack', extensions: ['json'] }] });
    if (!path || Array.isArray(path)) return;
    try {
      const id = await backend.packImport(path);
      app.toast('ok', `Imported pack "${id}". Add it on the Profile screen to use it.`);
      await app.loadPacks();
      source = id;
      load();
    } catch (e) {
      const msg = describeError(e);
      if (/already exists/.test(msg) && (await ask(`${msg}. Overwrite it?`, { title: 'Import pack', kind: 'warning' }))) {
        const id = await backend.packImport(path, true);
        app.toast('ok', `Replaced pack "${id}"`);
        await app.loadPacks();
      } else app.toast('error', msg);
    }
  }
  async function exportPack() {
    if (resolved) return;
    const path = await saveDialog({ defaultPath: `${source}.json`, filters: [{ name: 'Phoenix pack', extensions: ['json'] }] });
    if (!path) return;
    try {
      await backend.packExport(source, path);
      app.toast('ok', `Exported ${source}`);
    } catch (e) {
      app.toast('error', describeError(e));
    }
  }

  const counts = $derived({
    steps: steps.length,
    on: steps.filter((s) => stepEnabled(s)).length,
    items: steps.reduce((n, s) => n + (s.items?.length ?? 0), 0),
  });

  onMount(load);
</script>

<PageHeader title="Packs" subtitle="Every change Phoenix can make, grouped by phase. Toggle anything off for this machine; danger items stay off until you turn them on.">
  {#snippet actions()}
    <button class="btn-ghost" onclick={importPack}><Icon name="download" size={15} /> Import</button>
    <button class="btn-ghost" disabled={resolved} onclick={exportPack}><Icon name="external" size={15} /> Export</button>
    {#if !resolved}<button class="btn-primary" disabled={!packDirty} onclick={savePack}><Icon name="save" size={15} /> Save to pack</button>{/if}
    {#if resolved && app.dirty}<button class="btn-primary" onclick={() => app.saveConfig()}><Icon name="save" size={15} /> Save overrides</button>{/if}
  {/snippet}
</PageHeader>

<div class="mb-4 flex flex-wrap items-center gap-3">
  <select class="input w-72" bind:value={source} onchange={load}>
    <option value="__resolved">Resolved profile (your stack + overrides)</option>
    {#each app.packs as p (p.id)}<option value={p.id}>Pack: {p.name ?? p.id}</option>{/each}
  </select>
  <select class="input w-48" bind:value={phaseFilter}>
    <option value="">All phases</option>
    {#each PHASES as p}<option value={p}>{p}</option>{/each}
  </select>
  <div class="relative min-w-60 flex-1">
    <span class="absolute top-2 left-2.5 text-ink-400"><Icon name="search" size={15} /></span>
    <input class="input pl-8" placeholder="Filter steps and items (e.g. DiagTrack, pagefile, xbox)" bind:value={query} />
  </div>
  <span class="text-xs text-ink-400">{counts.on}/{counts.steps} steps on · {counts.items} items</span>
</div>

{#if resolved}
  <div class="mb-4"><Notice kind="info">Toggles here are saved as <strong>overrides</strong> in your config. The pack files are untouched, so you can share them as-is.</Notice></div>
{:else}
  <div class="mb-4"><Notice kind="warn">You're editing the pack file itself. Changes affect every config that uses <code class="kbd">{source}</code>.</Notice></div>
{/if}

{#if error}<Notice kind="error" title="Couldn't load">{error}</Notice>{/if}
{#if loading}<div class="muted py-8 text-center">Loading…</div>{/if}

{#each groups as g (g.phase)}
  <section class="mb-6">
    <h2 class="mb-2 text-xs font-semibold tracking-wider text-ink-400 uppercase">{phaseTitle[g.phase] ?? g.phase}</h2>
    <div class="space-y-2">
      {#each g.steps as s (s.id)}
        {@const on = stepEnabled(s)}
        {@const items = visibleItems(s)}
        <div class="card {on ? '' : 'opacity-60'}">
          <div class="flex items-start gap-3 px-4 py-3">
            <div class="pt-0.5"><Toggle checked={on} label="Enable {s.title ?? s.id}" onchange={(v) => setStep(s, v)} /></div>
            <button class="min-w-0 flex-1 text-left" onclick={() => (open[s.id] = !open[s.id])}>
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium text-ink-100">{s.title ?? s.id}</span>
                <RiskBadge risk={s.risk ?? 'safe'} />
                <span class="rounded bg-ink-800 px-1.5 py-px font-mono text-[10px] text-ink-300">{s.kind}</span>
                {#if overridden(s)}<span class="rounded bg-ember-500/15 px-1.5 py-px text-[10px] text-ember-300">overridden</span>{/if}
                {#if s._error}<span class="text-xs text-danger">{String(s._error)}</span>{/if}
              </div>
              {#if s.why}<div class="mt-0.5 text-sm text-ink-300">{s.why}</div>{/if}
              <div class="mt-1 flex gap-3 font-mono text-[11px] text-ink-500">
                <span>{s.id}</span>
                {#if Array.isArray(s._sources)}<span>from {(s._sources as string[]).join(' → ')}</span>{/if}
                {#if s.items?.length}<span>{s.items.length} items</span>{/if}
              </div>
            </button>
            {#if overridden(s)}
              <button class="btn-ghost px-2 text-xs" onclick={() => clearOverrides(s)} title="Remove your overrides for this step">Reset</button>
            {/if}
            {#if s.items?.length}
              <button class="btn-ghost px-2" onclick={() => (open[s.id] = !open[s.id])} aria-label="Expand">
                <Icon name={open[s.id] ? 'up' : 'down'} size={15} />
              </button>
            {/if}
          </div>
          {#if (open[s.id] || (q && items.length)) && s.items?.length}
            <div class="border-t border-ink-800 px-4 py-2">
              {#each items as it (itemKey(s.kind, it))}
                {@const ion = itemEnabled(s, it)}
                <div class="flex items-start gap-3 border-b border-ink-800/60 py-2 last:border-0">
                  <div class="pt-0.5"><Toggle checked={ion} disabled={!on} label={itemLabel(s.kind, it)} onchange={(v) => setItem(s, it, v)} /></div>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="font-mono text-[13px] break-all {ion ? 'text-ink-100' : 'text-ink-400 line-through'}">{itemLabel(s.kind, it)}</span>
                      {#if it.risk && it.risk !== 'safe'}<RiskBadge risk={it.risk} small />{/if}
                    </div>
                    {#if it.why}<div class="text-xs text-ink-400">{it.why}</div>{/if}
                  </div>
                </div>
              {/each}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  </section>
{:else}
  {#if !loading && !error}<div class="muted py-10 text-center">No steps match.</div>{/if}
{/each}
