<script lang="ts">
  import { setup, log } from '../store.svelte';
  import type { BootModule } from '../types';

  // Ventoy renders the 4-option boot menu from the staged ISOs.
  // This GUI stages the ISOs; it never constructs a boot menu.
  const MODULES: BootModule[] = [
    {
      id: 'analyze',
      label: 'Analyze',
      isoLabel: 'SystemRescue',
      description: 'Hardware analysis, full graphical file manager, shell.',
      defaultStaged: true,
      dangerous: false,
    },
    {
      id: 'backup',
      label: 'Backup',
      isoLabel: 'Rescuezilla',
      description: 'Full-machine image backup before anything destructive.',
      defaultStaged: true,
      dangerous: false,
    },
    {
      id: 'nuke',
      label: 'Nuke',
      isoLabel: 'ShredOS',
      description:
        'nwipe secure disk wipe. IRREVERSIBLE. nwipe keeps its own on-device confirmations - this GUI cannot bypass them.',
      defaultStaged: false,
      dangerous: true,
    },
    {
      id: 'reinstall',
      label: 'Reinstall',
      isoLabel: 'WinPE + Win ISO',
      description:
        'Windows installer ISO + Phoenix WinPE payload: headless install driven by phoenix-config.json.',
      defaultStaged: true,
      dangerous: false,
    },
  ];

  let showNukeWarning = $state(false);

  function applyToggle(id: string, checked: boolean) {
    setup.modules = checked
      ? [...setup.modules, id]
      : setup.modules.filter((m) => m !== id);
    if (checked && id === 'nuke') {
      log('warn', 'ShredOS ISO staged (NOT executed). nwipe keeps its own on-device confirmations.');
    }
  }

  function onToggle(m: BootModule, e: Event) {
    const checked = (e.target as HTMLInputElement).checked;
    if (checked && m.dangerous) {
      // Nuke interlock: staging requires explicit acknowledgement.
      // Unchecking is always free.
      (e.target as HTMLInputElement).checked = false;
      showNukeWarning = true;
      return;
    }
    applyToggle(m.id, checked);
  }
</script>

<div class="grid grid-cols-2 gap-3 xl:grid-cols-4">
  {#each MODULES as m}
    <div
      class="rounded-lg border bg-white p-4 shadow-sm"
      class:border-red-400={m.dangerous}
      class:border-slate-200={!m.dangerous}
    >
      <div class="flex items-baseline justify-between">
        <h3
          class="text-sm font-bold uppercase tracking-wide"
          class:text-red-600={m.dangerous}
          class:text-sky-700={!m.dangerous}
        >
          {m.label}
        </h3>
        <span class="text-xs italic text-slate-500">{m.isoLabel}</span>
      </div>
      <p class="mt-1 min-h-16 text-xs text-slate-600">{m.description}</p>
      <label class="mt-2 flex cursor-pointer items-center gap-2 text-sm font-semibold text-slate-700">
        <input
          type="checkbox"
          class="h-4 w-4 accent-sky-600"
          checked={setup.modules.includes(m.id)}
          onchange={(e) => onToggle(m, e)}
        />
        Stage ISO
      </label>
    </div>
  {/each}
</div>

{#if showNukeWarning}
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
    <div class="w-105 max-w-[90vw] rounded-lg bg-white p-6 shadow-xl">
      <h2 class="text-lg font-bold text-red-600">Stage the Nuke ISO?</h2>
      <p class="mt-2 text-sm text-slate-700">
        You are staging the <strong>ShredOS (nwipe)</strong> ISO onto this USB.
        Nuke securely wipes the target machine's disk - it is
        <strong>irreversible</strong>.
      </p>
      <p class="mt-2 text-sm text-slate-700">
        Staging it does <strong>not</strong> run anything on this machine. On the
        target machine, nwipe keeps its own on-device confirmations, which this
        screen cannot bypass.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <button
          class="rounded bg-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-300"
          onclick={() => (showNukeWarning = false)}
        >
          Cancel
        </button>
        <button
          class="rounded bg-red-600 px-4 py-2 text-sm font-semibold text-white hover:bg-red-700"
          onclick={() => {
            showNukeWarning = false;
            applyToggle('nuke', true);
          }}
        >
          I understand - stage it
        </button>
      </div>
    </div>
  </div>
{/if}
