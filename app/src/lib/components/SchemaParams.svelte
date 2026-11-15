<script lang="ts">
  /** Renders a record's params as a form. Mutates `obj` in place (it's deep $state). */
  import { humanize, type Obj, type Param, type Schema } from '$lib/unattend';
  import SchemaValue from './SchemaValue.svelte';

  let {
    schema,
    params,
    obj,
    depth = 0,
    onchange,
  }: { schema: Schema; params: Param[]; obj: Obj; depth?: number; onchange: () => void } = $props();

  // Simple fields go in a two-column grid; nested records/interfaces/collections get full width.
  function isSimple(p: Param): boolean {
    if (p.collection) return false;
    if (['bool', 'int'].includes(p.type)) return true;
    if (p.type === 'string') return !/script|xml|content|command|json|code/i.test(p.name);
    const t = schema.types[p.type];
    return t?.kind === 'enum' || t?.kind === 'keyed';
  }
  const visible = $derived(params.filter((p) => p.name !== '$type'));
</script>

<div class="grid grid-cols-2 gap-x-5 gap-y-4">
  {#each visible as p (p.name)}
    <div class={isSimple(p) ? '' : 'col-span-2'}>
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span class="label mb-0">{p.label ?? humanize(p.name)}</span>
        {#if p.nullable && obj[p.name] !== null && obj[p.name] !== undefined && p.type !== 'bool'}
          <button type="button" class="text-[11px] text-ink-500 hover:text-ink-200" onclick={() => { obj[p.name] = null; onchange(); }}>unset</button>
        {/if}
      </div>
      <SchemaValue {schema} param={p} holder={obj} key={p.name} depth={depth + 1} {onchange} />
      {#if p.help}<p class="mt-1 text-xs text-ink-500">{p.help}</p>{/if}
    </div>
  {/each}
</div>
