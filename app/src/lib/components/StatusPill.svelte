<script lang="ts">
  let { status = 'pending' }: { status?: string } = $props();
  const map: Record<string, [string, string]> = {
    done: ['Done', 'bg-safe/15 text-safe'],
    ok: ['Done', 'bg-safe/15 text-safe'],
    skipped: ['Skipped', 'bg-ink-700 text-ink-300'],
    skip: ['Skipped', 'bg-ink-700 text-ink-300'],
    running: ['Running', 'bg-ember-500/15 text-ember-300'],
    failed: ['Failed', 'bg-danger/15 text-danger'],
    fail: ['Failed', 'bg-danger/15 text-danger'],
    pending: ['To do', 'bg-ink-800 text-ink-300'],
  };
  const v = $derived(map[status] ?? [status, 'bg-ink-800 text-ink-300']);
</script>

<span class="rounded-full px-2 py-0.5 text-[11px] font-medium {v[1]}">{v[0]}</span>
