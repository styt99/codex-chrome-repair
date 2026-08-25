---
name: chrome-xiufu
description: Diagnose and repair Codex Desktop Chrome plugin takeover failures on Windows, especially when chrome@openai-bundled connects to Chrome but tab.goto stays on about:blank, DOM snapshot fails with incrementalAriaSnapshot errors, screenshots/evaluate/scroll/download are flaky, the bundled marketplace or cache drifts after restart, native-host paths are stale, or the user asks to fix Chrome plugin control without reinstalling.
---

# Chrome Xiufu

Use this skill for fragile Windows repair of `chrome@openai-bundled`. Prefer repair over uninstall/reinstall when the extension is installed and Codex can see Chrome but cannot fully control pages.

## Core Rules

- Use the `chrome:control-chrome` skill first for Chrome runtime work, and read its `SKILL.md`.
- Use the Node REPL `js` tool to load `scripts/browser-client.mjs` from the Chrome plugin cache. Do not use external Playwright.
- Do not edit `C:\Program Files\WindowsApps`.
- Do not destroy user Chrome data or reset Chrome profiles.
- Back up any patched plugin file before editing.
- After writing a patched file, read it back and compare against the intended content. A sandboxed or permission-restricted write can fail without raising an error, which makes the repair report success while the file on disk is unchanged. Refuse to patch a file whose backup could not be created. Both conditions are write-permission problems, not version problems.
- Inspect both `scripts\browser-client.mjs` and `scripts\browser-service.mjs` in the active cache and every available persistent marketplace copy. Patch only files that contain an exact known-broken pattern.
- For Chrome sessions, also inspect the matching `browser@openai-bundled` `scripts\browser-service.mjs` copies. The Node REPL trusted service is selected from `NODE_REPL_TRUSTED_SERVICES` and can be the Browser plugin service even when the user invokes Chrome; patching only the Chrome directory can leave `cua.scroll()` on the old implementation.
- Resolve the user home directory from `$env:USERPROFILE`, falling back to `$env:HOMEDRIVE` + `$env:HOMEPATH`, and only then to `GetFolderPath`. Under a sandboxed Codex process `GetFolderPath("UserProfile")` can return a synthetic path such as `C:\Users\CodexSandboxOffline`, which makes every plugin file look absent. Validate each candidate by confirming a `.codex` directory exists inside it.
- An environment-resolution failure is never evidence of a missing or broken plugin version. Report it as an environment problem and stop; do not conclude that files are missing, and do not install, add, or sync anything.
- Never hard-code a plugin version anywhere in this skill or its scripts. Always read the active version from `latest\.codex-plugin\plugin.json`.
- Verify with real Chrome actions before declaring success.

## Check First, Then Repair

Always run checks before changing files. The repair script follows this order:

1. Inspect plugin, manifest, Chrome extension, cache, marketplace, and `browser-client.mjs`.
2. Print a diagnosis with detected symptoms and recommended actions.
3. If not in `-VerifyOnly` mode, apply only the patches whose exact broken patterns are present.
4. Back up each edited file before writing.
5. Run syntax checks and print the final status.

Run the default check-then-repair flow when the symptoms match this skill:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1"
```

For inspection only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -VerifyOnly
```

