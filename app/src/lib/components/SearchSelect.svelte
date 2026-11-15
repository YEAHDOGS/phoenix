<script lang="ts">
  /** Single-select over a possibly long option list (locales, keyboards, time zones). */
  let {
    options,
    value,
    placeholder = 'Choose…',
    onchange,
  }: { options: { id: string; label?: string }[]; value: string | null | undefined; placeholder?: string; onchange: (id: string) => void } = $props();

  let open = $state(false);
  let q = $state('');
  let root = $state<HTMLDivElement | null>(null);
  let input = $state<HTMLInputElement | null>(null);

  const current = $derived(options.find((o) => o.id === value));
  const filtered = $derived.by(() => {
    const s = q.trim().toLowerCase();
    const list = s ? options.filter((o) => `${o.id} ${o.label ?? ''}`.toLowerCase().includes(s)) : options;
    return list.slice(0, 300);
  });

  function toggle() {
    open = !open;
    q = '';
    if (open) queueMicrotask(() => input?.focus());
  }
  function pick(id: string) {
    onchange(id);
    open = false;
  }
  function onwindowclick(e: MouseEvent) {
    if (open && root && !root.contains(e.target as Node)) open = false;
  }
  function onkeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') open = false;
    if (e.key === 'Enter' && filtered.length) {
      e.preventDefault();
      pick(filtered[0].id);
    }
  }
</script>

<svelte:window onclick={onwindowclick} />

<div class="relative" bind:this={root}>
  <button type="button" class="input flex items-center justify-between gap-2 text-left" onclick={toggle}>
    <span class="truncate {current || value ? '' : 'text-ink-500'}">
      {current ? (current.label ?? current.id) : value || placeholder}
      {#if current?.label && current.label !== current.id}<span class="ml-1 font-mono text-[11px] text-ink-500">{current.id}</span>{/if}
    </span>
    <span class="text-ink-400">▾</span>
  </button>
  {#if open}
    <div class="absolute z-40 mt-1 w-full min-w-64 rounded-lg border border-ink-600 bg-ink-850 shadow-2xl">
      <input bind:this={input} class="input rounded-b-none border-0 border-b" placeholder="Search {options.length} options…" bind:value={q} {onkeydown} />
      <ul class="max-h-72 overflow-y-auto py-1">
        {#each filtered as o (o.id)}
          <li>
            <button
              type="button"
              class="flex w-full items-center justify-between gap-3 px-3 py-1.5 text-left text-sm hover:bg-ink-700 {o.id === value ? 'text-ember-300' : 'text-ink-100'}"
              onclick={() => pick(o.id)}
            >
              <span class="truncate">{o.label ?? o.id}</span>
              <span class="shrink-0 font-mono text-[11px] text-ink-500">{o.id}</span>
            </button>
          </li>
        {:else}
          <li class="px-3 py-2 text-sm text-ink-500">No match</li>
        {/each}
        {#if filtered.length === 300}<li class="px-3 py-1 text-xs text-ink-500">Showing 300; keep typing to narrow.</li>{/if}
      </ul>
    </div>
  {/if}
</div>
