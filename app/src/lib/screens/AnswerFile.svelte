<script lang="ts">
  import { onMount } from 'svelte';
  import { save as saveDialog } from '@tauri-apps/plugin-dialog';
  import { app } from '#lib/app.svelte.ts';
  import { backend, call, describeError, unwrap, type EngineError } from '#lib/engine.ts';
  import type { Obj, Param, Schema } from '#lib/unattend.ts';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import Notice from '#lib/components/Notice.svelte';
  import Icon from '#lib/components/Icon.svelte';
  import Toggle from '#lib/components/Toggle.svelte';
  import Modal from '#lib/components/Modal.svelte';
  import SchemaParams from '#lib/components/SchemaParams.svelte';

  let schema = $state<Schema | null>(null);
  let defaults = $state<Obj | null>(null);
  let loading = $state(true);
  let notBuilt = $state<string | null>(null);
  let group = $state<string>('');
  let search = $state('');

  async function load() {
    loading = true;
    notBuilt = null;
    try {
      const [s, d] = await Promise.all([call<Schema>('unattend-schema'), call<Obj>('unattend-defaults')]);
      schema = unwrap<Schema>('unattend-schema', s);
      defaults = unwrap<Obj>('unattend-defaults', d);
      if (!app.config.unattend || typeof app.config.unattend !== 'object') app.config.unattend = structuredClone($state.snapshot(defaults) as Obj);
      if (!group) group = groups[0]?.id ?? '';
    } catch (e) {
      schema = null;
      notBuilt = describeError(e);
    }
    loading = false;
  }

  const rootParams = $derived.by<Param[]>(() => {
    if (!schema) return [];
    const r = schema.types[schema.root];
    return r?.kind === 'record' ? r.params : [];
  });
  const groups = $derived.by(() => {
    if (!schema) return [] as { id: string; label: string; params: string[] }[];
    const gs = (schema.groups ?? []).map((g) => ({ ...g, params: g.params.filter((p) => rootParams.some((rp) => rp.name === p)) }));
    const grouped = new Set(gs.flatMap((g) => g.params));
    const rest = rootParams.filter((p) => !grouped.has(p.name)).map((p) => p.name);
    if (rest.length) gs.push({ id: '__other', label: gs.length ? 'Other' : 'All settings', params: rest });
    return gs.filter((g) => g.params.length);
  });

  const q = $derived(search.trim().toLowerCase());
  const shownParams = $derived.by(() => {
    if (q) return rootParams.filter((p) => `${p.name} ${p.label ?? ''} ${p.help ?? ''}`.toLowerCase().includes(q));
    const g = groups.find((x) => x.id === group);
    return g ? rootParams.filter((p) => g.params.includes(p.name)) : [];
  });
  const currentGroup = $derived(groups.find((g) => g.id === group));
  const isAccountsGroup = $derived(/account|user|logon/i.test(`${currentGroup?.id} ${currentGroup?.label}`));

  const dto = $derived((app.config.unattend ?? {}) as Obj);
  const fromProfile = $derived(app.config.unattendAccountsFromProfile !== false);

  function changed() {
    app.markDirty();
  }
  function resetParams(names: string[]) {
    if (!defaults || !app.config.unattend) return;
    for (const n of names) {
      if (defaults[n] === undefined) delete app.config.unattend[n];
      else app.config.unattend[n] = structuredClone($state.snapshot(defaults[n]));
    }
    app.markDirty();
    app.toast('info', 'Reset to defaults');
  }

  // ---------------------------------------------------------------- generate
  let previewOpen = $state(false);
  let previewXml = $state('');
  let previewPath = $state<string | null>(null);
  let generating = $state(false);
  let genError = $state<string | null>(null);

  function placeholderSecrets() {
    const users: Record<string, string> = {};
    for (const u of app.config.accounts.users) users[u.name] = 'preview-only';
    return { admin: 'preview-only', lead: 'preview-only', users };
  }

  async function generate(secrets: { admin: string; lead: string; users: Record<string, string> }): Promise<string | null> {
    genError = null;
    if (!(await app.ensureSaved())) return null;
    let secretsPath: string | null = null;
    try {
      secretsPath = await backend.secretsWrite(secrets);
      const outPath = await backend.tmpFile('unattend', 'xml');
      const r = await call('unattend', { secretsPath, outPath });
      if (!r.ok) {
        genError = (r.data as EngineError)?.error ?? 'Generation failed';
        return null;
      }
      return outPath;
    } catch (e) {
      genError = describeError(e);
      return null;
    } finally {
      if (secretsPath) backend.secretsDiscard(secretsPath).catch(() => {});
    }
  }

  async function preview() {
    generating = true;
    previewOpen = true;
    previewXml = '';
    if (previewPath) backend.tmpDiscard(previewPath).catch(() => {});
    previewPath = await generate(placeholderSecrets());
    if (previewPath) {
      try {
        previewXml = await backend.tmpReadText(previewPath);
      } catch (e) {
        genError = describeError(e);
      }
    }
    generating = false;
  }

  async function savePreview() {
    if (!previewPath) return;
    const dest = await saveDialog({ defaultPath: 'autounattend.preview.xml', filters: [{ name: 'Answer file', extensions: ['xml'] }] });
    if (!dest) return;
    try {
      await backend.tmpSaveAs(previewPath, dest, true);
      app.toast('ok', 'Saved preview (placeholder passwords)');
    } catch (e) {
      app.toast('error', describeError(e));
    }
  }

  function closePreview() {
    previewOpen = false;
    if (previewPath) backend.tmpDiscard(previewPath).catch(() => {});
    previewPath = null;
  }

  // Real passwords -> save dialog. The file is written to tmp, copied, then deleted.
  let realOpen = $state(false);
  let pw = $state<Record<string, string>>({});
  const accounts = $derived([
    { key: 'admin', name: app.config.accounts.admin.name },
    { key: 'lead', name: app.config.accounts.lead.name },
    ...app.config.accounts.users.map((u) => ({ key: `user:${u.name}`, name: u.name })),
  ]);
  const realOk = $derived(accounts.every((a) => (pw[a.key] ?? '').length >= 8));

  async function saveReal() {
    const users: Record<string, string> = {};
    for (const u of app.config.accounts.users) users[u.name] = pw[`user:${u.name}`] ?? '';
    generating = true;
    const out = await generate({ admin: pw.admin ?? '', lead: pw.lead ?? '', users });
    pw = {};
    generating = false;
    if (!out) return;
    const dest = await saveDialog({ defaultPath: 'autounattend.xml', filters: [{ name: 'Answer file', extensions: ['xml'] }] });
    try {
      if (dest) {
        await backend.tmpSaveAs(out, dest, false);
        app.toast('ok', 'Answer file saved. It contains real passwords: keep it off shared drives.');
        realOpen = false;
      } else await backend.tmpDiscard(out);
    } catch (e) {
      app.toast('error', describeError(e));
    }
  }

  onMount(load);
