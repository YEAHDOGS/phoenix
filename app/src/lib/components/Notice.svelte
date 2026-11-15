<script lang="ts">
  import type { Snippet } from 'svelte';
  let { kind = 'info', title = '', children }: { kind?: 'info' | 'warn' | 'error' | 'ok'; title?: string; children?: Snippet } = $props();
  const cls: Record<string, string> = {
    info: 'border-info/30 bg-info/5',
    warn: 'border-caution/40 bg-caution/5',
    error: 'border-danger/40 bg-danger/5',
    ok: 'border-safe/30 bg-safe/5',
  };
  const dot: Record<string, string> = { info: 'bg-info', warn: 'bg-caution', error: 'bg-danger', ok: 'bg-safe' };
</script>

<div class="flex gap-3 rounded-lg border px-3 py-2.5 text-sm {cls[kind]}">
  <span class="mt-1.5 h-2 w-2 shrink-0 rounded-full {dot[kind]}"></span>
  <div class="min-w-0 text-ink-200">
    {#if title}<div class="font-medium text-ink-100">{title}</div>{/if}
    {@render children?.()}
  </div>
</div>
