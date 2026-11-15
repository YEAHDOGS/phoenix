<script lang="ts">
  import type { Snippet } from 'svelte';
  let { title, subtitle = '', actions }: { title: string; subtitle?: string; actions?: Snippet } = $props();
</script>

<header class="mb-6 flex items-end justify-between gap-4">
  <div class="min-w-0">
    <h1 class="h1">{title}</h1>
    {#if subtitle}<p class="muted mt-1 max-w-3xl text-sm">{subtitle}</p>{/if}
  </div>
  {#if actions}<div class="flex shrink-0 items-center gap-2">{@render actions()}</div>{/if}
</header>
