<script lang="ts">
  let {
    checked = false,
    disabled = false,
    label = '',
    onchange,
  }: { checked?: boolean; disabled?: boolean; label?: string; onchange?: (v: boolean) => void } = $props();
</script>

<button
  type="button"
  role="switch"
  aria-checked={checked}
  aria-label={label}
  {disabled}
  class="relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors disabled:opacity-40 {checked ? 'bg-ember-500' : 'bg-ink-600'}"
  onclick={() => onchange?.(!checked)}
>
  <span class="inline-block h-3.5 w-3.5 rounded-full bg-ink-100 shadow transition-transform {checked ? 'translate-x-[18px]' : 'translate-x-[3px]'}"></span>
</button>
