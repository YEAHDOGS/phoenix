<script lang="ts">
  import { onMount } from 'svelte';
  import { app } from '$lib/app.svelte';
  import { call, describeError, getMaybeElevated, unwrap, type EngineError } from '$lib/engine';
  import { FALLBACK_STAGES, isFinished, type Stage, type StateDoc } from '$lib/runbook';
  import PageHeader from '$lib/components/PageHeader.svelte';
  import Markdown from '$lib/components/Markdown.svelte';
  import StatusPill from '$lib/components/StatusPill.svelte';
  import Notice from '$lib/components/Notice.svelte';
  import Icon from '$lib/components/Icon.svelte';
  import PhaseRunDialog from '$lib/components/PhaseRunDialog.svelte';

  let stages = $state<Stage[]>([]);
  let usingFallback = $state(false);
  let loadError = $state<string | null>(null);
  let loading = $state(true);
  let expanded = $state<Record<string, boolean>>({});
  let busy = $state<Record<string, boolean>>({});

  let dialogOpen = $state(false);
  let dialogStage = $state<Stage | null>(null);

  const currentId = $derived(stages.find((s) => !isFinished(s.status))?.id ?? null);
  const doneCount = $derived(stages.filter((s) => isFinished(s.status)).length);

  async function load() {
    loading = true;
    loadError = null;
    let base: Stage[] = [];
    try {
      const r = unwrap<{ stages: Stage[] } | Stage[]>('runbook', await call('runbook'));
      base = Array.isArray(r) ? r : (r?.stages ?? []);
      usingFallback = base.length === 0;
    } catch (e) {
      loadError = describeError(e);
      usingFallback = true;
    }
    if (usingFallback) base = structuredClone(FALLBACK_STAGES);

    // `runbook` merges state already; `state` fills in when it doesn't.
    try {
      const st = unwrap<StateDoc>('state', await call('state'));
      for (const s of base) if (!s.status && st?.stages?.[s.id]) Object.assign(s, st.stages[s.id]);
    } catch {
      /* state is optional (fresh machine) */
    }
    for (const s of base) s.status ??= 'pending';
    stages = base;
    loading = false;
    const cur = stages.find((s) => !isFinished(s.status));
    if (cur && expanded[cur.id] === undefined) expanded[cur.id] = true;
  }

  async function mark(stage: Stage, status: 'done' | 'skipped' | 'pending') {
    busy[stage.id] = true;
    try {
      await getMaybeElevated('mark', { stage: stage.id, status });
      stage.status = status;
      if (status !== 'pending') {
        expanded[stage.id] = false;
        const next = stages.find((s) => !isFinished(s.status));
        if (next) expanded[next.id] = true;
      }
    } catch (e) {
      app.toast('error', `Could not update stage: ${describeError(e)}`);
    }
    busy[stage.id] = false;
  }

  async function launch(stage: Stage) {
    if (!stage.launch) return;
    busy[stage.id] = true;
    const r = await call('launch', { loadout: stage.launch.loadout, args: stage.launch.args ?? [] });
    if (r.ok) app.toast('ok', `Launched ${stage.launch.loadout}`);
    else app.toast('error', `Launch failed: ${(r.data as EngineError)?.error}`);
    busy[stage.id] = false;
  }

  function runPhase(stage: Stage) {
    dialogStage = stage;
    dialogOpen = true;
  }

  async function phaseDone(ok: boolean) {
    if (ok && dialogStage) await load();
  }

  const whoLabel: Record<string, string> = { admin: 'Admin account', lead: 'Lead user', any: 'Anyone' };

  onMount(load);
</script>

<PageHeader
  title="Runbook"
  subtitle="The full wipe-and-restore, in order. Manual steps you check off; automated phases preview first, then run with your approval."
