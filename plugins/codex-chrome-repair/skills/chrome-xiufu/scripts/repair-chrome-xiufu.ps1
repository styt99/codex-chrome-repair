[CmdletBinding()]
param(
  [switch]$VerifyOnly,
  [switch]$Detailed,
  [switch]$Repair,
  [ValidateSet("aria-snapshot", "cached-cdp", "focus-timeout", "oopif-timeout", "scroll-wheel", "history-navigation")]
  [string[]]$PatchId = @(),
  [switch]$RestoreOfficialCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section([string]$Name) { Write-Host ""; Write-Host "== $Name ==" }
function Write-Detailed([string]$Message) { if ($Detailed) { Write-Host $Message } }
function Get-Text([string]$Path) { return [IO.File]::ReadAllText($Path) }
function Set-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }

function Get-PluginVersion([string]$PluginRoot) {
  $manifest = Join-Path $PluginRoot ".codex-plugin\plugin.json"
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $null }
  try {
    $version = [string]((Get-Text $manifest | ConvertFrom-Json).version)
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    return $version.Trim()
  } catch { return $null }
}

function Resolve-HomeDir {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $candidates.Add($env:USERPROFILE) }
  if (-not [string]::IsNullOrWhiteSpace($env:HOMEDRIVE) -and -not [string]::IsNullOrWhiteSpace($env:HOMEPATH)) { $candidates.Add("$($env:HOMEDRIVE)$($env:HOMEPATH)") }
  $fallback = [Environment]::GetFolderPath("UserProfile")
  if (-not [string]::IsNullOrWhiteSpace($fallback)) { $candidates.Add($fallback) }
  foreach ($candidate in @($candidates | Select-Object -Unique)) {
    $resolved = $candidate.TrimEnd('\')
    if (Test-Path -LiteralPath (Join-Path $resolved ".codex") -PathType Container) { return $resolved }
  }
  return $null
}

