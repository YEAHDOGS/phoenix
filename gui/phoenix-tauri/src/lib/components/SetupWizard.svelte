<script lang="ts">
  import { setup, log, buildConfig, clearPassword } from '../store.svelte';
  import { getAppCatalog, verifyVentoy, writePhoenixConfig } from '../phoenix';
  import type { AppEntry } from '../types';

  let { onclose }: { onclose: () => void } = $props();

  const STEPS = ['Machine', 'Accounts', 'Apps', 'Options', 'Review'] as const;
  let step = $state(0);
  let error = $state('');

  // --- Apps catalog ---
  let catalog = $state<AppEntry[]>([]);
  let catalogState = $state<'idle' | 'loading' | 'empty' | 'error'>('idle');
  let categoryFilter = $state('(all)');
  let categories = $derived(['(all)', ...new Set(catalog.map((a) => a.category))]);
  let visibleApps = $derived(
    catalog.filter((a) => categoryFilter === '(all)' || a.category === categoryFilter),
  );

  async function loadCatalog() {
    if (catalogState !== 'idle' || !setup.repoRoot) return;
    catalogState = 'loading';
    try {
      catalog = await getAppCatalog(setup.repoRoot);
      if (catalog.length === 0) {
        catalogState = 'empty';
        log('warn', 'apps.json is empty (sibling worker still populating) - continuing without apps.');
      } else {
        catalogState = 'idle';
        // Preselect defaults on first load.
        const defaults = catalog.filter((a) => a.defaultSelected).map((a) => a.package);
        setup.apps = [...new Set([...setup.apps, ...defaults])];
      }
    } catch (e) {
      catalogState = 'error';
      log('error', `Could not load app catalog: ${e}`);
    }
  }

  function toggleApp(pkg: string, checked: boolean) {
    setup.apps = checked ? [...setup.apps, pkg] : setup.apps.filter((p) => p !== pkg);
  }

  // --- Validation per step ---
  function validate(): boolean {
    error = '';
    if (step === 0) {
      if (!/^[A-Za-z0-9-]{1,15}$/.test(setup.computerName.trim())) {
        error = 'Computer name must be 1-15 chars: letters, digits, dash.';
        return false;
      }
      setup.computerName = setup.computerName.trim().toUpperCase();
    }
    if (step === 1) {
      if (!setup.username.trim()) {
        error = 'Username is required.';
        return false;
      }
      if (!setup.password) {
        error = 'Password is required.';
        return false;
      }
      if (setup.password !== confirmPassword) {
        error = 'Passwords do not match.';
        return false;
      }
      setup.username = setup.username.trim();
    }
    return true;
  }

  let confirmPassword = $state('');

  function next() {
    if (!validate()) return;
    if (step === 2) {
      // Apps step reached - try loading the catalog once.
      void loadCatalog();
    }
    if (step < STEPS.length - 1) step += 1;
  }
  function back() {
    error = '';
    if (step > 0) step -= 1;
  }

  // --- Build ---
  let building = $state(false);

  async function build() {
    if (building) return;
    building = true;
    try {
      const drive = setup.drive.trim().replace(/[/\\]+$/, '');
      if (!drive) {
        log('error', 'No target drive set.');
        return;
      }
      log('info', `Verifying Ventoy on ${drive}...`);
      const ok = await verifyVentoy(drive);
      if (!ok) {
        log('error', `Target ${drive} is not a Ventoy USB (no ventoy/ directory). Prepare it with Ventoy first.`);
        return;
      }
      log('success', `Ventoy confirmed on ${drive}.`);

      // NOTE: ISO staging (Stage-Usb equivalent) lands with the sibling worker;
      // it will drive the stager through streamPowershellScript().
      log('warn', 'ISO staging step is stubbed in this scaffold - writing config only.');

      const path = await writePhoenixConfig(drive, buildConfig());
      log('success', 'phoenix-config.json written (headless boot handoff).', { path });
      log('info', 'USB build complete.');
      clearPassword();
      confirmPassword = '';
      onclose();
    } catch (e) {
      log('error', `Build failed: ${e}`);
    } finally {
      building = false;
    }
  }

  const inputCls =
    'w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-800 focus:border-sky-500 focus:outline-none';
  const labelCls = 'mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500';
</script>

