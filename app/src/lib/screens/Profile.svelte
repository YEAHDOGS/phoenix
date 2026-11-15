<script lang="ts">
  import { app } from '#lib/app.svelte.ts';
  import PageHeader from '#lib/components/PageHeader.svelte';
  import Notice from '#lib/components/Notice.svelte';
  import Icon from '#lib/components/Icon.svelte';

  const TIMEZONES = [
    'Pacific Standard Time', 'Mountain Standard Time', 'US Mountain Standard Time', 'Central Standard Time',
    'Eastern Standard Time', 'Alaskan Standard Time', 'Hawaiian Standard Time', 'Atlantic Standard Time',
    'Newfoundland Standard Time', 'SA Pacific Standard Time', 'E. South America Standard Time', 'UTC',
    'GMT Standard Time', 'W. Europe Standard Time', 'Central Europe Standard Time', 'Romance Standard Time',
    'E. Europe Standard Time', 'FLE Standard Time', 'Russian Standard Time', 'Arabian Standard Time',
    'India Standard Time', 'SE Asia Standard Time', 'China Standard Time', 'Tokyo Standard Time',
    'Korea Standard Time', 'AUS Eastern Standard Time', 'New Zealand Standard Time',
  ];
  const EDITIONS = ['Windows 11 Pro', 'Windows 11 Home', 'Windows 11 Education', 'Windows 11 Enterprise', 'Windows 11 Pro for Workstations'];

  const c = $derived(app.config);
  const tzOptions = $derived(TIMEZONES.includes(c.machine.timeZone) ? TIMEZONES : [c.machine.timeZone, ...TIMEZONES]);

  // Windows local account rules: 1-20 chars, none of "/\[]:;|=,+*?<>@, not only dots/spaces.
  function accountError(name: string, others: string[]): string | null {
    if (!name.trim()) return 'Required';
    if (name.length > 20) return 'Max 20 characters';
    if (/["/\\[\]:;|=,+*?<>@]/.test(name)) return 'Contains a character Windows does not allow';
    if (/^[.\s]+$/.test(name)) return 'Cannot be only dots or spaces';
    if (['administrator', 'guest', 'defaultaccount', 'wdagutilityaccount'].includes(name.toLowerCase())) return 'Reserved by Windows';
    if (others.some((o) => o.toLowerCase() === name.toLowerCase())) return 'Duplicate name';
    return null;
  }
  function computerNameError(n: string): string | null {
    if (!n) return 'Required';
    if (n.length > 15) return 'Max 15 characters (NetBIOS)';
    if (!/^[A-Za-z0-9-]+$/.test(n)) return 'Letters, digits and hyphens only';
    if (/^\d+$/.test(n)) return 'Cannot be all digits';
    return null;
  }

  const allNames = $derived([c.accounts.admin.name, c.accounts.lead.name, ...c.accounts.users.map((u) => u.name)]);
  const others = (i: number) => allNames.filter((_, j) => j !== i);
  const errors = $derived({
    computer: computerNameError(c.machine.computerName),
    admin: accountError(c.accounts.admin.name, others(0)),
    lead: accountError(c.accounts.lead.name, others(1)),
    users: c.accounts.users.map((u, i) => accountError(u.name, others(i + 2))),
  });
  const hasErrors = $derived(!!(errors.computer || errors.admin || errors.lead || errors.users.some(Boolean)));

  const dirty = () => app.markDirty();

  function addUser() {
    c.accounts.users.push({ name: '' });
    dirty();
  }
  function removeUser(i: number) {
    c.accounts.users.splice(i, 1);
    dirty();
  }

  const available = $derived(app.packs.filter((p) => !c.packs.includes(p.id)));
  const packInfo = (id: string) => app.packs.find((p) => p.id === id);
  let toAdd = $state('');

  function addPack() {
    if (toAdd && !c.packs.includes(toAdd)) {
      c.packs.push(toAdd);
      toAdd = '';
      dirty();
    }
  }
  function movePack(i: number, d: -1 | 1) {
    const j = i + d;
    if (j < 0 || j >= c.packs.length) return;
    [c.packs[i], c.packs[j]] = [c.packs[j], c.packs[i]];
    dirty();
  }
  function removePack(i: number) {
    c.packs.splice(i, 1);
    dirty();
  }

  async function save() {
    if (hasErrors) {
      app.toast('warn', 'Fix the highlighted fields first');
      return;
    }
    await app.saveConfig();
  }
</script>

<PageHeader title="Profile" subtitle="Who this machine is, who uses it, and which packs shape it. Passwords are never stored here: you type them when you build the USB.">
  {#snippet actions()}
    <button class="btn-ghost" onclick={() => app.loadConfig()} disabled={!app.dirty}>Revert</button>
    <button class="btn-primary" onclick={save} disabled={!app.dirty}><Icon name="save" size={15} /> Save</button>
  {/snippet}
</PageHeader>

{#if app.configError}
  <div class="mb-4"><Notice kind="warn" title="Using defaults">{app.configError}</Notice></div>
{:else if !app.isUserConfig}
  <div class="mb-4"><Notice kind="info">Showing the example config. Saving writes your own copy to <code class="kbd">%APPDATA%\Phoenix</code>.</Notice></div>
{/if}

<div class="grid grid-cols-2 gap-5">
  <section class="card p-5">
    <h2 class="h2 mb-4 flex items-center gap-2"><Icon name="chip" size={16} /> Machine</h2>
    <div class="grid grid-cols-2 gap-4">
      <div>
        <label class="label" for="cn">Computer name</label>
        <input id="cn" class="input font-mono {errors.computer ? 'border-danger' : ''}" bind:value={c.machine.computerName} oninput={dirty} maxlength="15" />
        {#if errors.computer}<p class="mt-1 text-xs text-danger">{errors.computer}</p>{/if}
      </div>
      <div>
        <label class="label" for="ed">Edition</label>
        <select id="ed" class="input" bind:value={c.machine.edition} onchange={dirty}>
          {#each EDITIONS.includes(c.machine.edition) ? EDITIONS : [c.machine.edition, ...EDITIONS] as e}<option>{e}</option>{/each}
        </select>
      </div>
      <div class="col-span-2">
        <label class="label" for="tz">Time zone</label>
        <select id="tz" class="input" bind:value={c.machine.timeZone} onchange={dirty}>
          {#each tzOptions as tz}<option>{tz}</option>{/each}
        </select>
      </div>
      <div>
        <label class="label" for="ui">UI language</label>
        <input id="ui" class="input font-mono" bind:value={c.machine.uiLanguage} oninput={dirty} />
      </div>
      <div>
        <label class="label" for="kb">Keyboard (input locale)</label>
        <input id="kb" class="input font-mono" bind:value={c.machine.inputLocale} oninput={dirty} />
      </div>
      <div>
        <label class="label" for="sl">System locale</label>
        <input id="sl" class="input font-mono" bind:value={c.machine.systemLocale} oninput={dirty} />
      </div>
      <div>
        <label class="label" for="ul">User locale</label>
        <input id="ul" class="input font-mono" bind:value={c.machine.userLocale} oninput={dirty} />
      </div>
      <div>
        <label class="label" for="pk">Product key</label>
        <input id="pk" class="input font-mono" placeholder="generic key if empty" bind:value={c.machine.productKey} oninput={dirty} />
      </div>
      <div>
        <label class="label" for="dn">Install disk number</label>
        <input id="dn" type="number" min="0" class="input font-mono" bind:value={c.machine.diskNumber} oninput={dirty} />
      </div>
    </div>
    <div class="mt-4"><Notice kind="warn">Setup <strong>wipes disk {c.machine.diskNumber}</strong> on the target. On a single-SSD laptop that's 0.</Notice></div>
  </section>

  <section class="card p-5">
    <h2 class="h2 mb-1 flex items-center gap-2"><Icon name="user" size={16} /> Accounts</h2>
    <p class="muted mb-4 text-xs">Least privilege: one administrator, everyone else standard. The lead user elevates with the admin's credentials when needed.</p>

    <div class="space-y-3">
      <div class="rounded-lg border border-ink-700 bg-ink-850 p-3">
        <div class="mb-2 flex items-center justify-between">
          <span class="text-sm font-medium">Administrator</span>
          <span class="rounded bg-ember-500/15 px-1.5 py-0.5 text-[10px] font-medium text-ember-300 uppercase">admin · auto-logon once</span>
        </div>
        <input class="input {errors.admin ? 'border-danger' : ''}" bind:value={c.accounts.admin.name} oninput={dirty} placeholder="BigMan" />
        {#if errors.admin}<p class="mt-1 text-xs text-danger">{errors.admin}</p>{/if}
      </div>
      <div class="rounded-lg border border-ink-700 bg-ink-850 p-3">
        <div class="mb-2 flex items-center justify-between">
          <span class="text-sm font-medium">Lead user</span>
          <span class="rounded bg-ink-700 px-1.5 py-0.5 text-[10px] font-medium text-ink-200 uppercase">standard · daily driver</span>
        </div>
        <input class="input {errors.lead ? 'border-danger' : ''}" bind:value={c.accounts.lead.name} oninput={dirty} placeholder="Main" />
        {#if errors.lead}<p class="mt-1 text-xs text-danger">{errors.lead}</p>{/if}
      </div>

      {#each c.accounts.users as u, i (i)}
        <div class="flex items-start gap-2">
          <div class="flex-1">
            <input class="input {errors.users[i] ? 'border-danger' : ''}" bind:value={u.name} oninput={dirty} placeholder="Another standard user" />
            {#if errors.users[i]}<p class="mt-1 text-xs text-danger">{errors.users[i]}</p>{/if}
          </div>
          <button class="btn-ghost px-2" onclick={() => removeUser(i)} aria-label="Remove user"><Icon name="trash" size={15} /></button>
        </div>
      {/each}
      <button class="btn-outline w-full" onclick={addUser}><Icon name="plus" size={15} /> Add standard user</button>
    </div>
  </section>

  <section class="card col-span-2 p-5">
    <div class="mb-4 flex items-end justify-between">
      <div>
        <h2 class="h2 flex items-center gap-2"><Icon name="packs" size={16} /> Pack stack</h2>
        <p class="muted mt-1 text-xs">Applied top to bottom; later packs override earlier ones. Usually: base → one tier → your hardware → your own tweaks.</p>
      </div>
      <div class="flex gap-2">
        <select class="input w-64" bind:value={toAdd}>
          <option value="">Add a pack…</option>
          {#each available as p (p.id)}<option value={p.id}>{p.name ?? p.id}</option>{/each}
        </select>
        <button class="btn-outline" disabled={!toAdd} onclick={addPack}><Icon name="plus" size={15} /> Add</button>
      </div>
    </div>
    {#if app.packsError}<div class="mb-3"><Notice kind="warn" title="Couldn't list packs">{app.packsError}</Notice></div>{/if}
    <ol class="space-y-2">
      {#each c.packs as id, i (id)}
        {@const p = packInfo(id)}
        <li class="flex items-center gap-3 rounded-lg border border-ink-700 bg-ink-850 px-3 py-2.5">
          <span class="w-5 text-center font-mono text-xs text-ink-400">{i + 1}</span>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="font-medium">{p?.name ?? id}</span>
              <span class="font-mono text-xs text-ink-400">{id}</span>
              {#if !p && app.packs.length}<span class="text-xs text-danger">not found</span>{/if}
            </div>
            {#if p?.description}<div class="truncate text-xs text-ink-400">{p.description}</div>{/if}
          </div>
          {#if p?.stepCount !== undefined}<span class="text-xs text-ink-400">{p.stepCount} steps</span>{/if}
          <div class="flex">
            <button class="btn-ghost px-1.5" disabled={i === 0} onclick={() => movePack(i, -1)} aria-label="Move up"><Icon name="up" size={15} /></button>
            <button class="btn-ghost px-1.5" disabled={i === c.packs.length - 1} onclick={() => movePack(i, 1)} aria-label="Move down"><Icon name="down" size={15} /></button>
            <button class="btn-ghost px-1.5" onclick={() => removePack(i)} aria-label="Remove"><Icon name="x" size={15} /></button>
          </div>
        </li>
      {:else}
        <li class="muted text-sm">No packs. Add at least "base".</li>
      {/each}
    </ol>
  </section>
</div>
