<script lang="ts">
  import { onMount } from 'svelte';
  import { open as openDialog } from '@tauri-apps/plugin-dialog';
  import { app } from '#lib/app.svelte.ts';
  import {
    backend, call, describeError, formatBytes, run, unwrap,
    type EngineError, type Run,
  } from '#lib/engine.ts';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import Notice from '#lib/components/Notice.svelte';
  import Icon from '#lib/components/Icon.svelte';
  import Modal from '#lib/components/Modal.svelte';

  interface Volume { letter: string; label: string | null; fileSystem: string | null; sizeBytes: number; freeBytes: number; hasPhoenix?: boolean; hasVentoy?: boolean }
  interface Disk {
    number: number; model?: string; busType?: string; sizeBytes: number; letter: string | null; label: string | null;
    fileSystem: string | null; volumes?: Volume[]; isBoot?: boolean; isSystem?: boolean; readOnly?: boolean | null;
  }
  interface Item {
    id: string; name?: string; category?: string; description?: string; kind?: string; source?: string;
    userFile?: boolean; optional?: boolean; homepage?: string; license?: string; cached?: boolean;
    file?: string | null; version?: string | null; sha512?: string | null; sizeBytes?: number | null;
    fetchedAt?: string | null; signature?: string | null;
  }

  // ---------------------------------------------------------------- drives
  let disks = $state<Disk[]>([]);
  let drivesError = $state<string | null>(null);
  let loadingDrives = $state(false);
  let target = $state<string>(''); // volume letter, e.g. "E:"

  async function loadDrives() {
    loadingDrives = true;
    try {
      const r = unwrap<Disk[]>('drives', await call('drives'));
      disks = Array.isArray(r) ? r : [];
      drivesError = null;
      const letters = disks.flatMap((d) => (d.volumes ?? []).map((v) => v.letter));
      if (target && !letters.includes(target)) target = '';
    } catch (e) {
      drivesError = describeError(e);
    }
    loadingDrives = false;
  }

  const volumeChoices = $derived(
    disks.flatMap((d) => (d.volumes?.length ? d.volumes : d.letter ? [{ letter: d.letter, label: d.label, fileSystem: d.fileSystem, sizeBytes: d.sizeBytes, freeBytes: 0 } as Volume] : []).map((v) => ({ disk: d, vol: v }))),
  );
  const chosen = $derived(volumeChoices.find((c) => c.vol.letter === target) ?? null);
  const blocked = (d: Disk) => !!(d.isBoot || d.isSystem || d.readOnly);

  // ---------------------------------------------------------------- loadout
  let items = $state<Item[]>([]);
  let cacheRoot = $state<string | null>(null);
  let loadoutError = $state<string | null>(null);
  let fetching = $state(false);
  let fetchStatus = $state<Record<string, string>>({});
  let fetchPct = $state<Record<string, number>>({});
  let fetchRun: Run | null = null;

  async function loadLoadout() {
    try {
      const r = unwrap<{ cacheRoot: string; items: Item[] } | Item[]>('loadout', await call('loadout'));
      items = Array.isArray(r) ? r : (r.items ?? []);
      cacheRoot = Array.isArray(r) ? null : r.cacheRoot;
      loadoutError = null;
    } catch (e) {
      loadoutError = describeError(e);
    }
  }

  const selected = $derived(new Set(app.config.loadout));
  function toggleItem(id: string) {
    app.config.loadout = selected.has(id) ? app.config.loadout.filter((x) => x !== id) : [...app.config.loadout, id];
    app.markDirty();
  }
  const categories = $derived([...new Set(items.map((i) => i.category ?? 'Other'))]);
  const missing = $derived(items.filter((i) => selected.has(i.id) && !i.cached && !i.userFile));
  const missingUser = $derived(items.filter((i) => selected.has(i.id) && !i.cached && i.userFile && !i.optional));
  const selectedBytes = $derived(items.filter((i) => selected.has(i.id)).reduce((n, i) => n + (i.sizeBytes ?? 0), 0));

  async function fetchItems(ids: string[], files: Record<string, string> = {}, force = false) {
    if (!ids.length) return;
    fetching = true;
    for (const id of ids) { fetchStatus[id] = 'queued'; fetchPct[id] = 0; }
    try {
      fetchRun = await run('fetch', { items: ids, files, force }, {
        onEvent: (e) => {
          const id = 'step' in e && typeof e.step === 'string' && e.step.startsWith('fetch.') ? e.step.slice(6) : null;
          if (!id) return;
          if (e.t === 'step') fetchStatus[id] = e.status === 'start' ? 'downloading' : e.status === 'ok' ? 'done' : e.status === 'skip' ? 'cached' : 'failed';
          if (e.t === 'progress') fetchPct[id] = e.pct;
        },
      });
      const r = await fetchRun.done;
      if (!r.ok) app.toast('error', `Fetch failed: ${(r.data as EngineError)?.error}`);
      else {
        const d = r.data as { failed?: number };
        app.toast(d?.failed ? 'warn' : 'ok', d?.failed ? `${d.failed} item(s) failed — see the log` : 'Loadout fetched and verified');
      }
    } catch (e) {
      app.toast('error', describeError(e));
    }
    fetching = false;
    fetchRun = null;
    await loadLoadout();
  }

  async function pickUserFile(it: Item) {
    const path = await openDialog({ multiple: false, title: `Pick ${it.name ?? it.id}` });
    if (!path || Array.isArray(path)) return;
    if (!selected.has(it.id)) toggleItem(it.id);
    await fetchItems([it.id], { [it.id]: path });
  }

  // ---------------------------------------------------------------- passwords
  const accounts = $derived([
    { key: 'admin', name: app.config.accounts.admin.name, role: 'Administrator' },
    { key: 'lead', name: app.config.accounts.lead.name, role: 'Lead user' },
    ...app.config.accounts.users.map((u) => ({ key: `user:${u.name}`, name: u.name, role: 'Standard user' })),
  ]);
  let pw = $state<Record<string, { a: string; b: string }>>({});
  $effect(() => {
    for (const a of accounts) if (!pw[a.key]) pw[a.key] = { a: '', b: '' };
  });
  const pwIssues = $derived(
    accounts.map((a) => {
      const p = pw[a.key];
      if (!p || !p.a) return 'Required';
      if (p.a !== p.b) return "Doesn't match";
      if (p.a.length < 8) return 'Use at least 8 characters';
      return null;
    }),
  );
  const passwordsOk = $derived(pwIssues.every((x) => !x));
  function clearPasswords() {
    for (const k of Object.keys(pw)) pw[k] = { a: '', b: '' };
  }

  // ---------------------------------------------------------------- build
  let confirmOpen = $state(false);
  let typed = $state('');
  let building = $state(false);
  let buildSteps = $state<{ step: string; status: string; msg?: string }[]>([]);
  let buildPct = $state(0);
  let buildResult = $state<Record<string, unknown> | null>(null);
  let buildError = $state<string | null>(null);
  let verifyResult = $state<{ ok: boolean; checked: number; problems: { path: string; problem: string }[] } | null>(null);
  let verifying = $state(false);

  const canBuild = $derived(!!chosen && !blocked(chosen.disk) && passwordsOk && !building && !fetching);
  const letterOnly = $derived(target.replace(':', '').toUpperCase());

  function openConfirm() {
    typed = '';
    confirmOpen = true;
  }

  async function build() {
    confirmOpen = false;
    if (!(await app.ensureSaved())) return;
    building = true;
    buildSteps = [];
    buildPct = 0;
    buildResult = null;
    buildError = null;
    verifyResult = null;
    const users: Record<string, string> = {};
    for (const u of app.config.accounts.users) users[u.name] = pw[`user:${u.name}`]?.a ?? '';
    let secretsPath: string | null = null;
    try {
      secretsPath = await backend.secretsWrite({ admin: pw.admin.a, lead: pw.lead.a, users });
      const r = await (await run('usb-build', { secretsPath, driveLetter: target, items: app.config.loadout }, {
        onEvent: (e) => {
          if (e.t === 'step') {
            const i = buildSteps.findIndex((s) => s.step === e.step);
            const row = { step: e.step, status: e.status, msg: e.msg };
            if (i >= 0) buildSteps[i] = row;
            else buildSteps.push(row);
          } else if (e.t === 'progress') buildPct = e.pct;
        },
      })).done;
      if (r.ok) {
        buildResult = r.data as Record<string, unknown>;
        clearPasswords();
        app.toast('ok', 'Phoenix USB built');
        await verify();
      } else buildError = (r.data as EngineError)?.error ?? 'Build failed';
    } catch (e) {
      buildError = describeError(e);
    } finally {
      // The engine deletes the secrets file after reading; this covers failures before that.
      if (secretsPath) backend.secretsDiscard(secretsPath).catch(() => {});
    }
    building = false;
    loadDrives();
  }

  async function verify() {
    if (!target) return;
    verifying = true;
    try {
      const r = unwrap<{ ok: boolean; checked: number; problems: { path: string; problem: string }[] }>('usb-verify', await call('usb-verify', { driveLetter: target }));
      verifyResult = r;
    } catch (e) {
      app.toast('error', `Verify: ${describeError(e)}`);
    }
    verifying = false;
  }

  const statusColor: Record<string, string> = {
    done: 'text-safe', ok: 'text-safe', cached: 'text-safe', downloading: 'text-ember-300', start: 'text-ember-300',
    queued: 'text-ink-400', failed: 'text-danger', fail: 'text-danger', skip: 'text-ink-400',
  };

  onMount(() => {
    loadDrives();
    loadLoadout();
  });
