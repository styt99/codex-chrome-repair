# Chrome Xiufu

`chrome-xiufu` is a Windows repair skill for Codex Desktop's `chrome@openai-bundled` control path. It is intended for cases where Codex can connect to Chrome but navigation, DOM snapshots, screenshots, scrolling, or history navigation are unreliable.

## What It Does

- Inspects the complete active Chrome and Browser plugin layout before changing anything.
- Resolves the active plugin version from `latest/.codex-plugin/plugin.json`; it never pins a version.
- Checks cache, marketplace, Browser service, native-host, extension, and runtime trusted-service state.
- Applies only exact, known compatibility patches when the corresponding broken pattern is present.
- Covers ARIA snapshot fallback, site-status timeouts, cached CDP expressions, focus/OOPIF waits, navigation timeouts, mouse-wheel scrolling, history navigation, and read-only response-meta latency.
- Verifies every write by reading the file back and runs `node --check` against every patched target.
- Requires a real Chrome smoke/full ACK before reporting complete recovery.

## Safety Boundaries

This is a patch-only repair workflow. It does not install, add, synchronize, replace, downgrade, or pin a plugin version. It does not modify Chrome profiles, cookies, passwords, user data, or `C:\Program Files\WindowsApps`.

If the active manifest is missing, malformed, or mismatched with a candidate copy, the version gate stops without writing. If runtime trusted-service configuration is absent or stale, the skill reports that state and uses only explicitly version-gated fallback candidates; it never guesses by directory timestamp.

## Use

Run the normal check-then-repair flow from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1"
```

Run inspection only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -VerifyOnly
```

Use `-Detailed` only when a failure needs file-level diagnostics. The default output intentionally omits cache paths, hashes, duplicate copies, and backup paths.

## Required Workflow

1. Inspect the environment, plugin manifests, extension, native host, all matching cache/marketplace copies, and runtime trusted-service configuration.
2. Classify the symptom as a capability failure, slow-but-successful operation, cold-start cost, or target-site transient.
3. Research official OpenAI/Codex documentation and public GitHub sources only when no tracked pattern explains the issue, the symptom is intermittent, upstream code changed shape, or a more stable official mechanism may exist.
4. Apply exact matching patches only after the full diagnosis and version gate pass.
5. Reset the Node runtime or extension host after any write.
6. Run the real Chrome smoke/full ACK in separate operations and record timings, evidence, and before/after comparisons.

## ACK Gate

The report progresses through:

`PATCH_READY -> RECONNECT_REQUIRED -> ACK_REQUIRED -> ACK_PASSED`

Static inspection is not a live ACK. `ACK_PASSED` requires successful navigation, page reads, DOM snapshot, screenshot, scrolling, interaction, and repeated history back/forward checks with correct page evidence. Missing live evidence must remain `ACK_REQUIRED`; it must never be fabricated.

## Package Contents

- `SKILL.md`: full operating procedure and diagnostic rules.
- `scripts/repair-chrome-xiufu.ps1`: deterministic inspection, patching, version gating, and syntax verification.
- `agents/openai.yaml`: Codex skill metadata.
- `README.md`: English overview.
- `README.zh-CN.md`: Chinese overview.

## Known Baseline

The verified history-navigation repair reduced `goBack` and `goForward` from roughly ten seconds per call to sub-100 ms on the Selenium test pages. Other tracked patches have no universal pre-repair timing; reports must say `no pre-repair data` instead of estimating.

## Rollback

During an active repair, the script creates a timestamped backup beside each file it changes. Restore the matching backup to its original path, then restart Codex/extension-host and rerun the smoke test. Backups are operational artifacts, not part of this published package.

