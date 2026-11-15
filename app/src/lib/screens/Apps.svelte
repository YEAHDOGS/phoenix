<script lang="ts">
  import { onMount } from 'svelte';
  import { app } from '$lib/app.svelte';
  import { backend, call, describeError, type CatalogEntry, type ChocoResult, type EngineError } from '$lib/engine';
  import PageHeader from '$lib/components/PageHeader.svelte';
  import Notice from '$lib/components/Notice.svelte';
  import Icon from '$lib/components/Icon.svelte';

  interface Entry { id: string; name: string; category: string; description: string; isDefault: boolean }

  let catalog = $state<Entry[]>([]);
  let catalogSource = $state<string | null>(null);
  let catalogError = $state<string | null>(null);
  let query = $state('');
  let category = $state('');

  let remote = $state<ChocoResult[]>([]);
  let searching = $state(false);
  let remoteError = $state<string | null>(null);
  let remoteQuery = $state('');

  const norm = (e: CatalogEntry): Entry | null => {
    const id = (e.id ?? e.package ?? '').trim();
    if (!id) return null;
    return {
      id: id.toLowerCase(),
      name: e.name ?? e.title ?? e.package ?? id,
      category: e.category ?? 'Other',
      description: e.description ?? '',
      isDefault: !!(e.default ?? e.defaultSelected),
    };
  };

  async function loadCatalog() {
    try {
      const r = await backend.catalogLoad();
      catalog = r.apps.map(norm).filter((x): x is Entry => !!x);
      catalogSource = r.source;
      catalogError = null;
    } catch (e) {
      catalogError = describeError(e);
    }
  }

  const selected = $derived(new Set(app.config.apps.map((a) => a.toLowerCase())));
  const categories = $derived([...new Set(catalog.map((c) => c.category))].sort());
  const q = $derived(query.trim().toLowerCase());
  const filtered = $derived(
    catalog.filter((c) => (!category || c.category === category) && (!q || `${c.id} ${c.name} ${c.description}`.toLowerCase().includes(q))),
  );
  const byCategory = $derived.by(() => {
    const m = new Map<string, Entry[]>();
    for (const c of filtered) {
      if (!m.has(c.category)) m.set(c.category, []);
      m.get(c.category)!.push(c);
    }
    return [...m.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  });

  function toggle(id: string) {
    const lid = id.toLowerCase();
    if (selected.has(lid)) app.config.apps = app.config.apps.filter((a) => a.toLowerCase() !== lid);
    else app.config.apps = [...app.config.apps, lid];
    app.markDirty();
  }
  function addDefaults() {
    const add = catalog.filter((c) => c.isDefault && !selected.has(c.id)).map((c) => c.id);
    app.config.apps = [...app.config.apps, ...add];
    app.markDirty();
    app.toast('info', `Added ${add.length} default apps`);
  }
  function clearAll() {
    app.config.apps = [];
    app.markDirty();
  }

  async function searchChoco() {
    const term = (query.trim() || remoteQuery).trim();
    if (!term) return;
    searching = true;
    remoteError = null;
    remoteQuery = term;
    try {
      const r = await call<ChocoResult[] | { results: ChocoResult[] }>('choco-search', { query: term });
      if (r.ok) {
        const d = r.data as ChocoResult[] | { results: ChocoResult[] };
        remote = Array.isArray(d) ? d : (d?.results ?? []);
      } else {
        remoteError = (r.data as EngineError)?.error ?? 'Search failed';
        remote = [];
      }
    } catch (e) {
      remoteError = describeError(e);
    }
    searching = false;
  }

  const nameOf = (id: string) => catalog.find((c) => c.id === id.toLowerCase())?.name ?? remote.find((r) => r.id.toLowerCase() === id.toLowerCase())?.title ?? id;

  onMount(loadCatalog);
</script>

<PageHeader
  title="Apps"
  subtitle="Chocolatey packages installed in the last phase, as the lead user, once the Wi-Fi card is back in. Phoenix installs Chocolatey itself from the USB."
>
  {#snippet actions()}
    <button class="btn-ghost" onclick={addDefaults} disabled={!catalog.length}>Add defaults</button>
    {#if app.dirty}<button class="btn-primary" onclick={() => app.saveConfig()}><Icon name="save" size={15} /> Save</button>{/if}
  {/snippet}
</PageHeader>

<div class="grid grid-cols-[minmax(0,1fr)_20rem] gap-5">
  <div class="min-w-0">
    <div class="mb-4 flex gap-2">
      <div class="relative flex-1">
        <span class="absolute top-2 left-2.5 text-ink-400"><Icon name="search" size={15} /></span>
        <input
          class="input pl-8"
          placeholder="Filter the catalog… press Enter to search Chocolatey"
          bind:value={query}
          onkeydown={(e) => e.key === 'Enter' && searchChoco()}
        />
      </div>
      <select class="input w-44" bind:value={category}>
        <option value="">All categories</option>
        {#each categories as c}<option>{c}</option>{/each}
      </select>
      <button class="btn-outline" disabled={searching || !query.trim()} onclick={searchChoco}>
        {#if searching}<span class="h-3.5 w-3.5 animate-spin rounded-full border-2 border-ink-600 border-t-ember-400"></span>{:else}<Icon name="search" size={15} />{/if}
        Search Chocolatey
      </button>
    </div>

    {#if remoteQuery}
      <section class="card mb-5 p-4">
        <div class="mb-2 flex items-center justify-between">
          <h2 class="h2">Chocolatey results for “{remoteQuery}”</h2>
          <button class="btn-ghost px-2 text-xs" onclick={() => { remote = []; remoteQuery = ''; remoteError = null; }}>Close</button>
        </div>
        {#if remoteError}<Notice kind="error" title="Search failed">{remoteError} (needs internet on this PC)</Notice>{/if}
        {#if !remoteError && !searching && !remote.length}<div class="muted text-sm">No packages found.</div>{/if}
        <div class="divide-y divide-ink-800">
          {#each remote as r (r.id)}
            <div class="flex items-center gap-3 py-2">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="font-medium">{r.title ?? r.id}</span>
                  <span class="font-mono text-xs text-ink-400">{r.id}</span>
                  {#if r.version}<span class="text-xs text-ink-500">v{r.version}</span>{/if}
                </div>
                {#if r.summary}<div class="truncate text-xs text-ink-400">{r.summary}</div>{/if}
              </div>
              {#if r.downloads}<span class="text-xs text-ink-500">{Intl.NumberFormat('en', { notation: 'compact' }).format(r.downloads)}↓</span>{/if}
              <button class={selected.has(r.id.toLowerCase()) ? 'btn-outline' : 'btn-primary'} onclick={() => toggle(r.id)}>
                {selected.has(r.id.toLowerCase()) ? 'Remove' : 'Add'}
              </button>
            </div>
          {/each}
        </div>
      </section>
    {/if}

    {#if catalogError}<Notice kind="error" title="Catalog">{catalogError}</Notice>{/if}
    {#if !catalog.length && !catalogError}<div class="muted text-sm">No local catalog found. Use Chocolatey search.</div>{/if}

    {#each byCategory as [cat, list] (cat)}
      <section class="mb-5">
        <h2 class="mb-2 text-xs font-semibold tracking-wider text-ink-400 uppercase">{cat}</h2>
        <div class="grid grid-cols-2 gap-2">
          {#each list as c (c.id)}
            {@const on = selected.has(c.id)}
            <button
              class="flex items-start gap-3 rounded-lg border px-3 py-2.5 text-left transition-colors {on
                ? 'border-ember-500/50 bg-ember-500/5'
                : 'border-ink-700 bg-ink-900 hover:border-ink-600'}"
              onclick={() => toggle(c.id)}
            >
              <span class="mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded border {on ? 'border-ember-500 bg-ember-500 text-ink-950' : 'border-ink-500'}">
                {#if on}<Icon name="check" size={12} />{/if}
              </span>
              <span class="min-w-0">
                <span class="block truncate text-sm font-medium text-ink-100">{c.name}</span>
                <span class="block truncate font-mono text-[11px] text-ink-500">{c.id}</span>
                {#if c.description}<span class="mt-0.5 block text-xs text-ink-400">{c.description}</span>{/if}
              </span>
            </button>
          {/each}
        </div>
      </section>
    {/each}
    {#if catalogSource}<div class="text-xs text-ink-500">Catalog: {catalogSource}</div>{/if}
  </div>

  <aside class="card sticky top-0 h-fit p-4">
    <div class="mb-3 flex items-center justify-between">
      <h2 class="h2">Selected <span class="text-ink-400">{app.config.apps.length}</span></h2>
      <button class="btn-ghost px-2 text-xs" disabled={!app.config.apps.length} onclick={clearAll}>Clear</button>
    </div>
    <ul class="max-h-[60vh] space-y-1 overflow-y-auto">
      {#each app.config.apps as id (id)}
        <li class="flex items-center justify-between gap-2 rounded px-2 py-1 hover:bg-ink-800">
          <span class="min-w-0">
            <span class="block truncate text-sm">{nameOf(id)}</span>
            <span class="block truncate font-mono text-[11px] text-ink-500">{id}</span>
          </span>
          <button class="btn-ghost px-1.5" onclick={() => toggle(id)} aria-label="Remove {id}"><Icon name="x" size={14} /></button>
        </li>
      {:else}
        <li class="muted text-sm">Nothing selected yet.</li>
      {/each}
    </ul>
    <p class="mt-4 text-xs text-ink-500">
      Installed with <code class="kbd">choco install</code> inside a time-boxed firewall window that closes automatically.
    </p>
  </aside>
</div>
