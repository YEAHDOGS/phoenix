<script lang="ts">
  import { onMount } from 'svelte';
  import { app, fmt } from '#lib/app.svelte.ts';
  import { run, type ChangeEvent, type EngineError, type Run, type StepEvent } from '#lib/engine.ts';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import Notice from '#lib/components/Notice.svelte';
  import Icon from '#lib/components/Icon.svelte';

  // ------------------------------------------------ scan
  let scan = $state<Record<string, unknown> | null>(null);
  let scanning = $state(false);
  let scanError = $state<string | null>(null);
  let openList = $state<string | null>(null);

  async function doScan() {
    scanning = true;
    scanError = null;
    try {
      const r = await (await run<Record<string, unknown>>('scan')).done;
      if (r.ok) scan = r.data as Record<string, unknown>;
      else scanError = (r.data as EngineError)?.error ?? 'Scan failed';
    } catch (e) {
      scanError = String(e);
    }
    scanning = false;
  }

  const scalarKeys = $derived(scan ? Object.keys(scan).filter((k) => !Array.isArray(scan![k]) && (typeof scan![k] !== 'object' || scan![k] === null)) : []);
  const objectKeys = $derived(scan ? Object.keys(scan).filter((k) => scan![k] && typeof scan![k] === 'object' && !Array.isArray(scan![k])) : []);
  const listKeys = $derived(scan ? Object.keys(scan).filter((k) => Array.isArray(scan![k])) : []);
  const pretty = (k: string) => k.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, (c) => c.toUpperCase());

  function rows(k: string): Record<string, unknown>[] {
    const v = scan?.[k];
    if (!Array.isArray(v)) return [];
    return v.map((x) => (x && typeof x === 'object' ? (x as Record<string, unknown>) : { value: x }));
  }
  function cols(rs: Record<string, unknown>[]): string[] {
    const s = new Set<string>();
    for (const r of rs.slice(0, 50)) for (const c of Object.keys(r)) s.add(c);
    return [...s].slice(0, 6);
  }

  // ------------------------------------------------ plan
  let phase = $state(app.planPhase || '');
  let planning = $state(false);
  let planError = $state<string | null>(null);
  let changes = $state<ChangeEvent[]>([]);
  let stepEvents = $state<Record<string, StepEvent>>({});
  let showSkips = $state(false);
  let filter = $state('');
  let planned = $state(false);
  let current: Run | null = null;

  async function doPlan() {
    planning = true;
    planError = null;
    changes = [];
    stepEvents = {};
    planned = false;
    if (!(await app.ensureSaved())) { planning = false; return; }
    const ch: ChangeEvent[] = [];
    const st: Record<string, StepEvent> = {};
    try {
      current = await run('plan', phase ? { phase } : {}, {
        onEvent: (e) => {
          if (e.t === 'change') ch.push(e);
          else if (e.t === 'step') st[e.step] = e;
        },
      });
      const r = await current.done;
      changes = ch;
      stepEvents = st;
      if (!r.ok) planError = (r.data as EngineError)?.error ?? 'Plan failed';
      planned = true;
    } catch (e) {
      planError = String(e);
    }
    planning = false;
    current = null;
  }

  const fl = $derived(filter.trim().toLowerCase());
  const shown = $derived(
    changes.filter((c) => (showSkips || c.action !== 'skip') && (!fl || `${c.step} ${c.key} ${fmt(c.current)} ${fmt(c.target)} ${c.msg ?? ''}`.toLowerCase().includes(fl))),
  );
  const grouped = $derived.by(() => {
    const m = new Map<string, ChangeEvent[]>();
    for (const c of shown) {
      if (!m.has(c.step)) m.set(c.step, []);
      m.get(c.step)!.push(c);
    }
    return [...m.entries()];
  });
  const totals = $derived({
    changes: changes.filter((c) => c.action !== 'skip').length,
    skips: changes.filter((c) => c.action === 'skip').length,
    steps: new Set(changes.filter((c) => c.action !== 'skip').map((c) => c.step)).size,
    failed: Object.values(stepEvents).filter((s) => s.status === 'fail').length,
  });
  const actionColor: Record<string, string> = {
    set: 'text-ember-300', disable: 'text-caution', remove: 'text-danger', enable: 'text-safe', add: 'text-safe', skip: 'text-ink-500',
  };

  onMount(() => {
    if (app.planAutoRun) {
      app.planAutoRun = false;
      doPlan();
    }
  });
