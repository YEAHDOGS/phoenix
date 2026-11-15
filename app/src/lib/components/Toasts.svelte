<script lang="ts">
  import { app } from '#lib/app.svelte.ts';
  const cls: Record<string, string> = {
    ok: 'border-safe/40', warn: 'border-caution/50', error: 'border-danger/50', info: 'border-ink-600',
  };
</script>

<div class="pointer-events-none fixed right-4 bottom-14 z-[60] flex w-80 flex-col gap-2">
  {#each app.toasts as t (t.id)}
    <div class="pointer-events-auto rounded-lg border bg-ink-850 px-3 py-2 text-sm text-ink-100 shadow-xl {cls[t.kind]}">{t.text}</div>
  {/each}
</div>