Normal output is intentionally concise. It reports the diagnosis, repair result,
syntax-check result, drift status, reconnect requirement, and final ACK status;
it does not print cache paths, duplicate marketplace copies, hashes, or backup
paths. Use `-Detailed` only when a failure needs file-level investigation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -VerifyOnly -Detailed
```

The detailed mode is diagnostic output only. It does not change which files are
eligible for repair and does not bypass the dynamic version safety gate.

The script checks plugin state, native-host manifest, active cache paths, version manifests, and syntax, then applies only compatibility patches whose exact broken patterns are present:

- `incrementalAriaSnapshot` fallback to `_renderAriaSnapshot`
- bypass of the remote `site_status` check that can block navigation before `chrome.tabs.update`, including the known `Gd`, `rp`, `bp`, and `cd` minified variants
- bounded `site_status` fetch and proxy timeouts
- disabling unsupported cached-CDP expression reuse
- bounded focus-emulation and OOPIF auto-attach waits
- a longer navigation timeout for slow pages
- mouse-wheel CDP scrolling when `Input.synthesizeScrollGesture` is unreliable
- history back/forward completion waiting on a navigation event instead of a full `load` event
- a read-only-command short-circuit before response-meta tab enrichment

The repair script is version-dynamic. It reads the active version from `latest\.codex-plugin\plugin.json`; it does not contain a fixed plugin version. Older cache-version directories are ignored rather than selected by modification time.

### Locate the whole problem before repairing

Partial diagnosis is the main failure mode of this skill. Do not patch after finding the first matching pattern. Complete all of the following before the first write:

1. Resolve and print the environment (home, local app data). Stop on failure.
2. Resolve the active version dynamically and enumerate every candidate copy: Chrome cache, Chrome marketplace, Browser cache, Browser marketplace, and the pinned trusted service.
3. Read `NODE_REPL_TRUSTED_SERVICES`, `NODE_REPL_TRUSTED_SERVICE`, or `NODE_REPL_TRUSTED_CODE_PATHS` when exposed by the running environment. Resolve only explicit service files or explicit roots that contain a service file, then apply the same active-version gate. If the value is absent, stale, or cannot be resolved, report `runtime trusted service path unknown` and keep the version-gated candidate set as a fallback; never guess a path from directory timestamps.
4. Evaluate every tracked pattern against every candidate, and print a per-file `needs`/`present` line for all of them.
5. Print the cache/marketplace drift comparison.
6. Only then decide what to write.
7. Probe the running system before patching when Chrome is reachable: run the smoke test operations and record each elapsed time. Static checks alone cannot tell a broken capability from a slow one.

Classify every timing before calling anything broken: capability fails, capability works but is slow, first-connection cold start, or target-site transient. A first navigation on a fresh session or right after a model switch can land in the 7–26 second range; that is cold-start cost and must not trigger a patch.

State each finding in four parts: symptom, root-cause hypothesis, evidence, intended action. When the evidence does not support a hypothesis, mark it `UNKNOWN` and move to research instead of patching speculatively.

### Cache/marketplace drift

"It worked, then a restart or a version bump broke it again" is almost always drift: the running cache copy carries the patches while the persistent marketplace source does not, so any refresh restores unpatched code. The script groups every candidate by plugin and script name, compares the cache copies against the marketplace copies flag by flag, and also compares SHA-256 so content differences outside the tracked patterns are still reported. Identical-content copies are collapsed, because `latest` and the pinned version directory can be the same bytes.

Treat drift as a first-class diagnosis, not a footnote. When drift is present, patch the matching-version marketplace copies too, otherwise the repair will not survive the next update.

### When to research instead of guessing

Research, do not improvise, when any of these hold:

- No tracked pattern explains the observed symptom.
- A symptom is intermittent rather than reproducible, so the current fix may be addressing the wrong layer.
- The upstream code changed shape, so a tracked pattern no longer matches and needs re-derivation.
- There is reason to believe a more stable official mechanism now exists (an added option, timeout, or API) that would replace a local patch.

Scope of research: official Codex/OpenAI documentation and public GitHub pages (repository code, issues, pull requests, release notes). Read public pages directly; do not open a browser session to do it. Prefer an official option over a local patch whenever one exists, since official behavior survives updates and a patch does not.

Stop condition: if research finds no better mechanism, say so explicitly and proceed with the pattern patch. If research finds a better mechanism, describe the tradeoff before switching.

### New upstream behavior

When a version bump changes upstream code, a tracked pattern can be absent for two very different reasons: upstream already fixed it, or upstream rewrote it and the pattern needs updating. Distinguish them before concluding anything. Check whether the intended behavior is already present under a different shape (a different symbol, an added timeout, a new option). If upstream fixed it, retire the pattern rather than forcing it back in. If upstream merely renamed or restructured, re-derive the exact string from the current file and confirm the new patch introduces no symbol that does not already exist in that file.

### Version safety gate

Xiufu is a patch-only repair skill. It must never install, add, sync, replace, or downgrade a plugin. Before modifying any `browser-client.mjs`, determine the active Chrome plugin version from:

```text
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\latest\.codex-plugin\plugin.json
```

Only patch cache and marketplace copies whose `.codex-plugin\plugin.json` version exactly matches the active `latest` version. If the active version is missing, malformed, or any candidate copy has a different version, stop without changing files and report the mismatch. Never select a version directory by modification time alone.

Do not invoke `repair-codex-bundled-plugins.ps1` from this skill. That separate wrapper may run `codex plugin add chrome@openai-bundled` or rebuild the marketplace from a stale source, which can roll back a working environment. Marketplace repair or plugin installation requires a separate explicit authorization and an independent version check first.

Before any non-verify repair, print the active version and all target versions, create a timestamped `.bak` beside every file that will change, and abort if the version check is not exact.

## Diagnostic Flow

1. Check plugin and native-host state:

```powershell
codex plugin list | Select-String -Pattern 'Marketplace `openai-bundled`|chrome@openai-bundled|browser@openai-bundled|computer-use@openai-bundled'
Get-Content "$env:LOCALAPPDATA\OpenAI\extension\com.openai.codexextension.json"
```

2. Confirm the active Chrome extension is installed:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions\hehggadaopoacecdllhhajmbjkdcmajg" -Directory -ErrorAction SilentlyContinue
```