<div class="fixed inset-0 z-40 flex items-center justify-center bg-black/50">
  <div class="flex max-h-[90vh] w-160 max-w-[94vw] flex-col rounded-xl bg-slate-100 shadow-2xl">
    <div class="flex items-center justify-between border-b border-slate-200 px-6 py-4">
      <h2 class="text-lg font-bold text-slate-800">New Setup</h2>
      <button class="text-slate-400 hover:text-slate-600" onclick={onclose} aria-label="Close">✕</button>
    </div>

    <!-- Stepper -->
    <div class="flex gap-1 px-6 pt-4">
      {#each STEPS as s, i}
        <div
          class="flex-1 rounded-t px-2 py-1.5 text-center text-xs font-bold uppercase"
          class:bg-white={i === step}
          class:text-sky-700={i === step}
          class:text-slate-400={i !== step}
        >
          {i + 1}. {s}
        </div>
      {/each}
    </div>

    <div class="flex-1 overflow-y-auto bg-white px-6 py-5">
      {#if error}
        <div class="mb-4 rounded bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">{error}</div>
      {/if}

      {#if step === 0}
        <div class="space-y-4">
          <div>
            <label class={labelCls} for="wz-computer">Computer name</label>
            <input id="wz-computer" class={inputCls} bind:value={setup.computerName} placeholder="PHOENIX-01" maxlength={15} />
            <p class="mt-1 text-xs text-slate-500">1-15 chars: letters, digits, dash.</p>
          </div>
          <div>
            <label class={labelCls} for="wz-tz">Timezone</label>
            <input id="wz-tz" class={inputCls} bind:value={setup.timeZone} placeholder="Central Standard Time" />
          </div>
          <div>
            <label class={labelCls} for="wz-edition">Windows edition</label>
            <select id="wz-edition" class={inputCls} bind:value={setup.edition}>
              {#each ['Pro', 'Home', 'Education', 'Pro for Workstations'] as e}<option>{e}</option>{/each}
            </select>
          </div>
          <div>
            <label class={labelCls} for="wz-key">Product key (blank = generic key)</label>
            <input id="wz-key" class={inputCls} bind:value={setup.productKey} placeholder="(optional)" />
          </div>
        </div>
      {:else if step === 1}
        <div class="space-y-4">
          <p class="text-xs text-slate-500">
            Passwords are masked, never written to the log, and stored plaintext
            <strong>only</strong> in phoenix-config.json on the USB (unattend requires it).
            Use a throwaway install-time credential, changed after first logon.
          </p>
          <div>
            <label class={labelCls} for="wz-user">Username</label>
            <input id="wz-user" class={inputCls} bind:value={setup.username} autocomplete="off" />
          </div>
          <div>
            <label class={labelCls} for="wz-pass">Password</label>
            <input id="wz-pass" type="password" class={inputCls} bind:value={setup.password} autocomplete="new-password" />
          </div>
          <div>
            <label class={labelCls} for="wz-pass2">Confirm password</label>
            <input id="wz-pass2" type="password" class={inputCls} bind:value={confirmPassword} autocomplete="new-password" />
          </div>
        </div>
      {:else if step === 2}
        <div>
          <div class="mb-3 flex items-center gap-2">
            <label class={labelCls} for="wz-cat">Category</label>
            <select id="wz-cat" class="rounded border border-slate-300 px-2 py-1 text-sm" bind:value={categoryFilter}>
              {#each categories as c}<option>{c}</option>{/each}
            </select>
            <span class="text-xs text-slate-500">Installed offline from the staged cache.</span>
          </div>
          {#if catalogState === 'loading'}
            <p class="text-sm text-slate-500">Loading app catalog…</p>
          {:else if catalog.length === 0}
            <p class="rounded bg-amber-50 px-3 py-2 text-sm text-amber-800">
              No apps available yet - data/choco-install/apps.json is being populated by a sibling worker.
              Set the repo root below and continue; apps are optional.
            </p>
            <div class="mt-3">
              <label class={labelCls} for="wz-repo">Repo root (for apps.json)</label>
              <input id="wz-repo" class={inputCls} bind:value={setup.repoRoot} placeholder="C:\path\to\phoenix" />
              <button
                class="mt-2 rounded bg-slate-200 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-300"
                onclick={() => { catalogState = 'idle'; void loadCatalog(); }}
              >
                Retry loading catalog
              </button>
            </div>
          {:else}
            <div class="max-h-64 space-y-1 overflow-y-auto rounded border border-slate-200 p-2">
              {#each visibleApps as a}
                <label class="flex cursor-pointer items-start gap-2 rounded px-2 py-1.5 hover:bg-slate-50">
                  <input
                    type="checkbox"
                    class="mt-1 h-4 w-4 accent-sky-600"
                    checked={setup.apps.includes(a.package)}
                    onchange={(e) => toggleApp(a.package, (e.target as HTMLInputElement).checked)}
                  />
                  <span class="text-sm">
                    <span class="font-semibold text-slate-800">{a.package}</span>
                    <span class="text-slate-500"> — {a.description}</span>
                    <span class="ml-1 rounded bg-slate-100 px-1.5 text-xs text-slate-500">{a.category}</span>
                  </span>
                </label>
              {/each}
            </div>
          {/if}
        </div>
      {:else if step === 3}
        <div class="space-y-4">
          <label class="flex items-center gap-2 text-sm font-semibold text-slate-700">
            <input type="checkbox" class="h-4 w-4 accent-sky-600" bind:checked={setup.skipOobe} />
            Skip OOBE (recommended)
          </label>
          <label class="flex items-center gap-2 text-sm font-semibold text-slate-700">
            <input type="checkbox" class="h-4 w-4 accent-sky-600" bind:checked={setup.disableWpbt} />
            Disable WPBT (Windows Platform Binary Table)
          </label>
          <label class="flex items-center gap-2 text-sm font-semibold text-slate-700">
            <input type="checkbox" class="h-4 w-4 accent-sky-600" bind:checked={setup.stageUpdates} />
            Stage Windows updates for offline install
          </label>
          <div>
            <label class={labelCls} for="wz-locale">Locale</label>
            <select id="wz-locale" class={inputCls} bind:value={setup.locale}>
              {#each ['en-US', 'en-GB', 'de-DE', 'fr-FR', 'es-ES', 'ja-JP'] as l}<option>{l}</option>{/each}
            </select>
          </div>
          <div>
            <label class={labelCls} for="wz-driver">Driver-pack profile</label>
            <input id="wz-driver" class={inputCls} bind:value={setup.driverProfile} placeholder="(optional)" />
          </div>
        </div>
      {:else}
        <div class="rounded bg-slate-900 p-4 font-mono text-xs leading-6 text-slate-200">
          <div>Computer name : {setup.computerName || '(not set)'}</div>
          <div>Username      : {setup.username || '(not set)'}</div>
          <div>Password      : •••••• <span class="text-slate-500">(never logged; throwaway credential)</span></div>
          <div>Timezone      : {setup.timeZone || '(not set)'}</div>
          <div>Edition       : {setup.edition}</div>
          <div>Product key   : {setup.productKey ? '••••••' : '(generic)'}</div>
          <div>Locale        : {setup.locale}</div>
          <div>Skip OOBE     : {setup.skipOobe ? 'yes' : 'no'}</div>
          <div>Disable WPBT  : {setup.disableWpbt ? 'yes' : 'no'}</div>
          <div>Stage updates : {setup.stageUpdates ? 'yes' : 'no'}</div>
          <div class="mt-2 text-slate-400">ISOs to stage (Ventoy):</div>
          {#each setup.modules as m}<div class="pl-4">✓ {m}</div>{/each}
          <div class="mt-2 text-slate-400">Apps ({setup.apps.length}):</div>
          {#if setup.apps.length === 0}<div class="pl-4 text-slate-500">(none)</div>{/if}
          {#each setup.apps as a}<div class="pl-4">✓ {a}</div>{/each}
          <div class="mt-2 text-slate-400">Target drive: {setup.drive || '(not set)'}</div>
        </div>
      {/if}
    </div>

    <div class="flex items-center justify-between border-t border-slate-200 px-6 py-4">
      <button
        class="rounded bg-slate-200 px-4 py-2 text-sm font-bold text-slate-600 hover:bg-slate-300 disabled:opacity-40"
        disabled={step === 0}
        onclick={back}
      >
        ← Back
      </button>
      {#if step < STEPS.length - 1}
        <button class="rounded bg-sky-600 px-6 py-2 text-sm font-bold text-white hover:bg-sky-700" onclick={next}>
          Next →
        </button>
      {:else}
        <button
          class="rounded bg-emerald-600 px-6 py-2 text-sm font-bold text-white hover:bg-emerald-700 disabled:opacity-50"
          disabled={building}
          onclick={build}
        >
          {building ? 'Building…' : 'Build USB'}
        </button>
      {/if}
    </div>
  </div>
</div>
