<script lang="ts">
  import { logLines } from '../store.svelte';

  const LEVEL_CLASS: Record<string, string> = {
    info: 'text-slate-300',
    warn: 'text-amber-300',
    error: 'text-red-400',
    success: 'text-emerald-400',
    stdout: 'text-slate-200',
    stderr: 'text-orange-300',
  };

  let box: HTMLDivElement | null = $state(null);

  $effect(() => {
    // Autoscroll on new lines (tracks logLines length reactively).
    void logLines.length;
    if (box) box.scrollTop = box.scrollHeight;
  });
</script>

<div class="flex h-56 flex-col rounded-lg bg-slate-900 p-3">
  <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-400">
    Build log <span class="normal-case text-slate-500">(passwords are never written here)</span>
  </div>
  <div bind:this={box} class="flex-1 overflow-y-auto font-mono text-xs leading-5">
    {#each logLines as l}
      <div class={LEVEL_CLASS[l.level] ?? 'text-slate-300'}>
        <span class="text-slate-500">[{l.t}]</span>
        {l.text}
      </div>
    {/each}
    {#if logLines.length === 0}
      <div class="text-slate-500">No output yet.</div>
    {/if}
  </div>
</div>