3. If `latest` is missing or incomplete, stop this skill and report that the active plugin cache is incomplete. Do not let Xiufu rebuild the marketplace or install a plugin. A separate, explicitly authorized Windows plugin-repair workflow is required, and it must first confirm the new active version before any repair:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\repair-codex-windows-plugins\scripts\repair-codex-bundled-plugins.ps1" -SkipChromeAdd -SkipComputerUseAdd
```

4. Stop stale extension-host processes before patching if files are locked:

```powershell
Get-Process extension-host -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\*" } | Stop-Process -Force
```

5. Run the quick repair script, then syntax check:

```powershell
node --check "$env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\latest\scripts\browser-client.mjs"
```

## Chrome Smoke Test

After repair, reset or reconnect the Node REPL and run the supported Chrome setup from `chrome:control-chrome`.

Run each browser operation below in a separate `js` call. In some current Chrome-plugin versions, navigation, DOM reads, and screenshots can each take roughly 20–25 seconds even when they succeed. Combining the sequence in one call can exceed the default call limit, reset the session, and falsely look like a DOM or screenshot failure. Record the timing and evidence for each separate operation.

```js
await browser.nameSession("Chrome xiufu smoke test");
const tab = await browser.tabs.new();
```

```js
await tab.goto("https://example.com/");
```

```js
await tab.goto("https://www.selenium.dev/selenium/web/simpleTest.html");
```

```js
await tab.goBack();
await tab.url();
```

```js
await tab.goForward();
await tab.url();
```

```js
await tab.url();
await tab.title();
```

```js
await tab.playwright.evaluate('() => ({href: location.href, title: document.title, h1: document.querySelector("h1")?.textContent || null})', undefined, { timeoutMs: 5000 });
```

```js
await tab.playwright.domSnapshot();
```

```js
await tab.screenshot({ fullPage: false });
```

```js
await tab.cua.scroll({ x: 1000, y: 600, scrollY: 600, scrollX: 0 });
```

```js
await browser.tabs.finalize({ keep: [] });
```

Expected signals:

- `tab.goto("https://example.com/")` resolves.
- `tab.url()` returns `https://example.com/`.
- `domSnapshot()` includes `Example Domain`.
- Screenshot returns image bytes.
- Scroll does not throw on a scrollable page.
- `goBack()` and `goForward()` each resolve in well under one second and land on the expected URL. Roughly 10 000 ms per call with a correct URL is the unpatched history-navigation path, not a slow network.
- A single operation that resolves after roughly 20–25 seconds is slow but successful. Diagnose a real failure only when an individual operation times out, resets the session, returns empty/incorrect page evidence, or fails to apply the requested action.

## Full ACK test and before/after comparison

The smoke test above proves the plugin responds. A full ACK run proves it is stable. Run the full pass after any repair, and after any model switch, since the first connection on a new session exercises paths a warm session does not.

Cover each capability group, one `js` call per operation, recording elapsed milliseconds for every operation:

- session and tab lifecycle: name session, open tab, finalize
- navigation: first navigation on a cold session, then a warm navigation
- page reads: `url`, `title`, `evaluate`, `domSnapshot`
- screenshot
- human-like interaction: click, type, key press, scroll
- history: `goBack`, `goForward`
- repeat the history and read operations at least three times each, because instability shows up as variance, not as a single failure

