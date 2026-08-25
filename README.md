# Codex Chrome Repair Plugin

This repository follows the current Codex plugin layout used by the public `openai/plugins` repository.

```text
.agents/plugins/marketplace.json
plugins/codex-chrome-repair/
├── .codex-plugin/plugin.json
├── skills/chrome-xiufu/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── scripts/repair-chrome-xiufu.ps1
├── README.md
└── README.zh-CN.md
```

## Install In Codex

### Codex App

Open **Plugins** in the Codex sidebar, add the GitHub marketplace/repository, then install **Codex Chrome Repair**. Restart Codex after installation or an update so skill metadata is reloaded.

### Codex CLI

Use the plugin search interface:

```text
/plugins
```

Search for `codex-chrome-repair` and select **Install Plugin**. The skill inside the plugin remains addressable as `$chrome-xiufu` for compatibility with the existing local workflow. For a local checkout, add the repository marketplace explicitly and then install the plugin named in its marketplace manifest:

```powershell
codex plugin marketplace add "C:\path\to\shiny-happiness"
codex plugin install codex-chrome-repair@chrome-xiufu-marketplace
```

The explicit marketplace command is for this repository's `.agents/plugins/marketplace.json`; it is not needed for the default personal marketplace.

### Manual Installation

For a manual fallback, copy `plugins/codex-chrome-repair/skills/chrome-xiufu` to:

```text
%USERPROFILE%\.codex\skills\chrome-xiufu
```

The target folder must contain `SKILL.md` directly. Do not copy `.bak` files, plugin caches, or Chrome profile data. Restart Codex afterward.

## Update and Verify

After an update, run `repair-chrome-xiufu.ps1 -VerifyOnly`, then reconnect Chrome and run the real smoke/full ACK. The plugin package version (`0.1.0`) identifies this published bundle; it does not pin the official Chrome plugin version. The repair skill reads the active Chrome version dynamically from `latest/.codex-plugin/plugin.json`.

## Verified Before/After Data

The following values are from real Chrome ACK runs on the Selenium test pages.
Only history navigation has a measured pre-repair baseline; other operations
are explicitly marked as having no pre-repair data.

| Operation | Before | After | Status | Data source |
| --- | ---: | ---: | --- | --- |
| Cold navigation | no pre-repair data | 6,284 ms | Pass | Chrome ACK recheck |
| Warm navigation | no pre-repair data | 6,536 ms | Pass | Chrome ACK recheck |
| URL / title | no pre-repair data | 3 / 3 ms | Pass | Chrome ACK recheck |
| Evaluate | no pre-repair data | 36 ms | Pass | Chrome ACK recheck |
| DOM snapshot | no pre-repair data | 109 ms | Pass | Chrome ACK recheck |
| Screenshot | no pre-repair data | 97 ms, 65,970 bytes | Pass | Chrome ACK recheck |
| Scroll | no pre-repair data | 17 ms | Pass | Chrome ACK recheck |
| Fill / keypress / click | no pre-repair data | 52 / 28 / 428 ms | Pass | Form ACK recheck |
| Submitted DOM | no pre-repair data | 37 ms | Pass | Form ACK recheck |
| `goBack` | mean 10,048.7 ms | 38–59 ms, 3/3 | Pass, about 99.5% lower | Historical baseline + ACK recheck |
| `goForward` | mean 10,048.4 ms | 37–44 ms, 3/3 | Pass, about 99.6% lower | Historical baseline + ACK recheck |

Cold and warm navigation remain multi-second operations because connection and
page attachment happen during navigation. They are slow-but-successful, not a
plugin failure. History operations are the measured latency fix: every attempt
landed on the expected URL.

## Safety

This plugin never installs, downgrades, synchronizes, or replaces the official Chrome plugin. It does not modify Chrome profiles, credentials, user data, or `C:\Program Files\WindowsApps`. It patches only exact known-broken patterns after diagnosis and version gating.

## References

- [OpenAI plugins](https://github.com/openai/plugins)
- [OpenAI skills](https://github.com/openai/skills)
- [Awesome Codex Skills](https://github.com/composio-community/awesome-codex-skills)
- [Codex Skills documentation](https://developers.openai.com/codex/skills)
- [Build Codex plugins](https://developers.openai.com/codex/plugins/build)

