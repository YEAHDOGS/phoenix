<script lang="ts">
  import { app } from '$lib/app.svelte';
  import Icon from './Icon.svelte';

  let level = $state<'all' | 'info' | 'warn' | 'error'>('all');
  let runFilter = $state(0);
  let showChanges = $state(true);
  let follow = $state(true);
  let scroller = $state<HTMLDivElement | null>(null);

  const runIds = $derived([...new Set(app.logs.map((l) => l.runId))].slice(-30).reverse());
  const lines = $derived(
    app.logs
      .filter((l) => {
        if (runFilter && l.runId !== runFilter) return false;
        if (!showChanges && l.level === 'debug') return false;
        if (level === 'error') return l.level === 'error';
        if (level === 'warn') return l.level === 'warn' || l.level === 'error';
        if (level === 'info') return l.level !== 'debug';
        return true;
      })
      .slice(-1500),
  );

  $effect(() => {
    void lines.length;
    const el = scroller;
    if (follow && el && app.logOpen) queueMicrotask(() => (el.scrollTop = el.scrollHeight));
  });

  function toggle() {
    app.logOpen = !app.logOpen;
    if (app.logOpen) app.unseenErrors = 0;
  }

  async function copy() {
    const text = lines
      .map((l) => `${new Date(l.at).toLocaleTimeString()} #${l.runId} ${l.command} ${l.level.toUpperCase()} ${l.text}`)
      .join('\n');
    try {
      await navigator.clipboard.writeText(text);
      app.toast('ok', `Copied ${lines.length} lines`);
    } catch {
      app.toast('error', 'Clipboard unavailable');
    }
  }

  const color: Record<string, string> = { info: 'text-ink-200', warn: 'text-caution', error: 'text-danger', debug: 'text-ink-400' };
  const last = $derived(app.logs.length ? app.logs[app.logs.length - 1] : null);
</script>

<div class="shrink-0 border-t border-ink-800 bg-ink-900">
  <div class="flex h-9 items-center gap-3 px-3 text-xs">
    <button class="btn-ghost h-7 px-2 text-xs" onclick={toggle} aria-expanded={app.logOpen}>
      <Icon name="log" size={14} /> Log
      <span class="text-ink-400">({app.logs.length})</span>
      {#if app.unseenErrors > 0}<span class="rounded-full bg-danger px-1.5 text-[10px] text-ink-950">{app.unseenErrors}</span>{/if}
    </button>
    {#if app.logOpen}
      <select class="input h-7 w-32 py-0 text-xs" bind:value={level} aria-label="Level filter">
        <option value="all">All events</option>
        <option value="info">Info+</option>
        <option value="warn">Warnings+</option>
        <option value="error">Errors</option>
      </select>
      <select class="input h-7 w-48 py-0 text-xs" bind:value={runFilter} aria-label="Run filter">
        <option value={0}>All runs</option>
        {#each runIds as id (id)}
          <option value={id}>#{id} {app.runs[id]?.command ?? ''}{app.runs[id]?.elevated ? ' (admin)' : ''}</option>
        {/each}
      </select>
      <label class="flex items-center gap-1.5 text-ink-300"><input type="checkbox" bind:checked={showChanges} /> changes</label>
      <label class="flex items-center gap-1.5 text-ink-300"><input type="checkbox" bind:checked={follow} /> follow</label>
      <div class="ml-auto flex gap-1">
        <button class="btn-ghost h-7 px-2 text-xs" onclick={copy}><Icon name="copy" size={14} /> Copy</button>
        <button class="btn-ghost h-7 px-2 text-xs" onclick={() => app.clearLogs()}><Icon name="trash" size={14} /> Clear</button>
      </div>
    {:else if last}
      <span class="truncate font-mono {color[last.level]}">#{last.runId} {last.command} · {last.text}</span>
    {/if}
  </div>
  {#if app.logOpen}
    <div bind:this={scroller} class="h-64 overflow-y-auto border-t border-ink-800 bg-ink-950 px-3 py-2 font-mono text-[12px] leading-5">
      {#each lines as l (l.seq)}
        <div class="flex gap-2 whitespace-pre-wrap">
          <span class="shrink-0 text-ink-500">{new Date(l.at).toLocaleTimeString()}</span>
          <span class="shrink-0 text-ink-500">#{l.runId}</span>
          <span class="w-20 shrink-0 truncate text-ink-400">{l.command}</span>
          <span class="min-w-0 {color[l.level]}">{l.text}</span>
        </div>
      {:else}
        <div class="text-ink-500">No events yet.</div>
      {/each}
    </div>
  {/if}
</div>