Rules for the comparison output:

- Report per-operation timings plus mean, and pass/fail counts such as `3/3`.
- Compare against the baseline below. Where no pre-repair measurement exists, write "no pre-repair data" rather than estimating. Never fabricate a before number.
- Distinguish a plugin defect from a target-site problem. A slow or failing load on one site, where another site succeeds on the same tab, is a site problem; switch sites and note it.
- Treat these as non-priority and out of scope unless the user asks: native JS dialogs, clipboard access, and real file-upload submission.
- Use a fixed table with the columns `Operation | Before | After | Status | Data source`, so every number is traceable to a measurement or to the baseline in this file.
- For operations whose timings vary between runs, report the range and explain the variance. A mean alone hides the instability that matters.
- Close the report with: which files changed, how the dynamic version gate resolved, the backup paths, how to roll back, and which operations are known-slow but functionally correct.

### ACK state gate

Use these states in the repair report and do not skip forward:

```text
PATCH_READY -> RECONNECT_REQUIRED -> ACK_REQUIRED -> ACK_PASSED
                                              \-> ACK_FAILED
```

- `PATCH_READY` means static inspection, version gating, writes, read-back, and syntax checks passed. It is not proof that Chrome is usable.
- `RECONNECT_REQUIRED` means the Node runtime/extension host must be reset after any file change. Do not reuse a stale browser binding for the final test.
- `ACK_REQUIRED` means the repair is waiting for the real Chrome smoke/full ACK. A script-only `-VerifyOnly` result can never advance beyond this state.
- `ACK_PASSED` is allowed only after the live operations in this skill complete with the required URL/DOM/screenshot/interaction/history evidence. Only then may the final report say “fully restored” or equivalent.
- `ACK_FAILED` requires reporting the failed operation and its timing/evidence, then returning to diagnosis or research. Never convert a timeout, missing evidence, or skipped live test into success.

If Chrome is unavailable, explicitly stop at `RECONNECT_REQUIRED` or `ACK_REQUIRED` and state the next required action. Do not fabricate an ACK result or reuse an old result as the current run.

### Baseline (measured, plugin version read dynamically at test time)

History back/forward, before and after the history-navigation patch:

| Operation | Before | After | Change |
| --- | --- | --- | --- |
| `goBack` | mean 10 048.7 ms | 50.4–60.7 ms, mean 54.4 ms | −99.43 % |
| `goForward` | mean 10 048.4 ms | 54.3–67.1 ms, mean 60.4 ms | −99.43 % |

3/3 success, URL switched correctly on every attempt. Test pages: `https://www.selenium.dev/selenium/web/simpleTest.html` and `xhtmlTest.html`.

First navigation on a cold session stays in the multi-second range because the connection and target attach happen once; subsequent navigations in the same session are much faster. That first-hit cost is expected, not a defect.

Other tracked patches have no recorded pre-repair measurement; report them as "no pre-repair data" with their post-repair timings.