</script>

<PageHeader
  title="Answer File"
  subtitle="Everything the Schneegans unattend generator can do, offline. Phoenix layers its accounts and the first-logon handoff on top."
>
  {#snippet actions()}
    {#if schema}
      <button class="btn-ghost" onclick={() => resetParams(rootParams.map((p) => p.name))}>Reset all</button>
      <button class="btn-outline" onclick={() => { pw = {}; realOpen = true; }}><Icon name="key" size={15} /> Save answer file…</button>
      <button class="btn-primary" onclick={preview}><Icon name="eye" size={15} /> Preview XML</button>
    {/if}
  {/snippet}
</PageHeader>

{#if loading}
  <div class="muted py-10 text-center">Loading the answer-file schema…</div>
{:else if notBuilt}
  <Notice kind="warn" title="Answer-file engine not built yet">
    The answer-file generator (<code class="kbd">phoenix-unattend.exe</code>) isn't available, so there are no options to show.
    Build it with <code class="kbd">app/unattend/build.ps1</code> (needs the .NET SDK), then reload this screen.
    <div class="mt-2 font-mono text-xs text-ink-400">{notBuilt}</div>
    <button class="btn-outline mt-3" onclick={load}><Icon name="refresh" size={15} /> Reload</button>
  </Notice>
{:else if schema}
  <div class="mb-5 card flex items-center gap-4 px-4 py-3">
    <Toggle
      checked={fromProfile}
      label="Accounts from Profile"
      onchange={(v) => { app.config.unattendAccountsFromProfile = v; app.markDirty(); }}
    />
    <div class="min-w-0 text-sm">
      <div class="font-medium text-ink-100">Accounts and first-logon handoff come from Profile</div>
      <div class="text-xs text-ink-400">
        {#if fromProfile}
          Admin <strong>{app.config.accounts.admin.name}</strong> (auto-logon once), lead <strong>{app.config.accounts.lead.name}</strong>{app.config.accounts.users.length ? ` and ${app.config.accounts.users.length} more` : ''}, plus the script that finds the Phoenix USB and runs the admin phase. Account settings below are ignored.
        {:else}
          Off: the account settings below are used as-is. The FirstLogon handoff script is still added.
        {/if}
      </div>
    </div>
  </div>

  <div class="grid grid-cols-[13rem_minmax(0,1fr)] gap-5">
    <aside class="space-y-3">
      <div class="relative">
        <span class="absolute top-2 left-2.5 text-ink-400"><Icon name="search" size={15} /></span>
        <input class="input pl-8" placeholder="Find a setting" bind:value={search} />
      </div>
      <ul class="space-y-0.5">
        {#each groups as g (g.id)}
          <li>
            <button
              class="w-full rounded-md px-2.5 py-1.5 text-left text-sm {group === g.id && !q ? 'bg-ink-800 text-ink-100' : 'text-ink-300 hover:bg-ink-800/60'}"
              onclick={() => { group = g.id; search = ''; }}
            >{g.label}<span class="float-right text-xs text-ink-500">{g.params.length}</span></button>
          </li>
        {/each}
      </ul>
    </aside>

    <section class="card min-w-0 p-5">
      <div class="mb-4 flex items-center justify-between">
        <h2 class="h2">{q ? `Matches for “${search}”` : (currentGroup?.label ?? '')}</h2>
        {#if !q && currentGroup}
          <button class="btn-ghost h-8 px-2 text-xs" onclick={() => resetParams(currentGroup.params)}><Icon name="refresh" size={14} /> Reset section to defaults</button>
        {/if}
      </div>
      {#if isAccountsGroup && fromProfile && !q}
        <div class="mb-4"><Notice kind="info">Accounts come from <button class="underline" onclick={() => app.go('profile')}>Profile</button> while the toggle above is on.</Notice></div>
      {/if}
      {#if shownParams.length}
        <SchemaParams {schema} params={shownParams} obj={dto} onchange={changed} />
      {:else}
        <div class="muted text-sm">{q ? 'No settings match.' : 'Nothing in this section.'}</div>
      {/if}
      {#if q}<p class="mt-4 text-xs text-ink-500">Search covers top-level settings; nested options are inside their section.</p>{/if}
    </section>
  </div>
{/if}

<Modal bind:open={previewOpen} title="autounattend.xml preview" wide onclose={closePreview}>
  {#if generating}
    <div class="flex items-center gap-3 py-6 text-ink-300"><span class="h-4 w-4 animate-spin rounded-full border-2 border-ink-600 border-t-ember-400"></span> Generating…</div>
  {:else if genError}
    <Notice kind="error" title="Generation failed">{genError}</Notice>
  {:else}
    <div class="mb-3"><Notice kind="info">Preview only: every password is <code class="kbd">preview-only</code>. Build the USB (or "Save answer file…") to use real ones.</Notice></div>
    <pre class="max-h-[55vh] overflow-auto rounded-lg border border-ink-700 bg-ink-950 p-3 font-mono text-[11.5px] leading-[1.45] text-ink-200">{previewXml}</pre>
  {/if}
  {#snippet actions()}
    <button class="btn-ghost" onclick={() => navigator.clipboard.writeText(previewXml).then(() => app.toast('ok', 'Copied'))} disabled={!previewXml}>
      <Icon name="copy" size={15} /> Copy
    </button>
    <button class="btn-outline" onclick={savePreview} disabled={!previewPath || !!genError}><Icon name="save" size={15} /> Save preview…</button>
    <button class="btn-primary" onclick={closePreview}>Close</button>
  {/snippet}
</Modal>

<Modal bind:open={realOpen} title="Save answer file with real passwords">
  <p class="mb-3 text-sm text-ink-300">
    For using the answer file outside the Phoenix USB builder. The saved file <strong>contains these passwords</strong>
    (base64, not encrypted). They aren't stored anywhere else.
  </p>
  <div class="space-y-2">
    {#each accounts as a (a.key)}
      <div class="grid grid-cols-[9rem_minmax(0,1fr)] items-center gap-2">
        <span class="truncate text-sm text-ink-200">{a.name || '(unnamed)'}</span>
        <input class="input" type="password" autocomplete="new-password" placeholder="At least 8 characters" bind:value={pw[a.key]} />
      </div>
    {/each}
  </div>
  {#if genError}<div class="mt-3"><Notice kind="error">{genError}</Notice></div>{/if}
  {#snippet actions()}
    <button class="btn-ghost" onclick={() => { pw = {}; realOpen = false; }}>Cancel</button>
    <button class="btn-primary" disabled={!realOk || generating} onclick={saveReal}>Generate and save…</button>
  {/snippet}
</Modal>
