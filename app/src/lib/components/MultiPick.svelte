<script lang="ts">
  /** Checkbox grid with search for set/list-of-enum params (e.g. Bloatware). */
  let {
    options,
    values,
    onchange,
  }: { options: { id: string; label?: string }[]; values: string[]; onchange: (next: string[]) => void } = $props();

  let q = $state('');
  const set = $derived(new Set(values));
  const filtered = $derived.by(() => {
    const s = q.trim().toLowerCase();
    return s ? options.filter((o) => `${o.id} ${o.label ?? ''}`.toLowerCase().includes(s)) : options;
  });

  function toggle(id: string) {
    onchange(set.has(id) ? values.filter((v) => v !== id) : [...values, id]);
  }
  function selectShown(on: boolean) {
    const ids = new Set(filtered.map((o) => o.id));
    onchange(on ? [...new Set([...values, ...ids])] : values.filter((v) => !ids.has(v)));
  }
</script>

<div class="rounded-lg border border-ink-700 bg-ink-950/40 p-3">
  <div class="mb-2 flex items-center gap-2">
    <input class="input h-8 flex-1 py-1 text-xs" placeholder="Search {options.length}…" bind:value={q} />
    <span class="text-xs text-ink-400">{values.length} selected</span>
    <button type="button" class="btn-ghost h-8 px-2 text-xs" onclick={() => selectShown(true)}>All{q ? ' shown' : ''}</button>
    <button type="button" class="btn-ghost h-8 px-2 text-xs" onclick={() => selectShown(false)}>None{q ? ' shown' : ''}</button>
  </div>
  <div class="grid max-h-72 grid-cols-3 gap-x-3 gap-y-1 overflow-y-auto">
    {#each filtered as o (o.id)}
      <label class="flex min-w-0 cursor-pointer items-center gap-2 rounded px-1.5 py-1 text-sm hover:bg-ink-800" title={o.id}>
        <input type="checkbox" checked={set.has(o.id)} onchange={() => toggle(o.id)} />
        <span class="truncate {set.has(o.id) ? 'text-ink-100' : 'text-ink-300'}">{o.label ?? o.id}</span>
      </label>
    {/each}
  </div>
</div>