>
  {#snippet actions()}
    <button class="btn-ghost" onclick={load}><Icon name="refresh" size={15} /> Refresh</button>
  {/snippet}
</PageHeader>

{#if app.ctx}
  <div class="mb-5 grid grid-cols-3 gap-3 text-sm">
    <div class="card px-4 py-3">
      <div class="label">Where am I</div>
      <div class="text-ink-100">
        {app.ctx.isUsbKit ? 'Running from the Phoenix USB' : app.ctx.isInstalledKit ? 'Installed kit on this PC' : 'Build PC (repo kit)'}
      </div>
    </div>
    <div class="card px-4 py-3">
      <div class="label">This session</div>
      <div class={app.version?.isAdmin ? 'text-safe' : 'text-ink-100'}>
        {app.version ? (app.version.isAdmin ? 'Elevated (administrator)' : 'Standard; phases ask for UAC') : '…'}
      </div>
    </div>
    <div class="card px-4 py-3">
      <div class="label">Progress</div>
      <div class="flex items-center gap-3">
        <div class="h-1.5 flex-1 overflow-hidden rounded-full bg-ink-800">
          <div class="h-full bg-ember-500" style="width: {stages.length ? (doneCount / stages.length) * 100 : 0}%"></div>
        </div>
        <span class="text-ink-200">{doneCount}/{stages.length}</span>
      </div>
    </div>
  </div>
{/if}

{#if usingFallback && !loading}
  <div class="mb-4">
    <Notice kind="warn" title="Using the built-in runbook">
      {loadError ?? 'The engine returned no stages.'} Stage status can't be saved until the engine's runbook works.
    </Notice>
  </div>
{/if}

<ol class="relative">
  {#each stages as stage, i (stage.id)}
    {@const finished = isFinished(stage.status)}
    {@const isCurrent = stage.id === currentId}
    <li class="relative flex gap-4 pb-3">
      <div class="flex flex-col items-center">
        <div
          class="z-10 flex h-8 w-8 shrink-0 items-center justify-center rounded-full border text-xs font-semibold {finished
            ? 'border-safe/50 bg-safe/15 text-safe'
            : isCurrent
              ? 'border-ember-400 bg-ember-500/15 text-ember-300 shadow-[0_0_0_4px_rgba(255,106,26,0.12)]'
              : 'border-ink-600 bg-ink-900 text-ink-400'}"
        >
          {#if finished}<Icon name="check" size={15} />{:else}{i + 1}{/if}
        </div>
        {#if i < stages.length - 1}<div class="w-px flex-1 {finished ? 'bg-safe/30' : 'bg-ink-700'}"></div>{/if}
      </div>

      <div class="card mb-1 min-w-0 flex-1 {isCurrent ? 'border-ember-500/40' : ''}">
        <button class="flex w-full items-center gap-3 px-4 py-3 text-left" onclick={() => (expanded[stage.id] = !expanded[stage.id])}>
          <span class="shrink-0 {stage.kind === 'phase' ? 'text-ember-400' : stage.kind === 'build' ? 'text-info' : 'text-ink-400'}">
            <Icon name={stage.kind === 'phase' ? 'bolt' : stage.kind === 'build' ? 'usb' : 'hand'} size={16} />
          </span>
          <span class="min-w-0 flex-1">
            <span class="block truncate font-medium {finished ? 'text-ink-300' : 'text-ink-100'}">{stage.title}</span>
            <span class="mt-0.5 flex gap-3 text-xs text-ink-400">
              <span>{stage.kind === 'phase' ? `Automated · phase ${stage.phase}` : stage.kind === 'build' ? 'In this app' : 'Manual'}</span>
              {#if stage.who}<span>{whoLabel[stage.who] ?? stage.who}</span>{/if}
              {#if stage.network}
                <span class="flex items-center gap-1 {stage.network === 'offline' ? 'text-safe' : 'text-caution'}">
                  <Icon name="wifi" size={12} />{stage.network}
                </span>
              {/if}
            </span>
          </span>
          <StatusPill status={stage.status} />
        </button>

        {#if expanded[stage.id]}
          <div class="space-y-3 border-t border-ink-800 px-4 py-3">
            <Markdown source={stage.instructions} />
            {#each stage.warnings ?? [] as w}
              <Notice kind="warn">{w}</Notice>
            {/each}
            <div class="flex flex-wrap gap-2 pt-1">
              {#if stage.kind === 'build'}
                <button class="btn-primary" onclick={() => app.go('usb')}><Icon name="usb" size={15} /> Open USB builder</button>
              {/if}
              {#if stage.kind === 'phase' && stage.phase}
                <button class="btn-outline" onclick={() => app.openPlan(stage.phase!, true)}><Icon name="eye" size={15} /> Preview changes</button>
                <button class="btn-primary" onclick={() => runPhase(stage)}><Icon name="play" size={15} /> Run phase</button>
              {/if}
              {#if stage.launch}
                <button class="btn-outline" disabled={busy[stage.id]} onclick={() => launch(stage)}>
                  <Icon name="external" size={15} /> Launch {stage.launch.loadout}
                </button>
              {/if}
              <span class="flex-1"></span>
              {#if finished}
                <button class="btn-ghost" disabled={busy[stage.id] || usingFallback} onclick={() => mark(stage, 'pending')}>Reopen</button>
              {:else}
                <button class="btn-ghost" disabled={busy[stage.id] || usingFallback} onclick={() => mark(stage, 'skipped')}>Skip</button>
                <button class="btn-outline" disabled={busy[stage.id] || usingFallback} onclick={() => mark(stage, 'done')}>
                  <Icon name="check" size={15} /> Mark done
                </button>
              {/if}
            </div>
            {#if stage.at}<div class="text-xs text-ink-500">Updated {stage.at}</div>{/if}
          </div>
        {/if}
      </div>
    </li>
  {/each}
</ol>

{#if dialogStage?.phase}
  <PhaseRunDialog bind:open={dialogOpen} phase={dialogStage.phase} title={dialogStage.title} ondone={phaseDone} />
{/if}
