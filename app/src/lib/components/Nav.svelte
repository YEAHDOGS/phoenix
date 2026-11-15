<script lang="ts">
  import { app, type Screen } from '$lib/app.svelte';
  import Icon from './Icon.svelte';
  import Logo from './Logo.svelte';

  const items: { id: Screen; label: string; icon: string; hint: string }[] = [
    { id: 'runbook', label: 'Runbook', icon: 'runbook', hint: 'Wipe-and-restore, step by step' },
    { id: 'profile', label: 'Profile', icon: 'profile', hint: 'Machine, accounts, pack stack' },
    { id: 'answer', label: 'Answer File', icon: 'key', hint: 'Every Windows Setup option (Schneegans generator)' },
    { id: 'packs', label: 'Packs', icon: 'packs', hint: 'What gets changed, and how hard' },
    { id: 'plan', label: 'Scan & Plan', icon: 'plan', hint: 'Read-only preview on this machine' },
    { id: 'apps', label: 'Apps', icon: 'apps', hint: 'Chocolatey installs for the lead user' },
    { id: 'usb', label: 'USB', icon: 'usb', hint: 'Build and verify the Phoenix stick' },
  ];

  const kit = $derived(
    app.ctx?.isUsbKit ? 'USB kit' : app.ctx?.isInstalledKit ? 'Installed' : app.ctx?.engineFound ? 'Dev / repo' : 'Not found',
  );
</script>

<nav class="flex h-full w-56 shrink-0 flex-col border-r border-ink-800 bg-ink-900/60">
  <div class="flex items-center gap-2.5 px-4 pt-5 pb-6">
    <Logo />
    <div>
      <div class="font-[family-name:var(--font-display)] text-lg leading-none font-semibold tracking-tight">Phoenix</div>
      <div class="mt-1 text-[11px] text-ink-400">wipe · rebuild · rise</div>
    </div>
  </div>

  <ul class="flex flex-col gap-0.5 px-2">
    {#each items as it (it.id)}
      <li>
        <button
          class="group flex w-full items-center gap-3 rounded-md px-2.5 py-2 text-left text-sm transition-colors {app.screen === it.id
            ? 'bg-ink-800 text-ink-100'
            : 'text-ink-300 hover:bg-ink-800/60 hover:text-ink-100'}"
          onclick={() => app.go(it.id)}
          title={it.hint}
        >
          <span class={app.screen === it.id ? 'text-ember-400' : 'text-ink-400 group-hover:text-ink-200'}><Icon name={it.icon} /></span>
          <span>{it.label}</span>
        </button>
      </li>
    {/each}
  </ul>

  <div class="mt-auto space-y-3 px-4 pb-4 text-[11px] text-ink-400">
    {#if app.dirty}
      <button class="btn-primary w-full" onclick={() => app.saveConfig()}><Icon name="save" size={15} /> Save config</button>
    {/if}
    <div class="space-y-1 rounded-lg border border-ink-800 bg-ink-950/50 p-2.5">
      <div class="flex justify-between"><span>Engine</span><span class="text-ink-200">{app.version?.engineVersion ?? (app.versionError ? 'error' : '…')}</span></div>
      <div class="flex justify-between"><span>PowerShell</span><span class="text-ink-200">{app.version?.psVersion?.split('.').slice(0, 2).join('.') ?? '…'}</span></div>
      <div class="flex justify-between">
        <span>Elevated</span><span class={app.version?.isAdmin ? 'text-safe' : 'text-ink-200'}>{app.version ? (app.version.isAdmin ? 'yes' : 'no') : '…'}</span>
      </div>
      <div class="flex justify-between"><span>Kit</span><span class="text-ink-200">{kit}</span></div>
      <div class="flex justify-between">
        <span>Config</span><span class="text-ink-200" title={app.configPath ?? ''}>{app.isUserConfig ? 'saved' : 'example'}{app.dirty ? ' •' : ''}</span>
      </div>
    </div>
  </div>
</nav>
