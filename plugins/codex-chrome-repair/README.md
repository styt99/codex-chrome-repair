# Codex Chrome Repair

This plugin packages the `chrome-xiufu` skill under the general English publication name `Codex Chrome Repair` for Codex Desktop on Windows.

Read the [Chinese guide](README.zh-CN.md) or the full [skill instructions](skills/chrome-xiufu/SKILL.md). The skill diagnoses the complete Chrome/Browser control path, applies only exact known compatibility patches, follows the active official plugin version dynamically, and requires a real Chrome ACK before reporting recovery.

The package version in `.codex-plugin/plugin.json` is the version of this published bundle. It is intentionally independent of the official `chrome@openai-bundled` runtime version.

## Verified current ACK data

The following current-run data was collected with Chrome plugin version `26.820.60940` on Selenium test pages. Only history navigation has a measured pre-repair baseline; all other rows intentionally say `no pre-repair data` rather than estimating it.

| Operation | Before | Current result | Status |
| --- | ---: | ---: | --- |
| Cold navigation | no pre-repair data | 1,149.9 ms | passed |
| Warm navigation | no pre-repair data | 1,061.6 ms | passed |
| URL / title | no pre-repair data | 3.6 / 3.2 ms | passed |
| Evaluate / DOM snapshot / screenshot | no pre-repair data | 119.8 / 103.0 / 117.3 ms | passed |
| Fill / key press / submit click | no pre-repair data | 59.1 / 35.6 / 3,012.0 ms | passed |
| Scroll / confirmation | no pre-repair data | 3,037.3 ms dispatch; 700 px confirmed after a 2.2 s settle window | passed |
| Back | mean 10,048.7 ms | 71.6–104.2 ms, 3/3 | passed |
| Forward | mean 10,048.4 ms | 60.7–103.3 ms, 3/3 | passed |
| Temporary-tab cleanup | no pre-repair data | 60.2 ms; 0 controlled tabs | passed |

Scroll command completion alone is insufficient evidence: this runtime may apply the wheel event after a short delay, so the ACK requires a separate scroll-position confirmation.


