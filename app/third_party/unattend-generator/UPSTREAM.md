# Vendored upstream: unattend-generator

- Source: https://github.com/cschneegans/unattend-generator
- Commit: `8fdf1b99af95977ea38f4922662964dc6324b0df`
- Fetched: 2026-11-14
- License: MIT (see `LICENSE.txt` in this folder), (c) Christoph Schneegans

This is the .NET library behind https://schneegans.de/windows/unattend-generator/.
It is an unmodified snapshot. Phoenix builds it through `unattend/PhoenixUnattend.csproj`,
which overrides the target framework from outside; nothing in this folder is edited.

To update: download the tarball of a newer commit, replace this folder's contents,
update the commit above, then run `unattend/build.ps1` and `unattend/tests/Test-Unattend.ps1`.
