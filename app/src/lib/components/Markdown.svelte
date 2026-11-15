<script lang="ts">
  import { renderMarkdown } from '$lib/md';
  import { backend } from '$lib/engine';
  let { source = '' }: { source?: string | null } = $props();
  const html = $derived(renderMarkdown(source));

  // Links are rendered as <a data-href>; open them in the system browser.
  function onclick(e: MouseEvent) {
    const a = (e.target as HTMLElement).closest('a[data-href]');
    if (a) {
      e.preventDefault();
      backend.openUrl(a.getAttribute('data-href') ?? '').catch(() => {});
    }
  }
</script>

<!-- renderMarkdown escapes all input and emits a fixed tag set. -->
<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="md" {onclick}>{@html html}</div>
