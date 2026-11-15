<script lang="ts">
  let { size = 28 }: { size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true">
  <defs>
    <linearGradient id="phx-fire" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#e4520a" />
      <stop offset="0.55" stop-color="#ff8d45" />
      <stop offset="1" stop-color="#ffd2a1" />
    </linearGradient>
  </defs>
  <path
    fill="url(#phx-fire)"
    d="M16 2c1.6 4.2 5.6 6.4 5.6 11.2 0 1.6-.5 3-1.3 4.1 1.9-.6 3.6-2.2 4.4-4.5C26.8 15 28 17.8 28 20.5 28 26.3 22.6 30 16 30S4 26.3 4 20.5c0-2.7 1.2-5.5 3.3-7.7.8 2.3 2.5 3.9 4.4 4.5-.8-1.1-1.3-2.5-1.3-4.1C10.4 8.4 14.4 6.2 16 2z"
  />
  <path fill="#0b0c0f" opacity="0.35" d="M16 14c.8 2 2.8 3 2.8 5.4 0 1.8-1.3 3.6-2.8 3.6s-2.8-1.8-2.8-3.6C13.2 17 15.2 16 16 14z" />
</svg>
