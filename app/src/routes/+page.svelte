<script lang="ts">
  import { onMount } from 'svelte';
  import { app } from '$lib/app.svelte';
  import Nav from '$lib/components/Nav.svelte';
  import LogDrawer from '$lib/components/LogDrawer.svelte';
  import Toasts from '$lib/components/Toasts.svelte';
  import Notice from '$lib/components/Notice.svelte';
  import Runbook from '$lib/screens/Runbook.svelte';
  import Profile from '$lib/screens/Profile.svelte';
  import AnswerFile from '$lib/screens/AnswerFile.svelte';
  import Packs from '$lib/screens/Packs.svelte';
  import ScanPlan from '$lib/screens/ScanPlan.svelte';
  import Apps from '$lib/screens/Apps.svelte';
  import Usb from '$lib/screens/Usb.svelte';

  onMount(() => {
    app.boot();
  });
</script>

<div class="flex h-screen flex-col">
  <div class="flex min-h-0 flex-1">
    <Nav />
    <main class="min-w-0 flex-1 overflow-y-auto">
      <div class="mx-auto max-w-6xl px-8 py-7">
        {#if app.ctx && !app.ctx.engineFound}
          <div class="mb-5"><Notice kind="error" title="Engine not found">{app.ctx.engineError}</Notice></div>
        {:else if app.versionError}
          <div class="mb-5"><Notice kind="error" title="Engine error">{app.versionError}</Notice></div>
        {/if}
        {#if app.screen === 'runbook'}<Runbook />
        {:else if app.screen === 'profile'}<Profile />
        {:else if app.screen === 'answer'}<AnswerFile />
        {:else if app.screen === 'packs'}<Packs />
        {:else if app.screen === 'plan'}<ScanPlan />
        {:else if app.screen === 'apps'}<Apps />
        {:else if app.screen === 'usb'}<Usb />
        {/if}
      </div>
    </main>
  </div>
  <LogDrawer />
  <Toasts />
</div>