function Resolve-LocalAppData([string]$HomeDir) {
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and (Test-Path -LiteralPath $env:LOCALAPPDATA -PathType Container)) { return $env:LOCALAPPDATA.TrimEnd('\') }
  $fallback = [Environment]::GetFolderPath("LocalApplicationData")
  if (-not [string]::IsNullOrWhiteSpace($fallback) -and (Test-Path -LiteralPath $fallback -PathType Container)) { return $fallback.TrimEnd('\') }
  return (Join-Path $HomeDir "AppData\Local")
}

function Get-ConfiguredMarketplaceRoot([string]$HomeDir) {
  $configPath = Join-Path $HomeDir ".codex\config.toml"
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
  $inSection = $false
  foreach ($line in Get-Content -LiteralPath $configPath) {
    if ($line -match '^\s*\[marketplaces\.openai-bundled\]\s*$') { $inSection = $true; continue }
    if ($inSection -and $line -match '^\s*\[') { break }
    if ($inSection -and $line -match '^\s*source\s*=\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]') {
      $root = $matches[1]
      if ($root.StartsWith('\\?\')) { $root = $root.Substring(4) }
      return $root.TrimEnd('\')
    }
  }
  return $null
}

function Get-PluginRootFromScript([string]$ScriptPath) {
  $cursor = Split-Path -Parent $ScriptPath
  for ($index = 0; $index -lt 3 -and -not [string]::IsNullOrWhiteSpace($cursor); $index++) {
    if (Test-Path -LiteralPath (Join-Path $cursor ".codex-plugin\plugin.json") -PathType Leaf) { return $cursor }
    $parent = Split-Path -Parent $cursor
    if ($parent -eq $cursor) { break }
    $cursor = $parent
  }
  return $null
}

function Get-PluginNameFromScript([string]$ScriptPath) {
  if ($ScriptPath -match '[\\/]browser[\\/]') { return 'browser' }
  return 'chrome'
}

function Get-ConfiguredTrustedBrowserServicePaths([string]$HomeDir) {
  $configPath = Join-Path $HomeDir ".codex\config.toml"
  $paths = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $paths.ToArray() }
  foreach ($line in Get-Content -LiteralPath $configPath) {
    if ($line -notmatch '^\s*NODE_REPL_TRUSTED_SERVICES\s*=\s*(.+?)\s*$') { continue }
    $raw = $matches[1].Trim().Trim("'").Trim('"')
    try {
      $services = $raw | ConvertFrom-Json
      $candidate = [string]$services.browser
      if (-not [string]::IsNullOrWhiteSpace($candidate)) { $paths.Add($candidate) }
    } catch { }
  }
  return @($paths | Select-Object -Unique)
}

function Invoke-SyntaxCheck([string[]]$Paths) {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) { Write-Host "SYNTAX_CHECK_UNAVAILABLE: node was not found."; return $false }
  $unique = @($Paths | Select-Object -Unique)
  foreach ($path in $unique) {
    $output = & $node.Source --check $path 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host "SYNTAX_CHECK_FAILED: $path"; Write-Host $output; return $false }
    Write-Detailed "node --check ok: $path"
  }
  Write-Host ("Syntax check: {0}/{0} passed." -f $unique.Count)
  return $true
}

function Get-SecurityIntegrityFindings([string]$Text) {
  $markers = @(
    'if(typeof e=="string")return;if(Gd("check-url-site-status")',
    'if(typeof e=="string")return;if(rp("check-url-site-status")',
    'if(typeof t==="string")return;if(cd("check-url-site-status")',
    'if(typeof t==="string")return;if(bp("check-url-site-status")',
    'site-status proxy request timed out',
    'site-status request timed out'
  )
  return @($markers | Where-Object { $Text.Contains($_) })
}

function Get-UnsafeLegacyFindings([string]$Text) {
  $findings = New-Object System.Collections.Generic.List[string]
  foreach ($marker in @('if(LX.has(r))return a;', 'timeout_ms=="number"?t.timeout_ms:45e3', 'Timed out waiting for history navigation.").catch(()=>{})')) {
    if ($Text.Contains($marker)) { $findings.Add($marker) }
  }
  return $findings.ToArray()
}

function Get-ChromeExtensionInventory([string]$LocalAppData) {
  $userData = Join-Path $LocalAppData "Google\Chrome\User Data"
  $extensionId = "hehggadaopoacecdllhhajmbjkdcmajg"
  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $userData -PathType Container)) { return @() }
  try {
    $profiles = @(Get-ChildItem -LiteralPath $userData -Directory -ErrorAction Stop | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
  } catch { Write-Host "Chrome profile inventory unavailable: $($_.Exception.Message)"; return @() }
  foreach ($profile in $profiles) {
    $root = Join-Path $profile.FullName "Extensions\$extensionId"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    try {
      $versions = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Select-Object -ExpandProperty Name)
      $items.Add([pscustomobject]@{ Profile = $profile.Name; Versions = @($versions) })
    } catch {
      $items.Add([pscustomobject]@{ Profile = $profile.Name; Versions = @(); Error = $_.Exception.Message })
    }
  }
  return $items.ToArray()
}

function Invoke-TransactionalWrite([object[]]$Changes) {
  if ($Changes.Count -eq 0) { return @() }
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("chrome-xiufu-" + [Guid]::NewGuid().ToString('N'))
  $written = New-Object System.Collections.Generic.List[object]
  try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $staged = New-Object System.Collections.Generic.List[string]
    $index = 0
    foreach ($change in $Changes) {
      $index++
      $stage = Join-Path $tempRoot ("{0:D2}-{1}" -f $index, [IO.Path]::GetFileName([string]$change.Path))
      Set-Text $stage ([string]$change.NewText)
      $staged.Add($stage)
    }
    if (-not (Invoke-SyntaxCheck $staged.ToArray())) { throw "staged syntax check failed" }
    foreach ($change in $Changes) {
      Set-Text ([string]$change.Path) ([string]$change.NewText)
      if ((Get-Text ([string]$change.Path)) -ne ([string]$change.NewText)) { throw "write verification failed: $($change.Path)" }
      $written.Add($change)
    }
    if (-not (Invoke-SyntaxCheck @($Changes | ForEach-Object { [string]$_.Path }))) { throw "post-write syntax check failed" }
    return @($written.ToArray() | ForEach-Object { [string]$_.Path })
  } catch {
    $originalError = $_.Exception.Message
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    foreach ($change in $written.ToArray()) {
      try {
        Set-Text ([string]$change.Path) ([string]$change.OriginalText)
        if ((Get-Text ([string]$change.Path)) -ne ([string]$change.OriginalText)) { throw "read-back mismatch" }
      } catch { $rollbackErrors.Add("$($change.Path): $($_.Exception.Message)") }
    }
    if ($rollbackErrors.Count -gt 0) { throw "transaction failed: $originalError; rollback failed: $($rollbackErrors -join '; ')" }
    throw "transaction failed and all written files were rolled back: $originalError"
  } finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
      $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
      $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
      if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTemp).StartsWith('chrome-xiufu-')) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
    }
  }
}

