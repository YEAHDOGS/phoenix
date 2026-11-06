# Blackbird — username footprint scanner

Reference note, added 2026-11-05.

**What it is:** Blackbird is an open-source OSINT tool that checks whether a
username exists across ~650 sites and exports the hits (CSV/JSON with profile
URLs). One scan of a handle takes under a minute.

**Source:** X post by @Cranefomo (Nov 4, 2026) —
https://x.com/Cranefomo/status/2118032544574652860 — demoed scanning a
well-known handle across 653 sites in ~42 seconds. The demo ran through a
GitHub Actions wrapper (no local install, results download as a file):
https://cranefomo.github.io/blackbird

**How it works:** for each site in its list, it probes the public profile URL /
existence signal for the given username and records matches. Same family as
Sherlock / WhatsMyName.

**Caveat:** a hit proves an account with that name exists — it does NOT prove
the account belongs to a particular person. Handles collide across people;
attribution is a separate step.

**Safe use:** run it on your own handles only, from your own fork /
infrastructure. Do not enter handles into third-party hosted copies — the set
of names being audited is itself sensitive.