## Symptom Map

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| A navigation reports `net::ERR_FAILED`, while the tab remains listed, the final URL is not `about:blank`, and a focused retry returns a real DOM | Target-site or network transient, not a Chrome takeover failure by itself | Record `PAGE_NETWORK_TRANSIENT`; do not patch or reinstall the plugin. Re-test once on the same dedicated tab, then route through `browser-runtime-maintenance` if the failure persists |
| `domSnapshot()` throws `TypeError: ... incrementalAriaSnapshot is not a function` | `browser-client.mjs` expects a newer injected Playwright object than the extension provides | Apply fallback patch to `_renderAriaSnapshot` |
| `tab.goto()` times out and tab stays `about:blank` | Remote `site_status` check times out before navigation dispatch | Apply site-status bypass patch |
| `browser.documentation()` fails because files are missing | Chrome plugin cache is incomplete after restart | Stop Xiufu and use a separately authorized Windows plugin-repair workflow; then rerun the version gate |
| `cua.scroll()` moves the page but times out on `Input.synthesizeScrollGesture` | The trusted Browser service may still own the scroll implementation | Inspect and patch matching-version Chrome and Browser `browser-service.mjs` copies to use mouse-wheel CDP dispatch |
| `tab.goBack()` / `tab.goForward()` each take about 10 s but land on the correct URL | After `Page.navigateToHistoryEntry` the service awaits a full `load` event; a BFCache restore never fires one, so it waits out the default 10 000 ms timeout | Apply the history back/forward patch so completion waits on `Page.frameNavigated` / `Page.navigatedWithinDocument` with a bounded 2 000 ms cap |
| Read-only commands such as DOM snapshot or screenshot carry extra seconds of tail latency | Response-meta tab enrichment runs even for commands that do not need it | Apply the response-meta short-circuit so commands already listed in the read-only set return before enrichment |
| Every plugin file appears missing, or paths point at a user profile the user does not recognize | Home-directory resolution fell back to `GetFolderPath` inside a sandboxed process | Fix environment resolution and re-run. Report as an environment problem, not a missing version. Do not install or sync |
| The script reports the Chrome extension directory as incomplete, yet Chrome shows the extension working | Enumeration of the Chrome profile was denied while `Test-Path` still succeeded, so an empty result was mistaken for an empty directory | Treat as a read-permission problem. The script now separates "cannot enumerate (read permission)" from "no version dirs" and refuses to diagnose the extension as incomplete on that basis. Do not install, add, or sync |
| The script prints `Patched` but the symptom persists and `-VerifyOnly` still reports the same `needs=True` | The write was silently blocked, so the file on disk never changed | Compare file size and hash before and after. Obtain write access to the cache and marketplace paths, then re-run. The script now verifies each write and exits with code 4 instead of reporting a false success |
| Chrome listed but commands hang after patch | Old extension-host or Node session loaded stale code | Stop `extension-host.exe`, reset Node REPL, reconnect |
| Works until restart then breaks again | Active cache or a matching-version persistent marketplace copy was not patched | Run `-VerifyOnly` and patch all matching-version `browser-client.mjs`/`browser-service.mjs` copies; never sync an older marketplace |
| `Browser is not available: chrome` and the native-host check reports `correct: false` | Chrome Native Messaging registration or extension communication is unavailable | Do not patch plugin code; restore/re-enable the Browser plugin through Codex **Settings → Computer use**, then rerun the native-host check |

## After a Codex update

Never assume the previous plugin version remains active. First run:

```powershell
codex plugin list | Select-String -Pattern 'browser@openai-bundled|chrome@openai-bundled|computer-use@openai-bundled'
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -VerifyOnly
```

Continue only when the active `latest` manifest and the selected cache/marketplace copies report the same version. If the script prints `VERSION SAFETY GATE: STOP`, do not run a repair, `codex plugin add`, marketplace sync, or downgrade command.

## Rollback

The repair script creates timestamped `*.bak` files next to every patched `browser-client.mjs` or `browser-service.mjs`. To roll back, restore the matching backup to the same path, then restart Codex/extension-host before live retesting.

## Exit codes

| Code | Meaning | Action |
| --- | --- | --- |
| 0 | Inspection or repair completed | Continue to the smoke test or full ACK run |
| 1 | A patched file failed `node --check` | Restore the matching `.bak` immediately, then re-derive the pattern |
| 2 | Version safety gate stopped the run | Do not repair, install, sync, or downgrade. Re-check the active version |
| 3 | Environment resolution failed | Fix home / local-app-data resolution. Not a version problem |
| 4 | A backup or a patch write could not be completed | Grant write access to the cache and marketplace paths, then re-run |

## Out of scope

These are deliberately not repaired here, and the reason matters when deciding whether to revisit them:

- Native JavaScript dialogs (`alert`, `confirm`, `beforeunload`). Treated as non-priority: they are rare in normal use, and the one reproducible case (a dialog raised during file upload) was already resolved.
- Clipboard access and real file-upload submission. Non-priority, and submission touches remote state.
- Marketplace rebuilds and plugin installation. Requires separate explicit authorization; a stale source can roll back a working environment.

A dialog-handling patch is not carried in this skill because it has not been shown to produce a behavioral difference against the current unpatched files, and it ranks below the latency and stability work. If a reproducible dialog failure appears, re-derive it rather than assuming it is unfixable.