if ($Repair -and $RestoreOfficialCache) { Write-Host "USAGE_ERROR: choose either -Repair or -RestoreOfficialCache."; exit 2 }
if ($Repair -and $PatchId.Count -eq 0) { Write-Host "AUTHORIZATION_REQUIRED: -Repair requires at least one explicit -PatchId."; exit 2 }
if (-not $Repair -and $PatchId.Count -gt 0) { Write-Host "USAGE_ERROR: -PatchId is valid only with -Repair."; exit 2 }

$homeDir = Resolve-HomeDir
if ([string]::IsNullOrWhiteSpace($homeDir)) { Write-Host "ENVIRONMENT_RESOLUTION_FAILED: no real user profile containing .codex was found."; exit 3 }
$localAppData = Resolve-LocalAppData $homeDir
$chromeRoot = Join-Path $homeDir ".codex\plugins\cache\openai-bundled\chrome\latest"
$activeVersion = Get-PluginVersion $chromeRoot
if ([string]::IsNullOrWhiteSpace($activeVersion)) { Write-Host "VERSION_SAFETY_GATE_FAILED: active Chrome latest manifest is missing or invalid."; exit 4 }

$targets = New-Object System.Collections.Generic.List[string]
foreach ($name in @('browser-client.mjs', 'browser-service.mjs')) {
  $path = Join-Path $chromeRoot "scripts\$name"
  if (Test-Path -LiteralPath $path -PathType Leaf) { $targets.Add($path) }
}
if ($targets.Count -eq 0) { Write-Host "VERSION_SAFETY_GATE_FAILED: no supported active Chrome scripts were found."; exit 4 }

$trustedServiceTargets = New-Object System.Collections.Generic.List[string]
foreach ($servicePath in @(Get-ConfiguredTrustedBrowserServicePaths $homeDir)) {
  if (-not (Test-Path -LiteralPath $servicePath -PathType Leaf)) { continue }
  if ([IO.Path]::GetFileName($servicePath) -ne 'browser-service.mjs') { continue }
  $serviceRoot = Get-PluginRootFromScript $servicePath
  if ([string]::IsNullOrWhiteSpace($serviceRoot) -or (Get-PluginVersion $serviceRoot) -ne $activeVersion) { continue }
  if ((Get-PluginNameFromScript $servicePath) -ne 'browser') { continue }
  $fullPath = [IO.Path]::GetFullPath($servicePath)
  if (-not $targets.Contains($fullPath)) {
    $targets.Add($fullPath)
    $trustedServiceTargets.Add($fullPath)
  }
}

