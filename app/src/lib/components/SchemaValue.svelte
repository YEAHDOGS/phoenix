<script lang="ts">
  /**
   * One value of the answer-file DTO, rendered by its schema type.
   * Reads/writes `holder[key]` (holder is a deep $state object or array).
   */
  import { open as openDialog } from '@tauri-apps/plugin-dialog';
  import { backend, describeError, formatBytes } from '#lib/engine.ts';
  import { humanize, implLabel, initialValue, isLongText, newImpl, type Obj, type Param, type Schema } from '#lib/unattend.ts';
  import Toggle from './Toggle.svelte';
  import SearchSelect from './SearchSelect.svelte';
  import MultiPick from './MultiPick.svelte';
  import SchemaParams from './SchemaParams.svelte';
  import Self from './SchemaValue.svelte';
  import Icon from './Icon.svelte';

  let {
    schema,
    param,
    holder,
    key,
    depth = 0,
    onchange,
  }: { schema: Schema; param: Param; holder: Record<string | number, unknown>; key: string | number; depth?: number; onchange: () => void } = $props();

  const v = $derived(holder[key]);
  const t = $derived(schema.types[param.type]);
  const elemParam = $derived<Param>({ ...param, collection: null, nullable: false });

  function set(nv: unknown) {
    holder[key] = nv;
    onchange();
  }

  // ---- collections
  const arr = $derived(Array.isArray(v) ? (v as unknown[]) : []);
  const elemOptions = $derived.by(() => {
    if (t?.kind === 'enum') return t.values.map((x) => ({ id: x, label: humanize(x) }));
    if (t?.kind === 'keyed') return t.options;
    return null;
  });
  function ensureArray(): unknown[] {
    if (!Array.isArray(holder[key])) holder[key] = [];
    return holder[key] as unknown[];
  }
  function addRow() {
    ensureArray().push(param.keyType === 'ComponentAndPass' ? { component: '', pass: 'specialize', xml: '' } : initialValue(schema, param.type));
    onchange();
  }
  function removeRow(i: number) {
    ensureArray().splice(i, 1);
    onchange();
  }
  // Generic (non-component) dicts are kept as plain objects.
  const dictEntries = $derived(v && typeof v === 'object' && !Array.isArray(v) ? Object.entries(v as Obj) : []);
  let newDictKey = $state('');
  function addDictEntry() {
    const k = newDictKey.trim();
    if (!k) return;
    if (!v || typeof v !== 'object' || Array.isArray(v)) holder[key] = {};
    (holder[key] as Obj)[k] = initialValue(schema, param.type);
    newDictKey = '';
    onchange();
  }
  function removeDictEntry(k: string) {
    delete (holder[key] as Obj)[k];
    onchange();
  }
  const PASSES = ['windowsPE', 'offlineServicing', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem'];

  // ---- bytes
  let bytesError = $state<string | null>(null);
  async function pickBytes() {
    bytesError = null;
    const path = await openDialog({ multiple: false });
    if (!path || Array.isArray(path)) return;
    try {
      const r = await backend.readFileBase64(path);
      set(r.base64);
    } catch (e) {
      bytesError = describeError(e);
    }
  }
  const bytesSize = $derived(typeof v === 'string' && v ? Math.floor((v.length * 3) / 4) : 0);

  // ---- enum flags (comma-separated names, .NET style)
  const flagSet = $derived(new Set(typeof v === 'string' && v ? v.split(',').map((s) => s.trim()).filter(Boolean) : []));
  function toggleFlag(name: string) {
    const s = new Set(flagSet);
    if (s.has(name)) s.delete(name);
    else s.add(name);
    set([...s].join(', '));
  }

  // ---- unknown types: JSON fallback
  let jsonText = $state('');
  let jsonError = $state<string | null>(null);
  $effect(() => {
    if (!t && !['bool', 'int', 'string', 'bytes'].includes(param.type)) jsonText = JSON.stringify(v ?? null, null, 2);
  });
  function commitJson() {
    try {
      set(JSON.parse(jsonText));
      jsonError = null;
    } catch (e) {
      jsonError = String(e);
    }
  }
</script>

{#if param.collection === 'list' || param.collection === 'set'}
  {#if elemOptions}
    <MultiPick options={elemOptions} values={arr.map(String)} onchange={(next) => set(next)} />
  {:else}
    <div class="space-y-2">
      {#each arr as _, i (i)}
        <div class="flex items-start gap-2">
          <div class="min-w-0 flex-1 {t?.kind === 'record' || t?.kind === 'interface' ? 'rounded-lg border border-ink-700 p-3' : ''}">
            <Self {schema} param={elemParam} holder={arr as unknown as Record<number, unknown>} key={i} {depth} {onchange} />
          </div>
          <button type="button" class="btn-ghost px-2" onclick={() => removeRow(i)} aria-label="Remove"><Icon name="trash" size={14} /></button>
        </div>
      {/each}
      <button type="button" class="btn-outline h-8 text-xs" onclick={addRow}><Icon name="plus" size={14} /> Add</button>
    </div>
  {/if}
{:else if param.collection === 'dict'}
  {#if param.keyType === 'ComponentAndPass'}
    <div class="space-y-3">
      {#each arr as row, i (i)}
        {@const r = row as Obj}
        <div class="rounded-lg border border-ink-700 p-3">
          <div class="mb-2 flex gap-2">
            <input class="input flex-1 font-mono text-xs" placeholder="Component, e.g. Microsoft-Windows-Shell-Setup" value={String(r.component ?? '')} oninput={(e) => { r.component = e.currentTarget.value; onchange(); }} />
            <select class="input w-44 text-xs" value={String(r.pass ?? 'specialize')} onchange={(e) => { r.pass = e.currentTarget.value; onchange(); }}>
              {#each PASSES as ps}<option>{ps}</option>{/each}
            </select>
            <button type="button" class="btn-ghost px-2" onclick={() => removeRow(i)} aria-label="Remove component"><Icon name="trash" size={14} /></button>
          </div>
          <textarea class="input h-28 font-mono text-xs" placeholder="<settings XML for this component>" value={String(r.xml ?? '')} oninput={(e) => { r.xml = e.currentTarget.value; onchange(); }}></textarea>
        </div>
      {/each}
      <button type="button" class="btn-outline h-8 text-xs" onclick={addRow}><Icon name="plus" size={14} /> Add component</button>
    </div>
  {:else}
    <div class="space-y-2">
      {#each dictEntries as [k] (k)}
        <div class="flex items-start gap-2">
          <span class="w-40 shrink-0 truncate pt-1.5 font-mono text-xs text-ink-300">{k}</span>
          <div class="min-w-0 flex-1"><Self {schema} param={elemParam} holder={v as Obj} key={k} {depth} {onchange} /></div>
          <button type="button" class="btn-ghost px-2" onclick={() => removeDictEntry(k)} aria-label="Remove"><Icon name="trash" size={14} /></button>
        </div>
      {/each}
      <div class="flex gap-2">
        <input class="input h-8 w-56 text-xs" placeholder="New key" bind:value={newDictKey} />
        <button type="button" class="btn-outline h-8 text-xs" onclick={addDictEntry}><Icon name="plus" size={14} /> Add</button>
      </div>
    </div>
  {/if}
{:else if param.nullable && (v === null || v === undefined) && param.type !== 'bool'}
  <div class="flex items-center gap-3 rounded-md border border-dashed border-ink-600 px-3 py-1.5 text-sm text-ink-400">
    Not set (generator default)
    <button type="button" class="btn-ghost h-7 px-2 text-xs" onclick={() => set(initialValue(schema, param.type))}>Set</button>
  </div>
{:else if param.type === 'bool'}
  <div class="flex h-8 items-center gap-2">
    <Toggle checked={!!v} label={param.label ?? param.name} onchange={(x) => set(x)} />
    <span class="text-xs text-ink-400">{v ? 'On' : 'Off'}</span>
  </div>
{:else if param.type === 'int'}
  <input class="input font-mono" type="number" value={typeof v === 'number' ? v : ''} oninput={(e) => set(e.currentTarget.value === '' ? null : Number(e.currentTarget.value))} />
{:else if param.type === 'string'}
  {#if isLongText(param, v)}
    <textarea class="input h-32 font-mono text-xs" value={String(v ?? '')} oninput={(e) => set(e.currentTarget.value)}></textarea>
  {:else}
    <input class="input" value={String(v ?? '')} oninput={(e) => set(e.currentTarget.value)} />
  {/if}
{:else if param.type === 'bytes'}
  <div class="flex items-center gap-2">
    <button type="button" class="btn-outline h-8 text-xs" onclick={pickBytes}><Icon name="folder" size={14} /> Choose file…</button>
    {#if bytesSize}<span class="text-xs text-ink-300">{formatBytes(bytesSize)} embedded</span>
      <button type="button" class="btn-ghost h-8 px-2 text-xs" onclick={() => set(null)}>Clear</button>{:else}<span class="text-xs text-ink-500">none</span>{/if}
  </div>
  {#if bytesError}<p class="mt-1 text-xs text-danger">{bytesError}</p>{/if}
{:else if t?.kind === 'enum'}
  {#if t.flags}
    <div class="flex flex-wrap gap-x-4 gap-y-1">
      {#each t.values as name (name)}
        <label class="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={flagSet.has(name)} onchange={() => toggleFlag(name)} /> {humanize(name)}</label>
      {/each}
    </div>
  {:else}
    <select class="input" value={String(v ?? '')} onchange={(e) => set(e.currentTarget.value)}>
      {#each t.values as name (name)}<option value={name}>{humanize(name)}</option>{/each}
    </select>
  {/if}
{:else if t?.kind === 'keyed'}
  {#if t.options.length > 12}
    <SearchSelect options={t.options} value={v as string} onchange={(id) => set(id)} />
  {:else}
    <select class="input" value={String(v ?? '')} onchange={(e) => set(e.currentTarget.value)}>
      {#each t.options as o (o.id)}<option value={o.id}>{o.label ?? o.id}</option>{/each}
    </select>
  {/if}
{:else if t?.kind === 'record'}
  {#if v && typeof v === 'object'}
    <div class="rounded-lg border-l-2 border-ink-700 py-1 pl-4">
      <SchemaParams {schema} params={t.params} obj={v as Obj} {depth} {onchange} />
    </div>
  {:else}
    <button type="button" class="btn-outline h-8 text-xs" onclick={() => set(initialValue(schema, param.type))}>Configure</button>
  {/if}
{:else if t?.kind === 'interface'}
  {@const cur = v && typeof v === 'object' ? String((v as Obj).$type ?? '') : ''}
  {@const impl = cur ? schema.types[cur] : undefined}
  <div class="space-y-3">
    <div class="flex flex-wrap gap-1.5">
      {#each t.implementations as im (im)}
        <button
          type="button"
          class="rounded-md border px-2.5 py-1 text-xs transition-colors {cur === im
            ? 'border-ember-500 bg-ember-500/10 text-ember-200'
            : 'border-ink-600 text-ink-300 hover:border-ink-500 hover:text-ink-100'}"
          onclick={() => cur !== im && set(newImpl(schema, im))}
          title={im}
        >{implLabel(param.type, im)}</button>
      {/each}
      {#if param.nullable && cur}<button type="button" class="px-2 text-xs text-ink-500 hover:text-ink-200" onclick={() => set(null)}>none</button>{/if}
    </div>
    {#if impl?.kind === 'record' && impl.params.length}
      <div class="rounded-lg border-l-2 border-ember-500/30 py-1 pl-4">
        <SchemaParams {schema} params={impl.params} obj={v as Obj} {depth} {onchange} />
      </div>
    {/if}
  </div>
{:else}
  <textarea class="input h-24 font-mono text-xs" bind:value={jsonText} onblur={commitJson}></textarea>
  <p class="mt-1 text-xs text-ink-500">Unknown type <code>{param.type}</code>; edit as JSON.</p>
  {#if jsonError}<p class="text-xs text-danger">{jsonError}</p>{/if}
{/if}
