<script lang="ts">
  import { log } from '../store.svelte';
  import { streamPowershellInline } from '../phoenix';

  let open = $state(false);
  let running = $state(false);

  /**
   * REQUIRED SPIKE: proves the core Tauri pattern on a real Windows machine -
   * spawn PowerShell via tauri-plugin-shell and stream stdout/stderr
   * line-by-line into the GUI log. Production flows (answer-file generation,
   * USB staging) use streamPowershellScript() the same way.
   */
  async function runSpike() {
    if (running) return;
    running = true;
    log('info', 'Spike: spawning PowerShell, streaming output...');
    try {
      await streamPowershellInline(
        `1..8 | ForEach-Object { Write-Output "spike stdout $_"; Write-Error "spike stderr $_"; Start-Sleep -Milliseconds 250 }; Write-Output "spike done"`,
      );
    } catch (e) {
      log('error', `Spike failed: ${e}`);
    } finally {
      running = false;
    }
  }
</script>

<div class="rounded-lg border border-dashed border-slate-300 bg-slate-50 p-3">
  <button
    class="text-xs font-bold uppercase tracking-wide text-slate-500 hover:text-slate-700"
    onclick={() => (open = !open)}
  >
    {open ? '▾' : '▸'} Diagnostics: PowerShell streaming spike
  </button>
  {#if open}
    <p class="mt-2 text-xs text-slate-600">
      Runs an inline PowerShell snippet through the
      <code class="rounded bg-slate-200 px-1">stream_powershell_inline</code>
      Tauri command. Stdout/stderr lines must appear in the build log below as
      they stream - this is the validated pattern the stager scripts will use.
      Requires Windows + PowerShell.
    </p>
    <button
      class="mt-2 rounded bg-slate-700 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:opacity-50"
      disabled={running}
      onclick={runSpike}
    >
      {running ? 'Running…' : 'Run streaming spike'}
    </button>
  {/if}
</div>
