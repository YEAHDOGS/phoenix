<script lang="ts">
  import { onMount } from 'svelte';
  import { BLADES, ACTIVE_BLADE } from '$lib/blades';
  import { setup, log } from '$lib/store.svelte';
  import { onScriptOutput, verifyVentoy, listRemovableDrives } from '$lib/phoenix';
  import ModuleTiles from '$lib/components/ModuleTiles.svelte';
  import SetupWizard from '$lib/components/SetupWizard.svelte';
  import LogPane from '$lib/components/LogPane.svelte';
  import SpikePanel from '$lib/components/SpikePanel.svelte';

  let wizardOpen = $state(false);

  onMount(() => {
    // Route streamed PowerShell output (Rust `phx-output` events) into the log.
    const unlisten = onScriptOutput((msg) => {
      const level = msg.stream === 'stderr' ? 'stderr' : msg.stream === 'status' ? 'info' : 'stdout';
      log(level, msg.line);
    });
    log('info', 'Phoenix USB Builder started.');
    log('info', 'Tauri flagship build. The WinForms launcher branch remains the zero-dependency fallback.');
    return () => {
      void unlisten.then((u) => u());
    };
  });

  async function onVerifyVentoy() {
    const drive = setup.drive.trim().replace(/[/\\]+$/, '');
    if (!drive) {
      log('warn', 'Set a target drive first.');
      return;
    }
    try {
      const ok = await verifyVentoy(drive);
      log(ok ? 'success' : 'error', ok ? `Ventoy confirmed on ${drive}.` : `${drive} is not a Ventoy USB (no ventoy/ directory).`);
    } catch (e) {
      log('error', `Ventoy check failed: ${e}`);
    }
  }

  async function onDetectDrives() {
    try {
      const drives = await listRemovableDrives();
      log('info', `Removable drives: ${drives.map((d) => `${d.letter} (${d.label})`).join(', ') || '(none)'}`);
    } catch (e) {
      log('warn', `Drive detection not wired yet: ${e}`);
    }
  }
</script>

<div class="flex min-h-screen flex-col bg-slate-100 text-slate-800">
  <!-- Header -->
  <header class="bg-slate-900 px-6 py-4">
    <h1 class="text-xl font-bold text-sky-400">PHOENIX <span class="text-slate-300">- USB Builder</span></h1>
    <p class="text-sm text-slate-400">
      {ACTIVE_BLADE.description}
    </p>
    <!-- Blade tabs: one blade today, registry-driven for the multi-interface future -->
    <div class="mt-3 flex gap-2">
      {#each BLADES as b}
        <span
          class="rounded-t px-3 py-1.5 text-xs font-bold uppercase tracking-wide"
          class:bg-slate-100={b.id === ACTIVE_BLADE.id}
          class:text-slate-800={b.id === ACTIVE_BLADE.id}
          class:bg-slate-800={b.id !== ACTIVE_BLADE.id}
          class:text-slate-500={b.id !== ACTIVE_BLADE.id}
        >
          {b.label}
        </span>
      {/each}
    </div>
  </header>

  <main class="flex flex-1 flex-col gap-4 p-6">
    <section>
      <h2 class="mb-2 text-sm font-bold uppercase tracking-wide text-slate-500">
        Boot options → Ventoy ISOs to stage
      </h2>
      <ModuleTiles />
    </section>

    <section class="flex flex-wrap items-end gap-3 rounded-lg border border-slate-200 bg-white p-4">
      <div>
        <label class="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500" for="drive">
          Ventoy USB drive
        </label>
        <input
          id="drive"
          class="w-28 rounded border border-slate-300 px-3 py-2 text-sm"
          bind:value={setup.drive}
          placeholder="E:"
        />
      </div>
      <button
        class="rounded bg-slate-200 px-4 py-2 text-sm font-bold text-slate-700 hover:bg-slate-300"
        onclick={onVerifyVentoy}
      >
        Verify Ventoy
      </button>
      <button
        class="rounded bg-slate-200 px-4 py-2 text-sm font-bold text-slate-700 hover:bg-slate-300"
        onclick={onDetectDrives}
      >
        Detect drives
      </button>
      <div class="min-w-64 flex-1">
        <label class="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500" for="reporoot">
          Repo root <span class="font-normal normal-case">(for data/choco-install/apps.json)</span>
        </label>
        <input
          id="reporoot"
          class="w-full rounded border border-slate-300 px-3 py-2 text-sm"
          bind:value={setup.repoRoot}
          placeholder="C:\path\to\phoenix"
        />
      </div>
      <button
        class="rounded bg-sky-600 px-5 py-2 text-sm font-bold text-white hover:bg-sky-700"
        onclick={() => (wizardOpen = true)}
      >
        New Setup…
      </button>
    </section>

    <SpikePanel />
    <LogPane />
  </main>

  {#if wizardOpen}
    <SetupWizard onclose={() => (wizardOpen = false)} />
  {/if}
</div>
