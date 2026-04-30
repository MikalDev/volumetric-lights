---
name: release-addon
description: Package a Construct 3 addon from src/ into a .c3addon release file. Optional argument `major`, `minor`, or `patch` bumps the version in src/addon.json before packaging.
disable-model-invocation: true
allowed-tools: Bash(powershell *) Bash(mv *) Bash(mkdir *) Bash(ls *) Edit
---

# Release the addon

1. **If an argument is provided** (`major`, `minor`, or `patch`), bump the `version` field in `src/addon.json` before packaging. The version is a 4-component string `A.B.C.D` (major.minor.patch.build):
   - `major`: `(A+1).0.0.0`
   - `minor`: `A.(B+1).0.0`
   - `patch`: `A.B.(C+1).0`

   Edit `src/addon.json` to write the new version, then continue.

   If the argument is anything other than `major`, `minor`, `patch`, or empty, stop and report the invalid argument.

2. Read `src/addon.json`. Extract the `id`, `version`, and `file-list` fields.
3. Determine the output directory: use `release/` if it exists, otherwise use `dist/` (create it if needed).
4. Package every entry in `file-list` into a zip, then rename to `.c3addon`:

```
cd src/
powershell -Command "Compress-Archive -Path <file-list entries, comma-separated> -DestinationPath '../<outdir>/release.zip' -Force"
mv <outdir>/release.zip <outdir>/<id>-<version with dots replaced by dashes>.c3addon
```

5. Report the output path and file size. If the version was bumped, also report the old → new version (so the user knows to commit `src/addon.json`).
