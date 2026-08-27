---
name: chrome-xiufu
description: Diagnose and safely repair Codex Desktop Chrome control failures on Windows when the bundled Chrome plugin connects but navigation, DOM, screenshot, interaction, scrolling, history, or session release is broken. Use after Codex/plugin updates or intermittent failures; do not use to bypass website safety policy or change Chrome user data.
---

# Chrome Xiufu

Restore `chrome@openai-bundled` control only when runtime evidence identifies a plugin compatibility defect. Diagnose first, write only with explicit authorization, and require a fresh live ACK before saying recovery is complete.

## Absolute safety boundary

- Never change, bypass, weaken, intercept, proxy, or time out website safety decisions, including `site_status`, `check-url-site-status`, `/aura/site_status`, allowlists, blocklists, origin checks, confirmation logic, approval logic, or security-mode settings.
- `Browser use is not permitted on <URL>` is a policy result, not a Chrome takeover defect. Stop attempts on that URL and use the product's supported Settings/approval flow or user-supplied content. A successful permitted-site ACK separates policy from toolchain failure.
- Never modify Chrome profiles, cookies, credentials, browsing history, extension permissions, user tabs, `C:\Program Files\WindowsApps`, or unrelated Codex configuration.
- Never install, add, sync, downgrade, pin, or publish a plugin from this skill.
- Never write marketplace copies. They are read-only, same-version comparison or restoration sources.
- Do not edit a Browser plugin by inference. The sole exception is an explicit `NODE_REPL_TRUSTED_SERVICES` configuration path whose script belongs to `browser@openai-bundled`, exactly matches the active Chrome version, and is proven by the failing capability to be the active service. It remains subject to the same explicit `-Repair -PatchId` gate.
- Never terminate `extension-host`, Chrome, or Codex processes unless the user separately authorizes the exact process action after ownership is verified. Prefer a normal reconnect or restart.
- Do not create persistent backups, logs, caches, receipts, or temporary artifacts. The script stages changes under the system temporary directory, rolls back written files on handled failure, and removes staging files in `finally`.

If the active plugin contains a known old Xiufu site-policy bypass marker, report `SECURITY_INTEGRITY_FAILED` and stop. Do not add another patch on top. Only an explicitly authorized `-RestoreOfficialCache` from one exact same-version clean marketplace source may restore the active cache.

## Operating states

```text
INSPECT_ONLY
  -> PATCH_AUTH_REQUIRED
  -> PATCH_READY
  -> RECONNECT_REQUIRED
  -> ACK_REQUIRED
  -> ACK_PASSED | ACK_FAILED
```

Static inspection never proves live Chrome behavior. Only a fresh ACK in the current runtime can reach `ACK_PASSED`.

## Diagnose before repair

1. Read the current `chrome:control-chrome` skill before live browser work.
2. Run the local script in inspection mode. Its default behavior is read-only.
3. Resolve the active Chrome plugin version from `chrome\latest\.codex-plugin\plugin.json`; never select a version by timestamp or hard-code one.
4. Inspect both active Chrome scripts, native-host state, every Chrome profile that contains the control extension, and any explicitly configured trusted-service path. A missing optional Browser plugin is not by itself a Chrome version failure; an exact, same-version configured Browser service is a repair target only when runtime evidence proves it owns the failure.
5. Hash files before and after inspection. `No files changed`, equal hashes, no new backup files, and clean temporary staging establish non-mutation; they do not establish live success.
6. Classify the symptom as one of: plugin capability failure, slow-but-successful operation, cold connection, target-site/network transient, site-policy result, environment/read-permission issue, or `UNKNOWN`.
7. State symptom, hypothesis, evidence, and intended action. Do not select a patch merely because its old minified string exists.

Run inspection:

```powershell
powershell -NoProfile -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -VerifyOnly -Detailed
```

`-VerifyOnly` is a compatibility alias for the default inspection-only mode. It never enters a write path.

## Research gate

Research official OpenAI/Codex documentation and public GitHub code, issues, pull requests, and release notes before editing when:

- no tracked defect explains the reproduced failure;
- the failure is intermittent or differs across sites;
- an update changed the minified code shape;
- the trusted runtime service is unclear;
- an official option may replace a local compatibility patch.

Prefer the official mechanism. If research does not establish a safe fix, report `UNKNOWN` and stop; absence of evidence is not permission to broaden the patch.

## Explicit repair gate

The script has no automatic or blanket repair mode. A write requires both `-Repair` and one or more explicit `-PatchId` values:

```powershell
powershell -NoProfile -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -Repair -PatchId aria-snapshot
```

Select a patch only when the current runtime reproduced its exact symptom and the active version contains the exact tracked source pattern:

| Patch ID | Required evidence |
| --- | --- |
| `aria-snapshot` | `domSnapshot()` throws an `incrementalAriaSnapshot` compatibility error |
| `cached-cdp` | current logs prove cached-expression negotiation fails and an uncached call succeeds |
| `focus-timeout` | a reproduced focus-emulation call hangs while the surrounding operation otherwise succeeds |
| `oopif-timeout` | logs identify OOPIF auto-attach as the bounded wait causing the failure |
| `scroll-wheel` | the active Chrome service uses `Input.synthesizeScrollGesture`, the scroll request fails there, and ordinary wheel dispatch is verified compatible |
| `history-navigation` | back/forward reaches the correct URL only after waiting for a missing full-load event; navigation-event completion is verified |

The script rejects an unknown pattern, stages every selected change, syntax-checks staged files, verifies read-back, syntax-checks the result, and rolls back all files already written if a handled failure occurs. It writes the active Chrome cache and, only under the exact configured-service gate above, the matching active Browser service. It never edits a marketplace copy.

Do not reintroduce the retired patches for site-policy bypass, site-status proxy/timeout, global navigation timeout, response-meta short-circuit, swallowed scroll errors, or swallowed history errors.

## Restore an unsafe legacy cache

Use restoration only when static inspection identifies an old unsafe Xiufu modification and exactly one distinct clean source exists for each active script at the same dynamically resolved version:

```powershell
powershell -NoProfile -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -RestoreOfficialCache
```

This action replaces only selected active cache scripts with reviewed same-version marketplace bytes. It does not write the marketplace, install a plugin, modify settings, or change a version. If a clean source is absent, duplicated with different hashes, fails syntax validation, or contains a known unsafe marker, stop without writing.

## Reconnect and live ACK

After any active-cache write, reconnect the Chrome control runtime normally. Do not reuse a binding that loaded pre-write code.

Every ACK owns only temporary test tabs created by `chrome.tabs.new()`. Never claim or reuse an existing user tab, and never call `markHandoff()` or `markDeliverable()` for ACK tabs.

```js
await chrome.nameSession("Chrome xiufu ACK");
let ackTab;
let cleanupError;
try {
  ackTab = await chrome.tabs.new();
  // Run one measured ACK operation per call against ackTab.
} finally {
  if (ackTab) {
    try { await ackTab.close(); } catch (error) { cleanupError = error; }
  }
}
if (cleanupError) throw cleanupError;
const controlledTabs = await chrome.tabs.list();
```

After cleanup, `chrome.tabs.list()` must contain no ACK tab and no tab controlled by this test. Do not enumerate all user tab metadata for routine ACK cleanup. If cleanup fails, report `RELEASE_FAILED`, include the confirmed test-tab identifier and error, and set `ACK_FAILED`.

Use permitted, non-sensitive test pages. Treat a site-policy rejection as a stop result, not a reason to switch surfaces or bypass controls. Keep each operation separate and record elapsed milliseconds plus page evidence:

- name session and create temporary tab;
- cold navigation, then warm navigation;
- URL and title;
- evaluate and DOM snapshot;
- screenshot;
- click, type, key press, and scroll. For `cua.scroll`, wait at least 2.2 seconds before a separate `window.scrollY` confirmation: command success alone is not scroll success. Record both dispatch time and confirmation evidence;
- back and forward, repeated at least three times;
- close the temporary tab and verify controlled-tab count is zero.

Cold navigation can be slower than warm navigation. A correct result that is slow is not a failure; record the range. A target-site failure with successful permitted control-site evidence is not a general plugin failure.

## Report discipline

Use `Operation | Before | After | Status | Data source`. Where no current pre-repair measurement exists, write `no pre-repair data`; never reuse an old run as current evidence.

Historical reference only: one earlier Selenium run measured `goBack` at mean `10,048.7 ms` before and `50.4-60.7 ms` after, and `goForward` at mean `10,048.4 ms` before and `54.3-67.1 ms` after, each `3/3`. These numbers are not a guarantee for another version or session.

The final report must include:

- current active version and version-source path;
- diagnosis and evidence;
- exact local skill files changed;
- exact official plugin files changed, or `0`;
- marketplace files changed (`0` by design);
- persistent artifacts created (`0` by design);
- before/after official-plugin hashes;
- syntax and skill-validation results;
- ACK state and current-run evidence, or an explicit statement that ACK was not run.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | inspection or authorized action completed |
| `1` | JavaScript syntax check failed |
| `2` | invalid mode or missing explicit patch authorization |
| `3` | real user environment could not be resolved |
| `4` | version, clean-source, or exact-pattern gate failed |
| `5` | transactional write failed; handled writes were rolled back |
| `6` | known site-policy bypass marker detected |
| `7` | another unsafe legacy Xiufu modification detected |

