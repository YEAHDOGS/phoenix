<script lang="ts">
  import type { Snippet } from 'svelte';
  let {
    open = $bindable(false),
    title = '',
    wide = false,
    children,
    actions,
    onclose,
  }: { open?: boolean; title?: string; wide?: boolean; children?: Snippet; actions?: Snippet; onclose?: () => void } = $props();

  function close() {
    open = false;
    onclose?.();
  }
  function onkeydown(e: KeyboardEvent) {
    if (open && e.key === 'Escape') close();
  }
</script>

<svelte:window {onkeydown} />

{#if open}
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-6 backdrop-blur-[2px]">
    <div class="card flex max-h-[85vh] w-full flex-col shadow-2xl {wide ? 'max-w-3xl' : 'max-w-lg'}" role="dialog" aria-modal="true" aria-label={title}>
      <div class="flex items-center justify-between border-b border-ink-700 px-5 py-3">
        <h2 class="h2">{title}</h2>
        <button class="btn-ghost px-2" onclick={close} aria-label="Close">✕</button>
      </div>
      <div class="overflow-y-auto px-5 py-4">{@render children?.()}</div>
      {#if actions}
        <div class="flex justify-end gap-2 border-t border-ink-700 px-5 py-3">{@render actions()}</div>
      {/if}
    </div>
  </div>
{/if}
