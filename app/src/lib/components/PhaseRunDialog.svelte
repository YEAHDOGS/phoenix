<script lang="ts">
  /**
   * Preview-then-apply for one phase. Always plans first (read-only) so the
   * confirmation shows real counts, then applies elevated through UAC.
   */
  import { untrack } from 'svelte';
  import { app } from '$lib/app.svelte';
  import { run, type ChangeEvent, type EngineError, type PhaseId, type Run } from '$lib/engine';
  import Modal from './Modal.svelte';
  import Notice from './Notice.svelte';

  let {
    open = $bindable(false),
    phase,
    title,
    ondone,
  }: { open?: boolean; phase: PhaseId; title: string; ondone?: (ok: boolean) => void } = $props();

  type Mode = 'planning' | 'ready' | 'applying' | 'finished';
  let mode = $state<Mode>('planning');
  let planError = $state<string | null>(null);
  let changes = $state<ChangeEvent[]>([]);
  let understood = $state(false);
  let progress = $state<{ pct: number; msg: string }>({ pct: 0, msg: '' });
  let stepStatus = $state<Record<string, string>>({});
  let applied = $state(0);
  let failed = $state(0);
  let result = $state<{ ok: boolean; error?: string } | null>(null);
  let current: Run | null = null;

  const real = $derived(changes.filter((c) => c.action !== 'skip'));
  const byStep = $derived.by(() => {
    const m = new Map<string, number>();
    for (const c of real) m.set(c.step, (m.get(c.step) ?? 0) + 1);
    return [...m.entries()].sort((a, b) => b[1] - a[1]);
  });

  // untrack: startPlan reads/writes state; only `open` should trigger it.
  $effect(() => {
    if (open) untrack(() => startPlan());
  });

  async function startPlan() {
    mode = 'planning';
    planError = null;
    changes = [];
    understood = false;
    result = null;
    stepStatus = {};
    applied = 0;
    failed = 0;
    if (!(await app.ensureSaved())) { planError = 'Save the config first.'; mode = 'ready'; return; }
    const found: ChangeEvent[] = [];
    try {
      current = await run('plan', { phase }, { onEvent: (e) => { if (e.t === 'change') found.push(e); } });
      const r = await current.done;
      changes = found;
      if (!r.ok) planError = (r.data as EngineError)?.error ?? 'Plan failed';
    } catch (e) {
      planError = String(e);
    }
    mode = 'ready';
  }

  async function apply() {
    mode = 'applying';
    progress = { pct: 0, msg: 'Waiting for the administrator prompt…' };
    try {
      current = await run('apply', { phase, unattended: false }, {
        elevated: true,
        onEvent: (e) => {
          if (e.t === 'progress') progress = { pct: e.pct, msg: e.msg ?? '' };
          else if (e.t === 'step') stepStatus[e.step] = e.status;
          else if (e.t === 'change' && e.applied) applied++;
        },
      });
      const r = await current.done;
      failed = Object.values(stepStatus).filter((s) => s === 'fail').length;
      result = { ok: r.ok, error: r.ok ? undefined : (r.data as EngineError)?.error };
    } catch (e) {
      result = { ok: false, error: String(e) };
    }
    mode = 'finished';
    ondone?.(!!result?.ok);
  }

  function close() {
    if (mode === 'planning') current?.cancel();
    open = false;
  }
</script>

<Modal bind:open title="Run phase: {title}" wide onclose={close}>
  {#if mode === 'planning'}
    <div class="flex items-center gap-3 py-6 text-ink-300">
      <span class="h-4 w-4 animate-spin rounded-full border-2 border-ink-600 border-t-ember-400"></span>
      Previewing what this phase would change on this machine (read-only)…
    </div>
  {:else if mode === 'ready'}
    {#if planError}
      <Notice kind="error" title="Preview failed">{planError}</Notice>
      <p class="muted mt-3 text-sm">You can still run the phase, but you'll be doing it blind.</p>
    {:else}
      <div class="mb-4 flex gap-6">
        <div><div class="text-3xl font-semibold text-ember-300">{real.length}</div><div class="muted text-xs">changes</div></div>
        <div><div class="text-3xl font-semibold text-ink-200">{byStep.length}</div><div class="muted text-xs">steps</div></div>
        <div><div class="text-3xl font-semibold text-ink-400">{changes.length - real.length}</div><div class="muted text-xs">already done / skipped</div></div>
      </div>
      {#if byStep.length}
        <div class="mb-4 max-h-56 overflow-y-auto rounded-lg border border-ink-700">
          {#each byStep as [step, n] (step)}
            <div class="flex justify-between border-b border-ink-800 px-3 py-1.5 text-sm last:border-0">
              <span class="font-mono text-ink-200">{step}</span><span class="text-ink-300">{n}</span>
            </div>
          {/each}
        </div>
      {:else}
        <Notice kind="ok" title="Nothing to change">This machine already matches the profile for this phase.</Notice>
      {/if}
    {/if}
    <div class="mt-3"><Notice kind="warn" title="This changes the system">
      Phoenix snapshots services, registry, firewall and startup entries first, so most of it can be undone. Removed
      apps, features and devices cannot be restored by undo. Windows will ask for administrator approval.
    </Notice></div>
    <label class="mt-4 flex items-center gap-2 text-sm text-ink-200">
      <input type="checkbox" bind:checked={understood} /> I've reviewed the plan and want to apply it.
    </label>
  {:else}
    <div class="space-y-3">
      <div class="h-2 overflow-hidden rounded-full bg-ink-800">
        <div class="h-full bg-ember-500 transition-all" style="width: {mode === 'finished' ? 100 : Math.max(2, progress.pct)}%"></div>
      </div>
      <div class="text-sm text-ink-300">{mode === 'finished' ? 'Finished.' : progress.msg || 'Working…'}</div>
      <div class="flex gap-6 text-sm">
        <span class="text-safe">{applied} applied</span>
        <span class="text-ink-300">{Object.values(stepStatus).filter((s) => s === 'ok').length} steps ok</span>
        {#if failed}<span class="text-danger">{failed} steps failed</span>{/if}
      </div>
      {#if result && !result.ok}<Notice kind="error" title="Phase failed">{result.error}</Notice>{/if}
      {#if result?.ok}<Notice kind="ok" title="Phase complete">Open the log for details. If the phase asks for it, power off now.</Notice>{/if}
    </div>
  {/if}

  {#snippet actions()}
    {#if mode === 'ready'}
      <button class="btn-ghost" onclick={close}>Cancel</button>
      <button class="btn-primary" disabled={!understood} onclick={apply}>Apply as administrator</button>
    {:else if mode === 'finished'}
      <button class="btn-outline" onclick={() => { app.logOpen = true; }}>Open log</button>
      <button class="btn-primary" onclick={close}>Close</button>
    {:else}
      <button class="btn-ghost" onclick={close} disabled={mode === 'applying'}>Cancel</button>
    {/if}
  {/snippet}
</Modal>