</script>

<PageHeader title="Scan & Plan" subtitle="See what's on this machine and exactly what your profile would change. Both are read-only: nothing is modified here." />

<div class="grid grid-cols-1 gap-6">
  <section class="card p-5">
    <div class="mb-4 flex items-center justify-between">
      <div>
        <h2 class="h2 flex items-center gap-2"><Icon name="chip" size={16} /> Machine scan</h2>
        <p class="muted mt-1 text-xs">Hardware, devices (including hidden), services, features, apps and startup entries. Use it to tune a hardware pack.</p>
      </div>
      <button class="btn-outline" disabled={scanning} onclick={doScan}>
        {#if scanning}<span class="h-3.5 w-3.5 animate-spin rounded-full border-2 border-ink-600 border-t-ember-400"></span> Scanning…{:else}<Icon name="search" size={15} /> Scan this machine{/if}
      </button>
    </div>
    {#if scanError}<Notice kind="error" title="Scan failed">{scanError}</Notice>{/if}
    {#if scan}
      <div class="grid grid-cols-3 gap-3">
        {#each scalarKeys as k (k)}
          <div class="rounded-lg border border-ink-700 bg-ink-850 px-3 py-2">
            <div class="label">{pretty(k)}</div>
            <div class="truncate text-sm text-ink-100" title={fmt(scan[k])}>{fmt(scan[k])}</div>
          </div>
        {/each}
        {#each objectKeys as k (k)}
          <div class="rounded-lg border border-ink-700 bg-ink-850 px-3 py-2">
            <div class="label">{pretty(k)}</div>
            {#each Object.entries(scan[k] as Record<string, unknown>).slice(0, 6) as [kk, vv] (kk)}
              <div class="flex justify-between gap-2 text-xs"><span class="text-ink-400">{kk}</span><span class="truncate text-ink-200">{fmt(vv)}</span></div>
            {/each}
          </div>
        {/each}
      </div>
      <div class="mt-4 flex flex-wrap gap-2">
        {#each listKeys as k (k)}
          <button class="btn-outline text-xs {openList === k ? 'border-ember-500' : ''}" onclick={() => (openList = openList === k ? null : k)}>
            {pretty(k)} <span class="text-ink-400">{(scan[k] as unknown[]).length}</span>
          </button>
        {/each}
      </div>
      {#if openList}
        {@const rs = rows(openList)}
        {@const cs = cols(rs)}
        <div class="mt-3 max-h-96 overflow-auto rounded-lg border border-ink-700">
          <table class="w-full text-left text-xs">
            <thead class="sticky top-0 bg-ink-850 text-ink-300">
              <tr>{#each cs as c}<th class="px-3 py-2 font-medium">{c}</th>{/each}</tr>
            </thead>
            <tbody>
              {#each rs as r, i (i)}
                <tr class="border-t border-ink-800">{#each cs as c}<td class="max-w-80 truncate px-3 py-1.5 font-mono text-ink-200" title={fmt(r[c])}>{fmt(r[c])}</td>{/each}</tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    {:else if !scanning && !scanError}
      <div class="muted text-sm">Not scanned yet.</div>
    {/if}
  </section>

  <section class="card p-5">
    <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
      <div>
        <h2 class="h2 flex items-center gap-2"><Icon name="plan" size={16} /> Plan</h2>
        <p class="muted mt-1 text-xs">Runs your resolved profile in audit mode against this machine: current value → target value for every item.</p>
      </div>
      <div class="flex items-center gap-2">
        <select class="input w-44" bind:value={phase}>
          <option value="">All phases</option>
          <option value="admin">admin</option>
          <option value="admin-post">admin-post</option>
          <option value="user-offline">user-offline</option>
          <option value="user-online">user-online</option>
        </select>
        {#if planning}
          <button class="btn-outline" onclick={() => current?.cancel()}><Icon name="x" size={15} /> Stop</button>
        {:else}
          <button class="btn-primary" onclick={doPlan}><Icon name="eye" size={15} /> Run plan</button>
        {/if}
      </div>
    </div>

    <Notice kind="info">Read-only. Plan never changes the system; running a phase happens from the Runbook, with your approval.</Notice>

    {#if planning}
      <div class="mt-4 flex items-center gap-3 text-sm text-ink-300">
        <span class="h-4 w-4 animate-spin rounded-full border-2 border-ink-600 border-t-ember-400"></span> Planning… ({changes.length} so far — open the log for live output)
      </div>
    {/if}
    {#if planError}<div class="mt-4"><Notice kind="error" title="Plan failed">{planError}</Notice></div>{/if}

    {#if planned}
      <div class="mt-5 flex items-end gap-8">
        <div><div class="text-3xl font-semibold text-ember-300">{totals.changes}</div><div class="muted text-xs">changes</div></div>
        <div><div class="text-3xl font-semibold text-ink-200">{totals.steps}</div><div class="muted text-xs">steps affected</div></div>
        <div><div class="text-3xl font-semibold text-ink-400">{totals.skips}</div><div class="muted text-xs">already done / not present</div></div>
        {#if totals.failed}<div><div class="text-3xl font-semibold text-danger">{totals.failed}</div><div class="muted text-xs">steps errored</div></div>{/if}
        <div class="ml-auto flex items-center gap-3">
          <input class="input w-64" placeholder="Filter" bind:value={filter} />
          <label class="flex items-center gap-1.5 text-xs text-ink-300"><input type="checkbox" bind:checked={showSkips} /> show skips</label>
        </div>
      </div>

      <div class="mt-4 space-y-3">
        {#each grouped as [step, list] (step)}
          {@const se = stepEvents[step]}
          <div class="rounded-lg border border-ink-700">
            <div class="flex items-center justify-between border-b border-ink-800 bg-ink-850 px-3 py-2">
              <span class="font-mono text-sm text-ink-100">{step}</span>
              <span class="text-xs {se?.status === 'fail' ? 'text-danger' : 'text-ink-400'}">{list.length} {se?.status === 'fail' ? `· failed: ${se.msg}` : ''}</span>
            </div>
            <div class="divide-y divide-ink-800">
              {#each list as c, i (i)}
                <div class="grid grid-cols-[7rem_minmax(0,1.3fr)_minmax(0,1fr)_minmax(0,1fr)] gap-3 px-3 py-1.5 text-xs">
                  <span class="font-medium uppercase {actionColor[c.action] ?? 'text-ink-200'}">{c.action}</span>
                  <span class="truncate font-mono text-ink-100" title={c.key}>{c.key}</span>
                  <span class="truncate font-mono text-ink-400" title={fmt(c.current)}>{fmt(c.current)}</span>
                  <span class="truncate font-mono text-ink-200" title={fmt(c.target) + (c.msg ? ` — ${c.msg}` : '')}>→ {fmt(c.target)}{c.msg ? ` · ${c.msg}` : ''}</span>
                </div>
              {/each}
            </div>
          </div>
        {:else}
          <div class="muted text-sm">{changes.length ? 'Only skips. Tick "show skips" to see them.' : 'No changes: this machine already matches.'}</div>
        {/each}
      </div>
    {/if}
  </section>
</div>