$marketplaceRoots = New-Object System.Collections.Generic.List[string]
foreach ($root in @((Join-Path $homeDir ".codex\marketplaces\openai-bundled-local"), (Join-Path $homeDir ".codex\bundled-marketplaces\openai-bundled"), (Get-ConfiguredMarketplaceRoot $homeDir))) {
  if (-not [string]::IsNullOrWhiteSpace($root) -and -not $marketplaceRoots.Contains($root)) { $marketplaceRoots.Add($root) }
}
$cleanSources = New-Object System.Collections.Generic.List[object]
foreach ($root in $marketplaceRoots) {
  foreach ($target in $targets) {
    $pluginName = Get-PluginNameFromScript $target
    $pluginRoot = Join-Path $root ("plugins\" + $pluginName)
    if ((Get-PluginVersion $pluginRoot) -ne $activeVersion) { continue }
    $source = Join-Path $pluginRoot ("scripts\" + [IO.Path]::GetFileName($target))
    if (Test-Path -LiteralPath $source -PathType Leaf) { $cleanSources.Add([pscustomobject]@{ Plugin=$pluginName; Name=[IO.Path]::GetFileName($target); Path=$source; Hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash }) }
  }
}

Write-Section "Inspect"
$mode = if ($Repair) { 'explicit repair' } elseif ($RestoreOfficialCache) { 'explicit official-cache restore' } else { 'inspection only' }
Write-Host "Mode: $mode"
Write-Host "Active Chrome version: $activeVersion"
Write-Host "Selected repair targets: $($targets.Count)"
Write-Host "Explicit same-version trusted Browser services: $($trustedServiceTargets.Count)"
Write-Host "Matching-version marketplace sources: $($cleanSources.Count) (read-only)"
$profiles = @(Get-ChromeExtensionInventory $localAppData)
Write-Host "Enumerated Chrome profiles containing the control extension: $($profiles.Count) (absence is diagnostic only)"
$nativeManifest = Join-Path $localAppData "OpenAI\extension\com.openai.codexextension.json"
$nativeTarget = $null
if (Test-Path -LiteralPath $nativeManifest -PathType Leaf) {
  try { $nativeTarget = [string]((Get-Text $nativeManifest | ConvertFrom-Json).path) } catch { $nativeTarget = '<unreadable manifest>' }
}
Write-Host "Native-host manifest: $(if ($nativeTarget) { 'present' } else { 'not found' }) (diagnostic only)"
$trustedServiceEntries = New-Object System.Collections.Generic.List[string]
foreach ($name in @('NODE_REPL_TRUSTED_SERVICES', 'NODE_REPL_TRUSTED_SERVICE', 'NODE_REPL_TRUSTED_CODE_PATHS')) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if (-not [string]::IsNullOrWhiteSpace($value)) { $trustedServiceEntries.Add("$name=$value") }
}
Write-Host "Explicit trusted-service environment entries: $($trustedServiceEntries.Count) (read-only; never a repair target)"
if ($Detailed) {
  foreach ($profile in $profiles) { Write-Host ("- {0}: {1}" -f $profile.Profile, (@($profile.Versions) -join ', ')) }
  if ($nativeTarget) { Write-Host "- native target: $nativeTarget" }
  foreach ($entry in $trustedServiceEntries) { Write-Host "- trusted service: $entry" }
  foreach ($target in $trustedServiceTargets) { Write-Host "- trusted Browser repair target: $target" }
  foreach ($target in $targets) { Write-Host "- target: $target sha256=$((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)" }
  foreach ($source in $cleanSources) { Write-Host "- source: $($source.Plugin) $($source.Path) sha256=$($source.Hash)" }
}

$securityFindings = New-Object System.Collections.Generic.List[string]
$legacyFindings = New-Object System.Collections.Generic.List[string]
foreach ($target in $targets) {
  $text = Get-Text $target
  foreach ($finding in @(Get-SecurityIntegrityFindings $text)) { $securityFindings.Add("$target :: $finding") }
  foreach ($finding in @(Get-UnsafeLegacyFindings $text)) { $legacyFindings.Add("$target :: $finding") }
}
if ($securityFindings.Count -gt 0) {
  Write-Section "SecurityIntegrity"
  Write-Host "SECURITY_INTEGRITY_FAILED: a known site-policy bypass marker exists in the active Chrome cache."
  $securityFindings | ForEach-Object { Write-Host "- $_" }
  Write-Host "No patch was attempted. Use -RestoreOfficialCache only after reviewing the matching-version source."
  exit 6
}
if ($legacyFindings.Count -gt 0) {
  Write-Section "LegacyModification"
  Write-Host "UNSAFE_LEGACY_MODIFICATION_DETECTED: an old broad Xiufu modification exists."
  $legacyFindings | ForEach-Object { Write-Host "- $_" }
  Write-Host "No compatibility patch was attempted. Use -RestoreOfficialCache only after reviewing the matching-version source."
  exit 7
}

$patches = @(
  [pscustomobject]@{ Id='aria-snapshot'; Script='browser-client.mjs'; Old='return i?o.incrementalAriaSnapshot(i,{mode:"ai"}):{full:"",iframeDepths:{},iframeRefs:[]}'; New='return i?(typeof o.incrementalAriaSnapshot==="function"?o.incrementalAriaSnapshot(i,{mode:"ai"}):{full:o._renderAriaSnapshot(i,{mode:"ai"}),iframeDepths:{},iframeRefs:[]}):{full:"",iframeDepths:{},iframeRefs:[]}' },
  [pscustomobject]@{ Id='cached-cdp'; Script='browser-client.mjs'; Old='async executeCdpWithCachedExpression(r,n){if(this.cachedExpressionSupport==null||await this.cachedExpressionSupport){let o={...r.commandParams};this.sentCachedExpressions.has(n)&&delete o.expression;let i=this.sendSessionRequest(Lf,{...r,commandParams:o,expressionCacheKey:n});this.sentCachedExpressions.add(n),this.cachedExpressionSupport==null&&(this.cachedExpressionSupport=i.then(()=>!0,s=>s!==UE));try{let s=await i;if(s.kind==="executed")return s.result;let a=await this.sendSessionRequest(Lf,{...r,expressionCacheKey:n});if(a.kind==="executed")return a.result;throw new Error("Cached CDP expression refill failed")}catch(s){if(s!==UE)throw s}}return this.executeCdp(r)}'; New='async executeCdpWithCachedExpression(r,n){return this.executeCdp(r)}' },
  [pscustomobject]@{ Id='focus-timeout'; Script='browser-client.mjs'; Old='async enableFocusEmulation(r){try{await this.api.executeCdp({target:{tabId:r},method:"Emulation.setFocusEmulationEnabled",commandParams:{enabled:!0}})}catch{}}'; New='async enableFocusEmulation(r){try{await this.api.executeCdp({target:{tabId:r},method:"Emulation.setFocusEmulationEnabled",commandParams:{enabled:!0},timeoutMs:1000})}catch{}}' },
  [pscustomobject]@{ Id='oopif-timeout'; Script='browser-client.mjs'; Old='async enableOopifAutoAttachForTarget(r,n={}){let o={autoAttach:!0,flatten:!0,waitForDebuggerOnStart:!1},i=Ni(n);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:{...o,filter:[{type:"iframe",exclude:!1}]},timeoutMs:i})}catch(s){if(QA(s))throw s;let a=Ni(n);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:o,timeoutMs:a})}catch(c){if(QA(c))throw c;Le(n)}}}'; New='async enableOopifAutoAttachForTarget(r,n={}){let o={autoAttach:!0,flatten:!0,waitForDebuggerOnStart:!1},i=Math.min(Ni(n),750);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:{...o,filter:[{type:"iframe",exclude:!1}]},timeoutMs:i})}catch(s){if(QA(s))throw s;let a=Math.min(Ni(n),750);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:o,timeoutMs:a})}catch(c){if(QA(c))throw c;Le(n)}}}' },
  [pscustomobject]@{ Id='scroll-wheel'; Script='browser-service.mjs'; Old='async scrollPoint(t){let r=M(t.tabId),n=t.scrollX===0?0:-t.scrollX,o=t.scrollY===0?0:-t.scrollY;await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.synthesizeScrollGesture",{x:t.point.x,y:t.point.y,xDistance:n,yDistance:o,gestureSourceType:"mouse",preventFling:!0,speed:8e3})}'; New='async scrollPoint(t){let r=M(t.tabId);await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,button:"none",buttons:0,pointerType:"mouse",deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers})}' },
  [pscustomobject]@{ Id='scroll-wheel'; Script='browser-service.mjs'; Old='async scrollPoint(e){let r=W(e.tabId),n=e.scrollX===0?0:-e.scrollX,o=e.scrollY===0?0:-e.scrollY;await this.dispatchMouseMove(r,e.point,e.modifiers),await this.cdp.call(r,"Input.synthesizeScrollGesture",{x:e.point.x,y:e.point.y,xDistance:n,yDistance:o,gestureSourceType:"mouse",preventFling:!0,speed:8e3})}'; New='async scrollPoint(e){let r=W(e.tabId);await this.dispatchMouseMove(r,e.point,e.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:e.point.x,y:e.point.y,button:"none",buttons:0,pointerType:"mouse",deltaX:e.scrollX,deltaY:e.scrollY,modifiers:e.modifiers})}' },
  [pscustomobject]@{ Id='scroll-wheel'; Script='browser-service.mjs'; Old='async scrollPoint(t){let r=M(t.tabId);await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers})}'; New='async scrollPoint(t){let r=M(t.tabId);await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,button:"none",buttons:0,pointerType:"mouse",deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers})}' },
  [pscustomobject]@{ Id='scroll-wheel'; Script='browser-service.mjs'; Old='async scrollPoint(e){let r=W(e.tabId);await this.dispatchMouseMove(r,e.point,e.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:e.point.x,y:e.point.y,deltaX:e.scrollX,deltaY:e.scrollY,modifiers:e.modifiers})}'; New='async scrollPoint(e){let r=W(e.tabId);await this.dispatchMouseMove(r,e.point,e.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:e.point.x,y:e.point.y,button:"none",buttons:0,pointerType:"mouse",deltaX:e.scrollX,deltaY:e.scrollY,modifiers:e.modifiers})}' },
  [pscustomobject]@{ Id='history-navigation'; Script='browser-service.mjs'; Old='no previous page in history.");let s=e.cdp.waitForPageLoadEvent(r,{timeoutMs:n})'; New='no previous page in history.");let s=e.cdp.waitForEvent(r,a=>a.method==="Page.frameNavigated"?MV(a):a.method==="Page.navigatedWithinDocument"&&BV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."})' },
  [pscustomobject]@{ Id='history-navigation'; Script='browser-service.mjs'; Old='no next page in history.");let s=e.cdp.waitForPageLoadEvent(r,{timeoutMs:n})'; New='no next page in history.");let s=e.cdp.waitForEvent(r,a=>a.method==="Page.frameNavigated"?MV(a):a.method==="Page.navigatedWithinDocument"&&BV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."})' },
  [pscustomobject]@{ Id='history-navigation'; Script='browser-service.mjs'; Old='no previous page in history.");let s=e.cdp.waitForEvent(r,a=>a.method==="Page.frameNavigated"?TV(a):a.method==="Page.navigatedWithinDocument"&&EV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."})'; New='no previous page in history.");let s=e.cdp.waitForEvent(r,a=>a.method==="Page.frameNavigated"?MV(a):a.method==="Page.navigatedWithinDocument"&&BV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."})' },
  [pscustomobject]@{ Id='history-navigation'; Script='browser-service.mjs'; Old='no next page in history.");let s=e.cdp.waitForEvent(r,a=>a.method==="Page.frameNavigated"?TV(a):a.method==="Page.navigatedWithinDocument"&&EV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."})'; New='no next page in history.");let s=e.cdp.waitForEvent(r,a=>a.method==="Page.frameNavigated"?MV(a):a.method==="Page.navigatedWithinDocument"&&BV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."})' }
)

Write-Section "Candidates"
foreach ($patch in ($patches | Group-Object Id)) {
  $count = 0
  foreach ($variant in $patch.Group) {
    foreach ($target in @($targets | Where-Object { [IO.Path]::GetFileName($_) -eq $variant.Script })) {
      if ((Get-Text $target).Contains([string]$variant.Old)) { $count++ }
    }
  }
  Write-Host ("- {0}: {1} exact candidate(s); evidence still required" -f $patch.Name, $count)
}

if (-not (Invoke-SyntaxCheck $targets.ToArray())) { exit 1 }
if (-not $Repair -and -not $RestoreOfficialCache) {
  Write-Section "Result"
  Write-Host "No files changed."
  Write-Host "State: ACK_REQUIRED (static inspection passed; live ACK was not run)."
  exit 0
}

$changes = New-Object System.Collections.Generic.List[object]
if ($RestoreOfficialCache) {
  foreach ($target in $targets) {
    $name = [IO.Path]::GetFileName($target)
    $pluginName = Get-PluginNameFromScript $target
    $sources = @($cleanSources | Where-Object { $_.Plugin -eq $pluginName -and $_.Name -eq $name } | Group-Object Hash | ForEach-Object { $_.Group[0] })
    if ($sources.Count -ne 1) { Write-Host "CLEAN_SOURCE_GATE_FAILED: expected exactly one distinct matching-version source for $name; found $($sources.Count)."; exit 4 }
    $sourceText = Get-Text $sources[0].Path
    if (@(Get-SecurityIntegrityFindings $sourceText).Count -gt 0 -or @(Get-UnsafeLegacyFindings $sourceText).Count -gt 0) { Write-Host "CLEAN_SOURCE_GATE_FAILED: source contains a known unsafe legacy marker: $($sources[0].Path)"; exit 4 }
    $current = Get-Text $target
    if ($current -ne $sourceText) { $changes.Add([pscustomobject]@{ Path=$target; OriginalText=$current; NewText=$sourceText }) }
  }
} else {
  foreach ($id in @($PatchId | Select-Object -Unique)) {
    $matchedForId = 0
    foreach ($variant in @($patches | Where-Object { $_.Id -eq $id })) {
      foreach ($target in @($targets | Where-Object { [IO.Path]::GetFileName($_) -eq $variant.Script })) {
        $existing = @($changes | Where-Object { $_.Path -eq $target }) | Select-Object -First 1
        $current = if ($existing) { [string]$existing.NewText } else { Get-Text $target }
        if (-not $current.Contains([string]$variant.Old)) { continue }
        $updated = $current.Replace([string]$variant.Old, [string]$variant.New)
        if ($existing) { $existing.NewText = $updated } else { $changes.Add([pscustomobject]@{ Path=$target; OriginalText=$current; NewText=$updated }) }
        $matchedForId++
      }
    }
    if ($matchedForId -eq 0) {
      Write-Host "PATCH_PATTERN_NOT_FOUND: $id has no exact known-compatible match in active version $activeVersion."
      Write-Host "No files changed. Research the current upstream shape before adding a new pattern."
      exit 4
    }
  }
}

try { $changed = @(Invoke-TransactionalWrite $changes.ToArray()) } catch { Write-Host "TRANSACTION_FAILED: $($_.Exception.Message)"; exit 5 }

Write-Section "Result"
if ($changed.Count -eq 0) {
  Write-Host "No changes were necessary."
  Write-Host "State: ACK_REQUIRED (live ACK was not run)."
} else {
  Write-Host "Changed active Chrome cache files: $($changed.Count)"
  $changed | ForEach-Object { Write-Host "- $_" }
  Write-Host "Marketplace files changed: 0"
  Write-Host "Persistent backup files created: 0"
  Write-Host "State: RECONNECT_REQUIRED -> ACK_REQUIRED"
}