</script>

<PageHeader
  title="USB"
  subtitle="Build the Phoenix USB: answer file, engine, packs, config and a verified software loadout. Your Windows 11 USB stays stock."
/>

<div class="mb-5">
  <Notice kind="info" title="How the two USBs work together">
    Windows Setup looks for <code class="kbd">autounattend.xml</code> at the root of every removable drive, so it picks the
    answer file up from the Phoenix USB. At first logon the Phoenix scripts find <code class="kbd">\phoenix\phoenix.id</code>, copy
    the kit to the machine, and run the admin phase. Phoenix never formats the drive; it writes alongside what's there (Ventoy is fine).
  </Notice>
</div>

<div class="grid grid-cols-2 gap-5">
  <!-- Drive -->
  <section class="card p-5">
    <div class="mb-3 flex items-center justify-between">
      <h2 class="h2 flex items-center gap-2"><span class="text-ember-400">1</span> Target drive</h2>
      <button class="btn-ghost px-2" onclick={loadDrives} disabled={loadingDrives}><Icon name="refresh" size={15} /> Refresh</button>
    </div>
    {#if drivesError}<Notice kind="error" title="Couldn't list drives">{drivesError}</Notice>{/if}
    {#if !drivesError && !volumeChoices.length}
      <div class="rounded-lg border border-dashed border-ink-600 px-4 py-6 text-center text-sm text-ink-400">
        {loadingDrives ? 'Looking for USB drives…' : 'No USB drive found. Plug one in and refresh.'}
      </div>
    {/if}
    <div class="space-y-2">
      {#each volumeChoices as { disk, vol } (vol.letter)}
        {@const off = blocked(disk)}
        <label
          class="flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-2.5 {target === vol.letter
            ? 'border-ember-500 bg-ember-500/5'
            : 'border-ink-700 hover:border-ink-600'} {off ? 'cursor-not-allowed opacity-50' : ''}"
        >
          <input type="radio" name="drive" value={vol.letter} bind:group={target} disabled={off} />
          <Icon name="usb" size={18} />
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="font-mono font-semibold">{vol.letter}</span>
              <span class="truncate">{vol.label || 'Untitled'}</span>
              {#if vol.hasPhoenix}<span class="rounded bg-ember-500/15 px-1.5 text-[10px] text-ember-300">PHOENIX</span>{/if}
              {#if vol.hasVentoy}<span class="rounded bg-info/15 px-1.5 text-[10px] text-info">VENTOY</span>{/if}
            </div>
            <div class="truncate text-xs text-ink-400">
              {disk.model ?? 'USB disk'} · disk {disk.number} · {vol.fileSystem ?? '?'} · {formatBytes(vol.sizeBytes)}{vol.freeBytes ? ` (${formatBytes(vol.freeBytes)} free)` : ''}
            </div>
            {#if off}<div class="text-xs text-danger">{disk.isSystem ? 'System disk' : disk.isBoot ? 'Boot disk' : 'Read-only'}: not selectable</div>{/if}
          </div>
        </label>
      {/each}
    </div>
    {#if chosen?.vol.fileSystem === 'FAT32'}
      <div class="mt-3"><Notice kind="warn">FAT32 can't hold files over 4 GB (e.g. a Windows ISO). Fine for everything else.</Notice></div>
    {/if}
  </section>

  <!-- Passwords -->
  <section class="card p-5">
    <h2 class="h2 mb-1 flex items-center gap-2"><span class="text-ember-400">2</span> Passwords</h2>
    <p class="muted mb-3 text-xs">
      Used once, written only into <code class="kbd">autounattend.xml</code> on the USB (Windows requires it; it's obfuscated, not encrypted).
      Never saved by the app. Change them after install.
    </p>
    <div class="space-y-3">
      {#each accounts as a, i (a.key)}
        {#if pw[a.key]}
          <div>
            <div class="mb-1 flex items-center justify-between text-xs">
              <span class="text-ink-200"><Icon name="key" size={12} /> {a.name || '(unnamed)'} <span class="text-ink-500">· {a.role}</span></span>
              {#if pw[a.key].a && pwIssues[i]}<span class="text-danger">{pwIssues[i]}</span>{:else if !pwIssues[i]}<span class="text-safe">ok</span>{/if}
            </div>
            <div class="grid grid-cols-2 gap-2">
              <input class="input" type="password" autocomplete="new-password" placeholder="Password" bind:value={pw[a.key].a} />
              <input class="input" type="password" autocomplete="new-password" placeholder="Confirm" bind:value={pw[a.key].b} />
            </div>
          </div>
        {/if}
      {/each}
    </div>
  </section>

  <!-- Loadout -->
  <section class="card col-span-2 p-5">
    <div class="mb-3 flex items-end justify-between gap-3">
      <div>
        <h2 class="h2 flex items-center gap-2"><span class="text-ember-400">3</span> Loadout</h2>
        <p class="muted mt-1 text-xs">
          Downloaded on this PC, hashed (SHA-512) and signature-checked, then copied to the USB so the target never needs the internet until the last phase.
          {#if cacheRoot}Cache: <button class="underline" onclick={() => backend.openPath(cacheRoot!)}>{cacheRoot}</button>{/if}
        </p>
      </div>
      <div class="flex items-center gap-2">
        <span class="text-xs text-ink-400">{app.config.loadout.length} selected · {formatBytes(selectedBytes)} cached</span>
        {#if fetching}
          <button class="btn-outline" onclick={() => fetchRun?.cancel()}><Icon name="x" size={15} /> Stop</button>
        {:else}
          <button class="btn-primary" disabled={!missing.length} onclick={() => fetchItems(missing.map((m) => m.id))}>
            <Icon name="download" size={15} /> Fetch {missing.length || ''} missing
          </button>
        {/if}
      </div>
    </div>
    {#if loadoutError}<Notice kind="error" title="Loadout">{loadoutError}</Notice>{/if}
    {#each categories as cat (cat)}
      <h3 class="mt-4 mb-2 text-xs font-semibold tracking-wider text-ink-400 uppercase">{cat}</h3>
      <div class="divide-y divide-ink-800 rounded-lg border border-ink-700">
        {#each items.filter((i) => (i.category ?? 'Other') === cat) as it (it.id)}
          {@const on = selected.has(it.id)}
          {@const st = fetchStatus[it.id]}
          <div class="flex items-center gap-3 px-3 py-2.5">
            <input type="checkbox" checked={on} onchange={() => toggleItem(it.id)} aria-label="Include {it.name}" />
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium">{it.name ?? it.id}</span>
                <span class="font-mono text-[11px] text-ink-500">{it.id}</span>
                {#if it.optional}<span class="text-[10px] text-ink-400 uppercase">optional</span>{/if}
                {#if it.license}<span class="text-[11px] text-ink-500">{it.license}</span>{/if}
              </div>
              {#if it.description}<div class="text-xs text-ink-400">{it.description}</div>{/if}
            </div>
            <div class="w-56 shrink-0 text-right text-xs">
              {#if st && st !== 'done' && st !== 'cached'}
                <span class={statusColor[st]}>{st}{fetchPct[it.id] ? ` ${fetchPct[it.id]}%` : ''}</span>
              {:else if it.cached}
                <span class="text-safe">✓ cached</span>
                <span class="text-ink-400">{it.version ? `v${it.version} · ` : ''}{formatBytes(it.sizeBytes)}</span>
                {#if it.signature}<div class="truncate text-[11px] {it.signature === 'Valid' ? 'text-safe' : 'text-caution'}" title={it.sha512 ?? ''}>sig: {it.signature}</div>{/if}
              {:else}
                <span class="text-ink-500">not cached</span>
              {/if}
            </div>
            <div class="flex shrink-0 gap-1">
              {#if it.userFile}
                <button class="btn-outline px-2 text-xs" disabled={fetching} onclick={() => pickUserFile(it)}><Icon name="folder" size={14} /> Pick file</button>
              {:else}
                <button class="btn-ghost px-2 text-xs" disabled={fetching} onclick={() => fetchItems([it.id], {}, !!it.cached)} title={it.cached ? 'Re-download' : 'Download'}>
                  <Icon name={it.cached ? 'refresh' : 'download'} size={14} />
                </button>
              {/if}
              {#if it.homepage}<button class="btn-ghost px-2" onclick={() => backend.openUrl(it.homepage!)} title="Homepage"><Icon name="external" size={14} /></button>{/if}
            </div>
          </div>
        {/each}
      </div>
    {/each}
    {#if missingUser.length}
      <div class="mt-3"><Notice kind="warn">Pick files for: {missingUser.map((m) => m.name ?? m.id).join(', ')}.</Notice></div>
    {/if}
  </section>

  <!-- Build -->
  <section class="card col-span-2 p-5">
    <div class="flex items-center justify-between gap-4">
      <div>
        <h2 class="h2 flex items-center gap-2"><span class="text-ember-400">4</span> Build</h2>
        <p class="muted mt-1 text-xs">
          Writes <code class="kbd">autounattend.xml</code> and <code class="kbd">\phoenix\</code> to {target || 'the drive'}, then a
          <code class="kbd">SHA512SUMS</code> you can re-check any time.
        </p>
      </div>
      <div class="flex gap-2">
        <button class="btn-outline" disabled={!target || verifying || building} onclick={verify}><Icon name="shield" size={15} /> Verify</button>
        <button class="btn-primary" disabled={!canBuild} onclick={openConfirm}><Icon name="usb" size={15} /> Build Phoenix USB</button>
      </div>
    </div>
    {#if !canBuild && !building}
      <ul class="mt-3 space-y-0.5 text-xs text-ink-400">
        {#if !chosen}<li>• Pick a target drive</li>{/if}
        {#if !passwordsOk}<li>• Enter and confirm every password</li>{/if}
        {#if missing.length}<li>• {missing.length} loadout item(s) not fetched yet (the build will skip them)</li>{/if}
      </ul>
    {/if}
    {#if building || buildSteps.length}
      <div class="mt-4 space-y-2">
        <div class="h-1.5 overflow-hidden rounded-full bg-ink-800"><div class="h-full bg-ember-500 transition-all" style="width: {building ? Math.max(3, buildPct) : 100}%"></div></div>
        <div class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs">
          {#each buildSteps as s (s.step)}
            <div class="flex justify-between gap-2"><span class="font-mono text-ink-300">{s.step}</span><span class={statusColor[s.status] ?? 'text-ink-300'}>{s.status}{s.msg ? ` · ${s.msg}` : ''}</span></div>
          {/each}
        </div>
      </div>
    {/if}
    {#if buildError}<div class="mt-3"><Notice kind="error" title="Build failed">{buildError}</Notice></div>{/if}
    {#if buildResult}
      <div class="mt-3"><Notice kind="ok" title="Built">
        {buildResult.fileCount} files written to {buildResult.root}.
        {#if Array.isArray(buildResult.missingItems) && buildResult.missingItems.length}Skipped (not cached): {(buildResult.missingItems as string[]).join(', ')}.{/if}
      </Notice></div>
    {/if}
    {#if verifyResult}
      <div class="mt-3">
        {#if verifyResult.ok}
          <Notice kind="ok" title="Verified">{verifyResult.checked} files match SHA512SUMS.</Notice>
        {:else}
          <Notice kind="error" title="Verification failed">
            {verifyResult.problems.length} problem(s):
            {#each verifyResult.problems.slice(0, 8) as p}<div class="font-mono text-xs">{p.problem}: {p.path}</div>{/each}
          </Notice>
        {/if}
      </div>
    {/if}
  </section>
</div>

<Modal bind:open={confirmOpen} title="Write to {target}?">
  <p class="text-sm text-ink-200">
    Phoenix will write <code class="kbd">autounattend.xml</code> and the <code class="kbd">phoenix</code> folder to
    <strong>{target}</strong> ({chosen?.vol.label || 'Untitled'}, {formatBytes(chosen?.vol.sizeBytes)}). Existing Phoenix files there are replaced;
    nothing else is deleted.
  </p>
  <div class="mt-3"><Notice kind="warn">Any PC that boots Windows Setup with this USB plugged in will <strong>wipe disk {app.config.machine.diskNumber}</strong> without asking. Label it.</Notice></div>
  <label class="label mt-4" for="typed">Type the drive letter ({letterOnly}) to confirm</label>
  <input id="typed" class="input w-24 font-mono uppercase" maxlength="2" bind:value={typed} />
  {#snippet actions()}
    <button class="btn-ghost" onclick={() => (confirmOpen = false)}>Cancel</button>
    <button class="btn-primary" disabled={typed.replace(':', '').toUpperCase() !== letterOnly} onclick={build}>Build</button>
  {/snippet}
</Modal>
