<script lang="ts">
  import type { Risk } from '#lib/engine.ts';
  let { risk = 'safe', small = false }: { risk?: Risk | string; small?: boolean } = $props();
  const cls: Record<string, string> = {
    safe: 'text-safe border-safe/40 bg-safe/10',
    caution: 'text-caution border-caution/40 bg-caution/10',
    danger: 'text-danger border-danger/50 bg-danger/10',
  };
</script>

<span
  class="inline-flex items-center rounded border font-medium uppercase tracking-wider {small ? 'px-1 text-[9px]' : 'px-1.5 py-px text-[10px]'} {cls[risk] ?? cls.safe}"
  title={risk === 'danger' ? 'Can break boot, networking or apps. Off unless you turn it on.' : risk === 'caution' ? 'Usually fine; can affect some hardware or apps.' : 'Low risk.'}
>{risk}</span>
