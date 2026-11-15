<script lang="ts">
  // Minimal stroke icons (24x24 viewBox), drawn inline so there are no remote assets.
  let { name, size = 18 }: { name: string; size?: number } = $props();
  const paths: Record<string, string> = {
    runbook: 'M5 4h11l3 3v13H5z M9 9h6 M9 13h6 M9 17h4',
    profile: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M4 20c1.5-4 4.5-6 8-6s6.5 2 8 6',
    packs: 'M12 3 3 7.5 12 12l9-4.5z M3 12l9 4.5 9-4.5 M3 16.5 12 21l9-4.5',
    plan: 'M4 19V5 M4 19h16 M8 15l3-4 3 2 5-6',
    apps: 'M4 4h7v7H4z M13 4h7v7h-7z M4 13h7v7H4z M13 13h7v7h-7z',
    usb: 'M9 2h6v6H9z M7 8h10v9a5 5 0 0 1-10 0z M12 13v4',
    log: 'M4 6h16 M4 12h16 M4 18h10',
    save: 'M5 4h11l3 3v13H5z M8 4v5h7V4 M8 20v-6h8v6',
    refresh: 'M20 11a8 8 0 1 0-2.3 5.7 M20 4v7h-7',
    shield: 'M12 3 5 6v6c0 4.5 3 7.5 7 9 4-1.5 7-4.5 7-9V6z',
    check: 'M5 12.5 10 17l9-10',
    play: 'M8 5v14l11-7z',
    eye: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
    search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z M20 20l-4-4',
    plus: 'M12 5v14 M5 12h14',
    trash: 'M4 7h16 M9 7V4h6v3 M6 7l1 13h10l1-13',
    up: 'M12 19V5 M6 11l6-6 6 6',
    down: 'M12 5v14 M6 13l6 6 6-6',
    folder: 'M3 6h6l2 2h10v11H3z',
    download: 'M12 4v11 M7 10l5 5 5-5 M5 20h14',
    hand: 'M8 13V5.5a1.5 1.5 0 0 1 3 0V11 M11 10V4.5a1.5 1.5 0 0 1 3 0V11 M14 10.5V6a1.5 1.5 0 0 1 3 0v8c0 4-2.5 7-6.5 7S5 18 4 15l-1-3a1.5 1.5 0 0 1 2.6-1.3L8 13',
    bolt: 'M13 2 4 14h7l-1 8 9-12h-7z',
    wifi: 'M2 9a15 15 0 0 1 20 0 M5 12.5a10 10 0 0 1 14 0 M8.5 16a5 5 0 0 1 7 0 M12 19.5h.01',
    chip: 'M7 7h10v10H7z M10 3v4 M14 3v4 M10 17v4 M14 17v4 M3 10h4 M3 14h4 M17 10h4 M17 14h4',
    power: 'M12 3v9 M6.3 6.3a8 8 0 1 0 11.4 0',
    leaf: 'M5 19c0-8 5-14 15-14 0 10-6 15-14 15 M5 19l7-7',
    copy: 'M8 8h11v11H8z M5 16V5h11',
    x: 'M6 6l12 12 M18 6 6 18',
    external: 'M14 4h6v6 M20 4l-9 9 M18 14v6H4V6h6',
    disk: 'M4 6a8 3 0 0 0 16 0 8 3 0 0 0-16 0 M4 6v12a8 3 0 0 0 16 0V6',
    user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M4 20c1.5-4 4.5-6 8-6s6.5 2 8 6',
    key: 'M15 7a4 4 0 1 1-3.5 6L5 19.5V21H3v-2l6.5-6.5A4 4 0 0 1 15 7z M16 8h.01',
  };
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  <path d={paths[name] ?? ''} />
</svg>
