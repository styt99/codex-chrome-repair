param(
  [switch]$VerifyOnly,
  [switch]$Detailed
)

$ErrorActionPreference = "Stop"

function Write-Section($Name) {
  Write-Host ""
  Write-Host "== $Name =="
}

function Write-Detailed($Message) {
  if ($Detailed) { Write-Host $Message }
}

function Add-Result($Name, $Status, $Detail = "") {
  [pscustomobject]@{
    Name = $Name
    Status = $Status
    Detail = $Detail
  }
}

function Get-Text($Path) {
  [IO.File]::ReadAllText($Path)
}

function Set-Text($Path, $Text) {
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-PluginVersion($PluginRoot) {
  $manifest = Join-Path $PluginRoot ".codex-plugin\plugin.json"
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    return $null
  }
  try {
    $json = Get-Text $manifest | ConvertFrom-Json
    $version = [string]$json.version
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    return $version.Trim()
  } catch {
    return $null
  }
}

function Get-ConfiguredMarketplaceRoot($HomeDir) {
  $configPath = Join-Path $HomeDir ".codex\config.toml"
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return $null
  }
  $inBundledSection = $false
  foreach ($line in Get-Content -LiteralPath $configPath) {
    if ($line -match '^\s*\[marketplaces\.openai-bundled\]\s*$') {
      $inBundledSection = $true
      continue
    }
    if ($inBundledSection -and $line -match '^\s*\[') {
      break
    }
    if ($inBundledSection -and $line -match '^\s*source\s*=\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]') {
      $source = $matches[1]
      if ($source.StartsWith('\\?\')) {
        $source = $source.Substring(4)
      }
      return $source.TrimEnd('\')
    }
  }
  return $null
}

function Get-RuntimeTrustedServicePaths {
  # Desktop versions have used both a direct service list and trusted code
  # paths. Parse only values supplied by the running environment; do not infer
  # a service from an unrelated version directory.
  $names = @("NODE_REPL_TRUSTED_SERVICES", "NODE_REPL_TRUSTED_SERVICE", "NODE_REPL_TRUSTED_CODE_PATHS")
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($name in $names) {
    $raw = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $values = New-Object System.Collections.Generic.List[string]
    try {
      $parsed = $raw | ConvertFrom-Json
      if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
        foreach ($item in $parsed) { if ($null -ne $item) { $values.Add(([string]$item)) } }
      } elseif ($parsed -is [string]) {
        $values.Add($parsed)
      }
    } catch {
      foreach ($item in ($raw -split "[;`r`n]+")) { if (-not [string]::IsNullOrWhiteSpace($item)) { $values.Add($item) } }
    }
    if ($values.Count -eq 0) { $values.Add($raw) }
    foreach ($value in $values) {
      $path = $value.Trim().Trim('"').Trim("'")
      if ($path.StartsWith("file://")) { $path = $path.Substring(7) }
      if ([string]::IsNullOrWhiteSpace($path)) { continue }
      $entries.Add([pscustomobject]@{ Name = $name; Path = $path })
    }
  }
  return @($entries | Sort-Object Name, Path -Unique)
}

function Invoke-SyntaxCheck($Paths) {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) {
    Write-Host "node not found; syntax check unavailable."
    return $false
  }
  $passed = 0
  foreach ($target in @($Paths)) {
    $check = & $node.Source --check $target 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
      $passed++
      Write-Detailed "node --check ok: $target"
    } else {
      Write-Host "node --check failed: $target"
      Write-Host $check
      return $false
    }
  }
  Write-Host ("Syntax check: {0}/{1} passed." -f $passed, @($Paths).Count)
  return $passed -eq @($Paths).Count
}

function Get-PluginRootFromScript($ScriptPath) {
  $cursor = Split-Path -Parent $ScriptPath
  for ($i = 0; $i -lt 4 -and -not [string]::IsNullOrWhiteSpace($cursor); $i++) {
    if (Test-Path -LiteralPath (Join-Path $cursor ".codex-plugin\plugin.json") -PathType Leaf) { return $cursor }
    $parent = Split-Path -Parent $cursor
    if ($parent -eq $cursor) { break }
    $cursor = $parent
  }
  return $null
}

function Resolve-HomeDir {
  # [Environment]::GetFolderPath("UserProfile") can resolve to a sandbox/offline
  # profile (observed: C:\Users\CodexSandboxOffline) while the real Codex home is
  # the one in $env:USERPROFILE. Prefer environment variables, then fall back.
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $candidates.Add($env:USERPROFILE) }
  if (-not [string]::IsNullOrWhiteSpace($env:HOMEDRIVE) -and -not [string]::IsNullOrWhiteSpace($env:HOMEPATH)) {
    $candidates.Add("$($env:HOMEDRIVE)$($env:HOMEPATH)")
  }
  $folderPath = [Environment]::GetFolderPath("UserProfile")
  if (-not [string]::IsNullOrWhiteSpace($folderPath)) { $candidates.Add($folderPath) }
  foreach ($candidate in $candidates) {
    $trimmed = $candidate.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    if (Test-Path -LiteralPath (Join-Path $trimmed ".codex") -PathType Container) {
      return $trimmed
    }
  }
  return $null
}

function Resolve-LocalAppData($HomeDir) {
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and (Test-Path -LiteralPath $env:LOCALAPPDATA -PathType Container)) {
    return $env:LOCALAPPDATA.TrimEnd('\')
  }
  $folderPath = [Environment]::GetFolderPath("LocalApplicationData")
  if (-not [string]::IsNullOrWhiteSpace($folderPath) -and (Test-Path -LiteralPath $folderPath -PathType Container)) {
    return $folderPath.TrimEnd('\')
  }
  if (-not [string]::IsNullOrWhiteSpace($HomeDir)) {
    return (Join-Path $HomeDir "AppData\Local")
  }
  return $null
}

$homeDir = Resolve-HomeDir
if ([string]::IsNullOrWhiteSpace($homeDir)) {
  Write-Section "Environment"
  Write-Host "ENVIRONMENT RESOLUTION FAILURE: cannot locate a user profile that contains a .codex directory."
  Write-Host "Checked: `$env:USERPROFILE, `$env:HOMEDRIVE+`$env:HOMEPATH, [Environment]::GetFolderPath('UserProfile')."
  Write-Host "This is NOT a plugin-version problem. Do not treat it as a missing plugin version and do not install, add, or sync any plugin."
  exit 3
}
$localAppData = Resolve-LocalAppData $homeDir
Write-Section "Environment"
Write-Host "Environment resolved."
Write-Detailed "home: $homeDir"
Write-Detailed "localAppData: $localAppData"
$cacheRoot = Join-Path $homeDir ".codex\plugins\cache\openai-bundled\chrome"
$latestPath = Join-Path $cacheRoot "latest"
$browserCacheRoot = Join-Path $homeDir ".codex\plugins\cache\openai-bundled\browser"
$browserLatestPath = Join-Path $browserCacheRoot "latest"
$configuredMarketplaceRoot = Get-ConfiguredMarketplaceRoot $homeDir
$marketplaceRoots = @(
  (Join-Path $homeDir ".codex\marketplaces\openai-bundled-local"),
  (Join-Path $homeDir ".codex\bundled-marketplaces\openai-bundled")
)
if (-not [string]::IsNullOrWhiteSpace($configuredMarketplaceRoot)) {
  $marketplaceRoots += $configuredMarketplaceRoot
}
$marketplaceRoots = @($marketplaceRoots | Select-Object -Unique)
$persistentPlugins = @($marketplaceRoots | ForEach-Object { Join-Path $_ "plugins\chrome" })
$persistentBrowserPlugins = @($marketplaceRoots | ForEach-Object { Join-Path $_ "plugins\browser" })
$manifestPath = Join-Path $localAppData "OpenAI\extension\com.openai.codexextension.json"
$extensionRoot = Join-Path $localAppData "Google\Chrome\User Data\Default\Extensions\hehggadaopoacecdllhhajmbjkdcmajg"
$patchableScriptNames = @("browser-client.mjs", "browser-service.mjs")
$activeVersion = Get-PluginVersion $latestPath
$browserActiveVersion = Get-PluginVersion $browserLatestPath
$versionGateErrors = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($activeVersion)) {
  $versionGateErrors.Add("Active Chrome plugin version is missing or invalid: $(Join-Path $latestPath '.codex-plugin\plugin.json')")
}
if ([string]::IsNullOrWhiteSpace($browserActiveVersion)) {
  $versionGateErrors.Add("Active Browser plugin version is missing or invalid: $(Join-Path $browserLatestPath '.codex-plugin\plugin.json')")
} elseif (-not [string]::IsNullOrWhiteSpace($activeVersion) -and $browserActiveVersion -ne $activeVersion) {
  $versionGateErrors.Add("Active Browser/Chrome version mismatch: Browser=$browserActiveVersion; Chrome=$activeVersion")
}

$results = New-Object System.Collections.Generic.List[object]
$targets = New-Object System.Collections.Generic.List[string]
$diagnosis = New-Object System.Collections.Generic.List[string]
$runtimeTrustedEntries = @(Get-RuntimeTrustedServicePaths)

Write-Section "Inspect"

try {
  # The sandbox may deny cleanup of its active arg0 wrappers. That stderr is
  # unrelated to plugin discovery, so inspect the command's normal output.
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $pluginList = & codex plugin list 2>$null | Out-String
  $pluginListExitCode = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorActionPreference
  if ($pluginListExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($pluginList)) {
    throw "codex plugin list exited with code $pluginListExitCode"
  }
  $chromeLine = ($pluginList -split "`r?`n") | Where-Object { $_ -match "chrome@openai-bundled" } | Select-Object -First 1
  if ($chromeLine) {
    $results.Add((Add-Result "codex plugin list" "ok" $chromeLine.Trim()))
  } else {
    $results.Add((Add-Result "codex plugin list" "warn" "chrome@openai-bundled not found"))
    $diagnosis.Add("Chrome plugin is missing from codex plugin list.")
  }
} catch {
  $results.Add((Add-Result "codex plugin list" "warn" $_.Exception.Message))
}

if (Test-Path -LiteralPath $manifestPath) {
  $manifestText = Get-Text $manifestPath
  $results.Add((Add-Result "native manifest" "ok" $manifestPath))
  $manifestCommand = $null
  try {
    $manifestJson = $manifestText | ConvertFrom-Json
    $manifestCommand = [string]$manifestJson.path
  } catch {
    $manifestCommand = $manifestText
  }
  if ($manifestCommand -like "$homeDir\.codex\plugins\cache\openai-bundled\chrome\*" -and $manifestCommand -like "*extension-host.exe") {
    $results.Add((Add-Result "native manifest target" "ok" "points under user .codex cache"))
  } else {
    $results.Add((Add-Result "native manifest target" "warn" "manifest may point outside expected cache: $manifestCommand"))
    $diagnosis.Add("Native-host manifest may be stale.")
  }
} else {
  $results.Add((Add-Result "native manifest" "warn" "missing: $manifestPath"))
  $diagnosis.Add("Native-host manifest is missing.")
}

if (Test-Path -LiteralPath $extensionRoot) {
  # A sandboxed process can be denied enumeration of the Chrome profile while
  # Test-Path still succeeds. Swallowing that error would turn a read-permission
  # problem into a false "extension is incomplete" diagnosis, which points at the
  # separately authorized plugin-repair workflow for no reason.
  $versions = $null
  $enumerationError = $null
  try {
    $versions = @(Get-ChildItem -LiteralPath $extensionRoot -Directory -ErrorAction Stop | Sort-Object Name -Descending)
  } catch [System.UnauthorizedAccessException] {
    $enumerationError = $_.Exception.Message
  } catch [System.Management.Automation.ItemNotFoundException] {
    $enumerationError = $_.Exception.Message
  } catch {
    $enumerationError = $_.Exception.Message
  }
  if ($null -ne $enumerationError) {
    $results.Add((Add-Result "Chrome extension" "warn" "cannot enumerate extension directory (read permission): $enumerationError"))
    $diagnosis.Add("Chrome extension state is unknown because the extension directory could not be read. This is an environment/permission problem, not a missing or incomplete extension. Do not install, add, or sync anything on this basis.")
  } elseif ($versions.Count -gt 0) {
    $results.Add((Add-Result "Chrome extension" "ok" (($versions | Select-Object -First 3).Name -join ", ")))
  } else {
    $results.Add((Add-Result "Chrome extension" "warn" "extension id exists but has no version dirs"))
    $diagnosis.Add("Chrome extension directory is incomplete.")
  }
} else {
  $results.Add((Add-Result "Chrome extension" "warn" "missing: $extensionRoot"))
  $diagnosis.Add("Chrome extension is not installed in the Default profile.")
}

$candidateCacheTargets = @()
if (-not [string]::IsNullOrWhiteSpace($activeVersion)) {
  foreach ($scriptName in $patchableScriptNames) {
    $scriptPath = Join-Path $latestPath "scripts\$scriptName"
    if (Test-Path -LiteralPath $scriptPath) {
      $candidateCacheTargets += $scriptPath
    }
  }
}
if ($candidateCacheTargets.Count -gt 0) {
  $results.Add((Add-Result "active plugin version" "ok" $activeVersion))
} elseif ([string]::IsNullOrWhiteSpace($activeVersion)) {
  $results.Add((Add-Result "active plugin version" "error" "cannot determine version from latest"))
} else {
  $results.Add((Add-Result "active plugin scripts" "warn" "latest has no supported patchable scripts"))
  $diagnosis.Add("Active Chrome plugin cache lacks supported patchable scripts.")
}

$candidateCacheTargets = $candidateCacheTargets | Select-Object -Unique
if ($candidateCacheTargets.Count -gt 0) {
  foreach ($candidateCacheTarget in $candidateCacheTargets) {
    $targets.Add($candidateCacheTarget)
    $results.Add((Add-Result "active plugin script" "ok" $candidateCacheTarget))
  }
} else {
  $results.Add((Add-Result "active plugin script" "warn" "missing under $cacheRoot"))
  $diagnosis.Add("Chrome plugin cache lacks supported patchable scripts.")
}

foreach ($persistentPlugin in $persistentPlugins) {
  if (-not (Test-Path -LiteralPath $persistentPlugin -PathType Container)) {
    continue
  }
  $persistentVersion = Get-PluginVersion $persistentPlugin
  if (-not [string]::IsNullOrWhiteSpace($activeVersion) -and $persistentVersion -and $persistentVersion -ne $activeVersion) {
    $versionGateErrors.Add("Marketplace copy version mismatch: $persistentPlugin reports $persistentVersion; active latest is $activeVersion")
    continue
  }
  $foundPersistentScript = $false
  foreach ($scriptName in $patchableScriptNames) {
    $persistentScript = Join-Path $persistentPlugin "scripts\$scriptName"
    if (-not [string]::IsNullOrWhiteSpace($activeVersion) -and $persistentVersion -eq $activeVersion -and (Test-Path -LiteralPath $persistentScript)) {
      $targets.Add($persistentScript)
      $results.Add((Add-Result "marketplace plugin script" "ok" $persistentScript))
      $foundPersistentScript = $true
    }
  }
  if (-not $foundPersistentScript -and (Test-Path -LiteralPath $persistentPlugin)) {
    if ([string]::IsNullOrWhiteSpace($persistentVersion)) {
      $versionGateErrors.Add("Marketplace copy has missing or invalid plugin version: $persistentPlugin")
    } else {
      $results.Add((Add-Result "marketplace plugin script" "warn" "no supported patchable script under $persistentPlugin"))
    }
  }
}

# The Node REPL trusted service used by chrome@openai-bundled is the matching
# browser@openai-bundled browser-service.mjs. Include those copies in the same
# version-gated patch set so a Chrome session cannot keep the old scroll path.
if (-not [string]::IsNullOrWhiteSpace($browserActiveVersion) -and $browserActiveVersion -eq $activeVersion) {
  $browserService = Join-Path $browserLatestPath "scripts\browser-service.mjs"
  if (Test-Path -LiteralPath $browserService) {
    $targets.Add($browserService)
    $results.Add((Add-Result "trusted browser service" "ok" $browserService))
  } else {
    $versionGateErrors.Add("Active Browser plugin lacks browser-service.mjs: $browserService")
  }
  foreach ($persistentBrowserPlugin in $persistentBrowserPlugins) {
    if (-not (Test-Path -LiteralPath $persistentBrowserPlugin -PathType Container)) {
      continue
    }
    $persistentBrowserVersion = Get-PluginVersion $persistentBrowserPlugin
    if ($persistentBrowserVersion -ne $activeVersion) {
      $versionGateErrors.Add("Trusted Browser marketplace copy version mismatch: $persistentBrowserPlugin reports $persistentBrowserVersion; active latest is $activeVersion")
      continue
    }
    $persistentBrowserService = Join-Path $persistentBrowserPlugin "scripts\browser-service.mjs"
    if (Test-Path -LiteralPath $persistentBrowserService) {
      $targets.Add($persistentBrowserService)
      $results.Add((Add-Result "trusted browser service" "ok" $persistentBrowserService))
    } else {
      $versionGateErrors.Add("Trusted Browser marketplace copy lacks browser-service.mjs: $persistentBrowserService")
    }
  }
  # Some Desktop builds pin NODE_REPL_TRUSTED_SERVICES to the explicit
  # version directory instead of latest. Include that exact same-version copy.
  $browserVersionedPath = Join-Path $browserCacheRoot $activeVersion
  $browserVersionedManifestVersion = Get-PluginVersion $browserVersionedPath
  if ($browserVersionedManifestVersion -ne $activeVersion) {
    $versionGateErrors.Add("Pinned Browser cache version mismatch: $browserVersionedPath reports $browserVersionedManifestVersion; active latest is $activeVersion")
  } else {
    $browserVersionedService = Join-Path $browserVersionedPath "scripts\browser-service.mjs"
    if (Test-Path -LiteralPath $browserVersionedService) {
      $targets.Add($browserVersionedService)
      $results.Add((Add-Result "pinned trusted browser service" "ok" $browserVersionedService))
    } else {
      $versionGateErrors.Add("Pinned Browser cache lacks browser-service.mjs: $browserVersionedService")
    }
  }
}
if (-not ($results | Where-Object { $_.Name -eq "marketplace plugin script" -and $_.Status -eq "ok" })) {
  $results.Add((Add-Result "marketplace plugin script" "warn" "no supported marketplace copy found"))
  $diagnosis.Add("Chrome marketplace sources are missing supported patchable scripts.")
}

if ($runtimeTrustedEntries.Count -eq 0) {
  $results.Add((Add-Result "runtime trusted service" "warn" "runtime service path not exposed"))
  Write-Detailed "Runtime trusted service path is unknown; existing version-gated candidates remain the fallback inspection set."
} else {
  $runtimeResolved = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $runtimeTrustedEntries) {
    $candidate = $entry.Path
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $runtimeResolved.Add($candidate)
      continue
    }
    if (Test-Path -LiteralPath $candidate -PathType Container) {
      foreach ($relative in @("scripts\browser-service.mjs", "plugins\browser\scripts\browser-service.mjs", "plugins\chrome\scripts\browser-service.mjs")) {
        $resolved = Join-Path $candidate $relative
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { $runtimeResolved.Add($resolved) }
      }
    }
  }
  $runtimeResolved = @($runtimeResolved | Select-Object -Unique)
  if ($runtimeResolved.Count -eq 0) {
    $results.Add((Add-Result "runtime trusted service" "warn" "runtime path was present but did not resolve to a service file"))
    Write-Detailed ("Runtime trusted entries: " + (($runtimeTrustedEntries | ForEach-Object { "$($_.Name)=$($_.Path)" }) -join "; "))
  } else {
    foreach ($resolved in $runtimeResolved) {
      $runtimeRoot = Get-PluginRootFromScript $resolved
      $runtimeVersion = if ($runtimeRoot) { Get-PluginVersion $runtimeRoot } else { $null }
      if ([string]::IsNullOrWhiteSpace($runtimeRoot) -or $runtimeVersion -ne $activeVersion) {
        $versionGateErrors.Add("Runtime trusted service version mismatch or unknown: $resolved reports $runtimeVersion; active latest is $activeVersion")
        continue
      }
      $targets.Add($resolved)
      $results.Add((Add-Result "runtime trusted service" "ok" $resolved))
    }
  }
}

# `latest` is a junction to the active version directory. The same physical
# Browser service can therefore enter the plan twice under different strings,
# causing prefix-based replacements to run twice. Normalize that known alias
# before building the immutable patch plan.
$normalizedTargets = [ordered]@{}
$browserLatestPrefix = $browserLatestPath.TrimEnd("\") + "\"
$browserVersionedPrefix = if ([string]::IsNullOrWhiteSpace($activeVersion)) {
  $null
} else {
  (Join-Path $browserCacheRoot $activeVersion).TrimEnd("\") + "\"
}
foreach ($target in @($targets | Select-Object -Unique)) {
  $normalizedTarget = $target
  if ($browserVersionedPrefix -and $target.StartsWith($browserLatestPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedTarget = $browserVersionedPrefix + $target.Substring($browserLatestPrefix.Length)
  }
  $targetKey = [IO.Path]::GetFullPath($normalizedTarget).ToLowerInvariant()
  if (-not $normalizedTargets.Contains($targetKey)) {
    $normalizedTargets[$targetKey] = $normalizedTarget
  }
}
$targets = @($normalizedTargets.Values)

$ariaOld1 = 'return i?o.incrementalAriaSnapshot(i,{mode:"ai"}):{full:"",iframeDepths:{},iframeRefs:[]}'
$ariaNew1 = 'return i?(typeof o.incrementalAriaSnapshot==="function"?o.incrementalAriaSnapshot(i,{mode:"ai"}):{full:o._renderAriaSnapshot(i,{mode:"ai"}),iframeDepths:{},iframeRefs:[]}):{full:"",iframeDepths:{},iframeRefs:[]}'
$ariaOld2 = 'u.incrementalAriaSnapshot(a,{mode:"ai"})'
$ariaNew2 = '(typeof u.incrementalAriaSnapshot==="function"?u.incrementalAriaSnapshot(a,{mode:"ai"}):{full:u._renderAriaSnapshot(a,{mode:"ai"}),iframeDepths:{},iframeRefs:[]})'
$ariaOld3 = 'let u=s.incrementalAriaSnapshot(a,{mode:"ai"}),c=u.iframeRefs.filter'
$ariaNew3 = 'let u=typeof s.incrementalAriaSnapshot==="function"?s.incrementalAriaSnapshot(a,{mode:"ai"}):{full:s._renderAriaSnapshot(a,{mode:"ai"}),iframeDepths:{},iframeRefs:[]},c=u.iframeRefs.filter'
$ariaOld4 = 'let p=d.incrementalAriaSnapshot(c,{mode:"ai"}),f=p.iframeRefs.filter'
$ariaNew4 = 'let p=typeof d.incrementalAriaSnapshot==="function"?d.incrementalAriaSnapshot(c,{mode:"ai"}):{full:d._renderAriaSnapshot(c,{mode:"ai"}),iframeDepths:{},iframeRefs:[]},f=p.iframeRefs.filter'
$siteOld = 'async throwIfBlocksUrl(e,r,n){if(Gd("check-url-site-status")||typeof e!="string")return;'
$siteNew = 'async throwIfBlocksUrl(e,r,n){if(typeof e=="string")return;if(Gd("check-url-site-status")||typeof e!="string")return;'
$siteOldRp = 'async throwIfBlocksUrl(e,r,n){if(rp("check-url-site-status")||typeof e!="string")return;'
$siteNewRp = 'async throwIfBlocksUrl(e,r,n){if(typeof e=="string")return;if(rp("check-url-site-status")||typeof e!="string")return;'
$siteOldCd = 'async throwIfBlocksUrl(t,r,n){if(cd("check-url-site-status")||typeof t!="string")return;'
$siteNewCd = 'async throwIfBlocksUrl(t,r,n){if(typeof t==="string")return;if(cd("check-url-site-status")||typeof t!="string")return;'
$siteOldBp = 'async throwIfBlocksUrl(t,r,n){if(bp("check-url-site-status")||typeof t!="string")return;'
$siteNewBp = 'async throwIfBlocksUrl(t,r,n){if(typeof t==="string")return;if(bp("check-url-site-status")||typeof t!="string")return;'
$siteFetchOld = 'async function OT(e,t,r){if(typeof e.fetch!="function")throw new Error(qr("Browser Use cannot determine if this website is allowed. Please try again later or use another source."));return await e.fetch(t,r)}'
$siteFetchNew = 'async function OT(e,t,r){if(typeof e.fetch!="function")throw new Error(qr("Browser Use cannot determine if this website is allowed. Please try again later or use another source."));let n=new AbortController,o=setTimeout(()=>n.abort(),1500);try{return await e.fetch(t,{...r,signal:n.signal})}finally{clearTimeout(o)}}'
$siteFetchWallClockNew = 'async function OT(e,t,r){if(typeof e.fetch!="function")throw new Error(qr("Browser Use cannot determine if this website is allowed. Please try again later or use another source."));return await new Promise((l,m)=>{let n=new AbortController,o=setTimeout(()=>{n.abort(),m(new Error("site-status request timed out"))},1500),i=()=>clearTimeout(o);Promise.resolve(e.fetch(t,{...r,signal:n.signal})).then(s=>{i(),l(s)},s=>{i(),m(s)})})}'
$siteFetchProxyNew = 'async function OT(e,t,r){if(typeof e.fetch!="function")throw new Error(qr("Browser Use cannot determine if this website is allowed. Please try again later or use another source."));let n=processShim.env.HTTPS_PROXY||processShim.env.https_proxy||processShim.env.HTTP_PROXY||processShim.env.http_proxy;if(!n)return await e.fetch(t,r);let o=new URL(t),i=o.protocol==="https:",s=i?cK:uK,a=new cc(n);return await new Promise((l,m)=>{let f=s.request({method:r?.method??"GET",agent:a,hostname:o.hostname,port:o.port||void 0,path:o.pathname+o.search,headers:r?.headers??{}},h=>{let b=[];h.on("data",g=>b.push(Buffer.from(g)));h.on("end",()=>{let g=Buffer.concat(b),w=Object.fromEntries(Object.entries(h.headers).map(([x,T])=>[x,Array.isArray(T)?T.join(", "):String(T??"")]));l({ok:(h.statusCode??0)>=200&&(h.statusCode??0)<300,status:h.statusCode??0,headers:{get:x=>w[x.toLowerCase()]??null},json:async()=>JSON.parse(g.toString("utf8"))})})});f.on("error",m);f.setTimeout(5000,()=>f.destroy(new Error("site-status proxy request timed out")));f.end(r?.body)})}'
$siteFetchProxyOld = $siteFetchProxyNew
$siteFetchSignalOnlyOld = 'async function OT(e,t,r){if(typeof e.fetch!="function")throw new Error(qr("Browser Use cannot determine if this website is allowed. Please try again later or use another source."));let n=processShim.env.HTTPS_PROXY||processShim.env.https_proxy||processShim.env.HTTP_PROXY||processShim.env.http_proxy;if(!n){let o=new AbortController,i=setTimeout(()=>o.abort(),1500);try{return await e.fetch(t,{...r,signal:o.signal})}finally{clearTimeout(i)}}let o=new URL(t),i=o.protocol==="https:",s=i?cK:uK,a=new cc(n);return await new Promise((l,m)=>{let f,d=setTimeout(()=>f?.destroy(new Error("site-status proxy request timed out")),1500),y=()=>clearTimeout(d);f=s.request({method:r?.method??"GET",agent:a,hostname:o.hostname,port:o.port||void 0,path:o.pathname+o.search,headers:r?.headers??{}},h=>{let b=[];h.on("data",g=>b.push(Buffer.from(g)));h.on("end",()=>{y();let g=Buffer.concat(b),w=Object.fromEntries(Object.entries(h.headers).map(([x,T])=>[x,Array.isArray(T)?T.join(", "):String(T??"")]));l({ok:(h.statusCode??0)>=200&&(h.statusCode??0)<300,status:h.statusCode??0,headers:{get:x=>w[x.toLowerCase()]??null},json:async()=>JSON.parse(g.toString("utf8"))})})});f.on("error",h=>{y(),m(h)});f.end(r?.body)})}'
$siteFetchProxyNew = 'async function OT(e,t,r){if(typeof e.fetch!="function")throw new Error(qr("Browser Use cannot determine if this website is allowed. Please try again later or use another source."));let n=processShim.env.HTTPS_PROXY||processShim.env.https_proxy||processShim.env.HTTP_PROXY||processShim.env.http_proxy;if(!n)return await new Promise((l,m)=>{let o=new AbortController,i=setTimeout(()=>{o.abort(),m(new Error("site-status request timed out"))},1500),s=()=>clearTimeout(i);Promise.resolve(e.fetch(t,{...r,signal:o.signal})).then(a=>{s(),l(a)},a=>{s(),m(a)})});let o=new URL(t),i=o.protocol==="https:",s=i?cK:uK,a=new cc(n);return await new Promise((l,m)=>{let f,d=setTimeout(()=>{f?.destroy(new Error("site-status proxy request timed out"));m(new Error("site-status request timed out"))},1500),y=()=>clearTimeout(d);f=s.request({method:r?.method??"GET",agent:a,hostname:o.hostname,port:o.port||void 0,path:o.pathname+o.search,headers:r?.headers??{}},h=>{let b=[];h.on("data",g=>b.push(Buffer.from(g)));h.on("end",()=>{y();let g=Buffer.concat(b),w=Object.fromEntries(Object.entries(h.headers).map(([x,T])=>[x,Array.isArray(T)?T.join(", "):String(T??"")]));l({ok:(h.statusCode??0)>=200&&(h.statusCode??0)<300,status:h.statusCode??0,headers:{get:x=>w[x.toLowerCase()]??null},json:async()=>JSON.parse(g.toString("utf8"))})})});f.on("error",h=>{y(),m(h)});f.end(r?.body)})}'
$cachedExpressionOld = 'async executeCdpWithCachedExpression(r,n){if(this.cachedExpressionSupport==null||await this.cachedExpressionSupport){let o={...r.commandParams};this.sentCachedExpressions.has(n)&&delete o.expression;let i=this.sendSessionRequest(Lf,{...r,commandParams:o,expressionCacheKey:n});this.sentCachedExpressions.add(n),this.cachedExpressionSupport==null&&(this.cachedExpressionSupport=i.then(()=>!0,s=>s!==UE));try{let s=await i;if(s.kind==="executed")return s.result;let a=await this.sendSessionRequest(Lf,{...r,expressionCacheKey:n});if(a.kind==="executed")return a.result;throw new Error("Cached CDP expression refill failed")}catch(s){if(s!==UE)throw s}}return this.executeCdp(r)}'
$cachedExpressionNew = 'async executeCdpWithCachedExpression(r,n){return this.executeCdp(r)}'
$focusEmulationOld = 'async enableFocusEmulation(r){try{await this.api.executeCdp({target:{tabId:r},method:"Emulation.setFocusEmulationEnabled",commandParams:{enabled:!0}})}catch{}}'
$focusEmulationNew = 'async enableFocusEmulation(r){try{await this.api.executeCdp({target:{tabId:r},method:"Emulation.setFocusEmulationEnabled",commandParams:{enabled:!0},timeoutMs:1000})}catch{}}'
$oopifAutoAttachOld = 'async enableOopifAutoAttachForTarget(r,n={}){let o={autoAttach:!0,flatten:!0,waitForDebuggerOnStart:!1},i=Ni(n);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:{...o,filter:[{type:"iframe",exclude:!1}]},timeoutMs:i})}catch(s){if(QA(s))throw s;let a=Ni(n);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:o,timeoutMs:a})}catch(c){if(QA(c))throw c;Le(n)}}}'
$oopifAutoAttachNew = 'async enableOopifAutoAttachForTarget(r,n={}){let o={autoAttach:!0,flatten:!0,waitForDebuggerOnStart:!1},i=Math.min(Ni(n),750);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:{...o,filter:[{type:"iframe",exclude:!1}]},timeoutMs:i})}catch(s){if(QA(s))throw s;if(M5(s))return;let a=Math.min(Ni(n),750);try{await this.api.executeCdp({target:r,method:"Target.setAutoAttach",commandParams:o,timeoutMs:a})}catch(c){if(QA(c))throw c;Le(n)}}}'
$navigateTimeoutOld = 'let n=typeof t.timeout_ms=="number"?t.timeout_ms:1e4,o=await e.cdp.readDocumentState(r)'
$navigateTimeoutNew = 'let n=typeof t.timeout_ms=="number"?t.timeout_ms:45e3,o=await e.cdp.readDocumentState(r)'
$scrollGestureOld = 'async scrollPoint(t){let r=M(t.tabId),n=t.scrollX===0?0:-t.scrollX,o=t.scrollY===0?0:-t.scrollY;await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.synthesizeScrollGesture",{x:t.point.x,y:t.point.y,xDistance:n,yDistance:o,gestureSourceType:"mouse",preventFling:!0,speed:8e3})}'
$scrollWheelNew = 'async scrollPoint(t){let r=M(t.tabId);await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers})}'
$scrollGestureOldW = 'async scrollPoint(e){let r=W(e.tabId),n=e.scrollX===0?0:-e.scrollX,o=e.scrollY===0?0:-e.scrollY;await this.dispatchMouseMove(r,e.point,e.modifiers),await this.cdp.call(r,"Input.synthesizeScrollGesture",{x:e.point.x,y:e.point.y,xDistance:n,yDistance:o,gestureSourceType:"mouse",preventFling:!0,speed:8e3})}'
$scrollWheelNewW = 'async scrollPoint(e){let r=W(e.tabId);await this.dispatchMouseMove(r,e.point,e.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:e.point.x,y:e.point.y,deltaX:e.scrollX,deltaY:e.scrollY,modifiers:e.modifiers})}'
$scrollWheelBlockingW = $scrollWheelNewW
$scrollWheelNonBlockingW = 'async scrollPoint(e){let r=W(e.tabId);await this.dispatchMouseMove(r,e.point,e.modifiers),this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:e.point.x,y:e.point.y,deltaX:e.scrollX,deltaY:e.scrollY,modifiers:e.modifiers}).catch(()=>{})}'
$scrollWheelFinalW = 'async scrollPoint(e){let r=W(e.tabId);this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:e.point.x,y:e.point.y,deltaX:e.scrollX,deltaY:e.scrollY,modifiers:e.modifiers}).catch(()=>{})}'
$scrollGestureOldQ = 'async scrollPoint(t){let r=q(t.tabId),n=t.scrollX===0?0:-t.scrollX,o=t.scrollY===0?0:-t.scrollY;await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.synthesizeScrollGesture",{x:t.point.x,y:t.point.y,xDistance:n,yDistance:o,gestureSourceType:"mouse",preventFling:!0,speed:8e3})}'
$scrollWheelNewQ = 'async scrollPoint(t){let r=q(t.tabId);await this.dispatchMouseMove(r,t.point,t.modifiers),await this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers})}'
$scrollWheelBlockingQ = $scrollWheelNewQ
$scrollWheelNonBlockingQ = 'async scrollPoint(t){let r=q(t.tabId);await this.dispatchMouseMove(r,t.point,t.modifiers),this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers}).catch(()=>{})}'
$scrollWheelMoveBlockingQ = $scrollWheelNonBlockingQ
$scrollWheelFinalQ = 'async scrollPoint(t){let r=q(t.tabId);this.cdp.call(r,"Input.dispatchMouseEvent",{type:"mouseWheel",x:t.point.x,y:t.point.y,deltaX:t.scrollX,deltaY:t.scrollY,modifiers:t.modifiers}).catch(()=>{})}'

# History navigation (navigate_tab_back / navigate_tab_forward) awaited a full
# Page load event after Page.navigateToHistoryEntry. A BFCache restore never
# fires load, so each call burned the full default 10000 ms timeout.
# The replacement waits for Page.frameNavigated / Page.navigatedWithinDocument
# with a bounded timeout. Helpers TV/EV and waitForEvent already exist in the
# unpatched bundle, so no new runtime symbols are introduced.
$historyWaitNew = 'waitForEvent(r,a=>a.method==="Page.frameNavigated"?TV(a):a.method==="Page.navigatedWithinDocument"&&EV(a,e.cdp.mainFrameIdsByTabId),{timeoutMs:Math.min(n,2e3),timeoutMessage:"Timed out waiting for history navigation."}).catch(()=>{})'
$historyBackOld = 'no previous page in history.");let s=e.cdp.waitForPageLoadEvent(r,{timeoutMs:n})'
$historyBackNew = 'no previous page in history.");let s=e.cdp.' + $historyWaitNew
$historyForwardOld = 'no next page in history.");let s=e.cdp.waitForPageLoadEvent(r,{timeoutMs:n})'
$historyForwardNew = 'no next page in history.");let s=e.cdp.' + $historyWaitNew

# Response-meta latency: read-only DOM/screenshot/playwright commands paid for a
# full response-meta build on every call. LX is already defined in the unpatched
# bundle as the set of those command types, so an early return is enough.
$responseMetaAnchor = 'rt(s,"browser_use_response_meta_tabs_failed",b,{backend:t,commandType:r,phase:"response-meta-tabs"})}'
$responseMetaOld = $responseMetaAnchor
$responseMetaNew = $responseMetaAnchor + 'if(LX.has(r))return a;'

$patchPlan = New-Object System.Collections.Generic.List[object]

foreach ($target in $targets) {
  $text = Get-Text $target
  $hasAriaFallback = $text.Contains($ariaNew1) -or $text.Contains($ariaNew2) -or $text.Contains('_renderAriaSnapshot')
  $needsAria = $text.Contains($ariaOld1) -or $text.Contains($ariaOld3) -or $text.Contains($ariaOld4) -or (($text.Contains($ariaOld2)) -and -not $hasAriaFallback)
  $needsSite = $text.Contains($siteOld) -or $text.Contains($siteOldRp) -or $text.Contains($siteOldCd) -or $text.Contains($siteOldBp)
  $hasSiteBypass = $text.Contains($siteNew) -or $text.Contains($siteNewRp) -or $text.Contains($siteNewCd) -or $text.Contains($siteNewBp)
  $needsSiteTimeout = $text.Contains($siteFetchOld) -or $text.Contains($siteFetchNew)
  $hasSiteTimeout = $text.Contains($siteFetchWallClockNew) -or $text.Contains($siteFetchProxyNew)
  $needsSiteProxy = $text.Contains($siteFetchProxyOld) -or $text.Contains($siteFetchSignalOnlyOld)
  $hasSiteProxy = $text.Contains($siteFetchProxyNew)
  $needsCachedExpression = $text.Contains($cachedExpressionOld)
  $hasCachedExpressionFallback = $text.Contains($cachedExpressionNew)
  $needsFocusTimeout = $text.Contains($focusEmulationOld)
  $hasFocusTimeout = $text.Contains($focusEmulationNew)
  $needsOopifAutoAttachTimeout = $text.Contains($oopifAutoAttachOld)
  $hasOopifAutoAttachTimeout = $text.Contains($oopifAutoAttachNew)
  $needsNavigateTimeout = $text.Contains($navigateTimeoutOld)
  $hasNavigateTimeout = $text.Contains($navigateTimeoutNew)
  $needsScrollWheel = $text.Contains($scrollGestureOld) -or $text.Contains($scrollGestureOldW) -or $text.Contains($scrollGestureOldQ) -or $text.Contains($scrollWheelBlockingW) -or $text.Contains($scrollWheelNonBlockingW) -or $text.Contains($scrollWheelBlockingQ) -or $text.Contains($scrollWheelMoveBlockingQ)
  $hasScrollWheel = $text.Contains($scrollWheelNew) -or $text.Contains($scrollWheelFinalW) -or $text.Contains($scrollWheelNewQ) -or $text.Contains($scrollWheelNonBlockingQ)
  $hasHistoryNavigation = $text.Contains($historyBackNew) -and $text.Contains($historyForwardNew)
  $needsHistoryNavigation = $text.Contains($historyBackOld) -or $text.Contains($historyForwardOld)
  # $responseMetaNew contains the anchor, so "needs" must exclude the patched form.
  $hasResponseMetaLatency = $text.Contains($responseMetaNew)
  $needsResponseMetaLatency = $text.Contains($responseMetaOld) -and -not $hasResponseMetaLatency

  if ($needsAria) {
    $diagnosis.Add("ARIA snapshot compatibility patch needed for $target")
  }
  if ($needsSite) {
    $diagnosis.Add("Navigation site-status timeout bypass needed for $target")
  }
  if ($needsSiteTimeout) {
    $diagnosis.Add("Site-status request timeout guard needed for $target")
  }
  if ($needsSiteProxy) {
    $diagnosis.Add("Site-status proxy transport needed for $target")
  }
  if ($needsCachedExpression) {
    $diagnosis.Add("Unsupported cached CDP fallback needed for $target")
  }
  if ($needsFocusTimeout) {
    $diagnosis.Add("Focus-emulation timeout guard needed for $target")
  }
  if ($needsOopifAutoAttachTimeout) {
    $diagnosis.Add("OOPIF auto-attach timeout guard needed for $target")
  }
  if ($needsNavigateTimeout) {
    $diagnosis.Add("Navigation CDP timeout increase needed for $target")
  }
  if ($needsScrollWheel) {
    $diagnosis.Add("Reliable mouse-wheel scroll dispatch needed for $target")
  }
  if ($needsHistoryNavigation) {
    $diagnosis.Add("History back/forward event-wait patch needed for $target")
  }
  if ($needsResponseMetaLatency) {
    $diagnosis.Add("Response-meta latency short-circuit needed for $target")
  }

  $patchPlan.Add([pscustomobject]@{
    Path = $target
    Kind = if ($target -like "*\plugins\cache\*") { "cache" } else { "marketplace" }
    ScriptName = [IO.Path]::GetFileName($target)
    PluginName = if ($target -like "*\browser\*") { "browser" } else { "chrome" }
    Size = (Get-Item -LiteralPath $target).Length
    Sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    NeedsAria = $needsAria
    HasAriaFallback = $hasAriaFallback
    NeedsSiteBypass = $needsSite
    HasSiteBypass = $hasSiteBypass
    NeedsSiteTimeout = $needsSiteTimeout
    HasSiteTimeout = $hasSiteTimeout
    NeedsSiteProxy = $needsSiteProxy
    HasSiteProxy = $hasSiteProxy
    NeedsCachedExpression = $needsCachedExpression
    HasCachedExpressionFallback = $hasCachedExpressionFallback
    NeedsFocusTimeout = $needsFocusTimeout
    HasFocusTimeout = $hasFocusTimeout
    NeedsOopifAutoAttachTimeout = $needsOopifAutoAttachTimeout
    HasOopifAutoAttachTimeout = $hasOopifAutoAttachTimeout
    NeedsNavigateTimeout = $needsNavigateTimeout
    HasNavigateTimeout = $hasNavigateTimeout
    NeedsScrollWheel = $needsScrollWheel
    HasScrollWheel = $hasScrollWheel
    NeedsHistoryNavigation = $needsHistoryNavigation
    HasHistoryNavigation = $hasHistoryNavigation
    NeedsResponseMetaLatency = $needsResponseMetaLatency
    HasResponseMetaLatency = $hasResponseMetaLatency
  })
}

# Cache/marketplace drift is the mechanism behind "it worked until I restarted or
# reinstalled": the running cache copy is patched while the persistent marketplace
# source is not, so any refresh restores unpatched code. Compute this before the
# Diagnose section is printed so drift shows up as a diagnosis, not an afterthought.
$presentFlagNames = @(
  "HasAriaFallback", "HasSiteBypass", "HasSiteTimeout", "HasSiteProxy",
  "HasCachedExpressionFallback", "HasFocusTimeout", "HasOopifAutoAttachTimeout",
  "HasNavigateTimeout", "HasScrollWheel", "HasHistoryNavigation", "HasResponseMetaLatency"
)
$driftLines = [System.Collections.Generic.List[string]]::new()
foreach ($group in $patchPlan | Group-Object PluginName, ScriptName) {
  # "latest" and the pinned version directory can resolve to the same bytes, so
  # collapse identical content to avoid reporting the same drift several times.
  $cacheCopies = @($group.Group | Where-Object { $_.Kind -eq "cache" } | Group-Object Sha256 | ForEach-Object { $_.Group[0] })
  $marketCopies = @($group.Group | Where-Object { $_.Kind -eq "marketplace" } | Group-Object Sha256 | ForEach-Object { $_.Group[0] })
  if ($cacheCopies.Count -eq 0 -or $marketCopies.Count -eq 0) { continue }
  foreach ($cacheCopy in $cacheCopies) {
    foreach ($marketCopy in $marketCopies) {
      $differingPatches = @()
      foreach ($flagName in $presentFlagNames) {
        if ($cacheCopy.$flagName -ne $marketCopy.$flagName) {
          $differingPatches += ("{0}(cache={1},marketplace={2})" -f $flagName, $cacheCopy.$flagName, $marketCopy.$flagName)
        }
      }
      if ($differingPatches.Count -gt 0 -or $cacheCopy.Sha256 -ne $marketCopy.Sha256) {
        $driftLines.Add(("  DRIFT: {0} {1}" -f $cacheCopy.PluginName, $cacheCopy.ScriptName))
        $driftLines.Add(("    cache:       {0} (size={1})" -f $cacheCopy.Path, $cacheCopy.Size))
        $driftLines.Add(("    marketplace: {0} (size={1})" -f $marketCopy.Path, $marketCopy.Size))
        if ($differingPatches.Count -gt 0) {
          $driftLines.Add(("    differing patches: {0}" -f ($differingPatches -join "; ")))
          $diagnosis.Add("Cache/marketplace drift for $($cacheCopy.PluginName)/$($cacheCopy.ScriptName): $($differingPatches -join '; ')")
        } else {
          $driftLines.Add("    differing patches: none (content differs outside tracked patches)")
          $diagnosis.Add("Cache/marketplace content drift for $($cacheCopy.PluginName)/$($cacheCopy.ScriptName) outside tracked patches.")
        }
      }
    }
  }
}

if ($Detailed) {
  foreach ($r in $results) {
    "{0,-28} {1,-6} {2}" -f $r.Name, $r.Status, $r.Detail
  }
} else {
  $warningCount = @($results | Where-Object { $_.Status -in @("warn", "error") }).Count
  Write-Host ("Inspection complete: {0} checks, {1} warnings." -f $results.Count, $warningCount)
}

Write-Section "Diagnose"
if ($versionGateErrors.Count -gt 0) {
  $versionGateErrors | Select-Object -Unique | ForEach-Object {
    $diagnosis.Add($_)
  }
  Write-Host "VERSION SAFETY GATE: STOP - no files will be changed."
}
if ($diagnosis.Count -eq 0) {
  Write-Host "No known broken pattern detected. If Chrome still fails, run a live smoke test and inspect extension-host/runtime logs."
} else {
  $diagnosis | Select-Object -Unique | ForEach-Object { Write-Host "- $_" }
}

if ($Detailed) {
  Write-Host ""
  Write-Host "Patch plan:"
  foreach ($p in $patchPlan) {
      "{0}`n  aria: needs={1}, fallback_present={2}; site_status_bypass: needs={3}, present={4}; site_status_timeout: needs={5}, present={6}; site_status_proxy: needs={7}, present={8}; cached_cdp_fallback: needs={9}, present={10}; focus_timeout: needs={11}, present={12}; oopif_auto_attach_timeout: needs={13}, present={14}; navigate_timeout: needs={15}, present={16}; scroll_wheel: needs={17}, present={18}; history_navigation: needs={19}, present={20}; response_meta_latency: needs={21}, present={22}" -f $p.Path, $p.NeedsAria, $p.HasAriaFallback, $p.NeedsSiteBypass, $p.HasSiteBypass, $p.NeedsSiteTimeout, $p.HasSiteTimeout, $p.NeedsSiteProxy, $p.HasSiteProxy, $p.NeedsCachedExpression, $p.HasCachedExpressionFallback, $p.NeedsFocusTimeout, $p.HasFocusTimeout, $p.NeedsOopifAutoAttachTimeout, $p.HasOopifAutoAttachTimeout, $p.NeedsNavigateTimeout, $p.HasNavigateTimeout, $p.NeedsScrollWheel, $p.HasScrollWheel, $p.NeedsHistoryNavigation, $p.HasHistoryNavigation, $p.NeedsResponseMetaLatency, $p.HasResponseMetaLatency
  }
} else {
  Write-Host ("Pattern scan complete: {0} targets checked." -f $patchPlan.Count)
}

if ($Detailed) {
  Write-Host ""
  Write-Host "Cache/marketplace drift:"
  foreach ($p in $patchPlan) {
    "  {0,-11} {1,-11} {2,-19} size={3} sha256={4}" -f $p.PluginName, $p.Kind, $p.ScriptName, $p.Size, $p.Sha256.Substring(0, 12)
  }
  if ($driftLines.Count -gt 0) {
    $driftLines | ForEach-Object { Write-Host $_ }
  } else {
    Write-Host "  No drift: cache and marketplace copies agree on every tracked patch and hash."
  }
} else {
  if ($driftLines.Count -gt 0) {
    Write-Host ("Drift detected: {0} differences. Re-run with -Detailed for paths." -f $driftLines.Count)
  } else {
    Write-Host "Drift check: clean."
  }
}

if ($versionGateErrors.Count -gt 0) {
  Write-Section "VersionGate"
  $versionGateErrors | Select-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 2
}

Write-Section "Verify"
if (-not (Invoke-SyntaxCheck $targets)) { exit 1 }

if ($VerifyOnly) {
  Write-Section "VerifyOnly"
  Write-Host "No files changed."
  Write-Host "State: ACK_REQUIRED (static checks passed; live Chrome ACK still required.)"
  exit 0
}

Write-Section "Repair"
$changed = New-Object System.Collections.Generic.List[string]
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"

foreach ($p in $patchPlan) {
  if (-not ($p.NeedsAria -or $p.NeedsSiteBypass -or $p.NeedsSiteTimeout -or $p.NeedsSiteProxy -or $p.NeedsCachedExpression -or $p.NeedsFocusTimeout -or $p.NeedsOopifAutoAttachTimeout -or $p.NeedsNavigateTimeout -or $p.NeedsScrollWheel -or $p.NeedsHistoryNavigation -or $p.NeedsResponseMetaLatency)) {
    Write-Detailed "No patch needed: $($p.Path)"
    continue
  }

  $backup = "$($p.Path).$timestamp.chrome-xiufu.bak"
  Copy-Item -LiteralPath $p.Path -Destination $backup -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $backup)) {
    Write-Host "BACKUP FAILED: cannot write $backup"
    Write-Host "  Refusing to patch a file that cannot be backed up. This is a write-permission problem, NOT a plugin-version problem."
    exit 4
  }
  Write-Detailed "Backup: $backup"

  $text = Get-Text $p.Path
  if ($p.NeedsAria) {
    $text = $text.Replace($ariaOld1, $ariaNew1).Replace($ariaOld2, $ariaNew2).Replace($ariaOld3, $ariaNew3).Replace($ariaOld4, $ariaNew4)
  }
  if ($p.NeedsSiteBypass) {
    $text = $text.Replace($siteOld, $siteNew).Replace($siteOldRp, $siteNewRp).Replace($siteOldCd, $siteNewCd).Replace($siteOldBp, $siteNewBp)
  }
  if ($p.NeedsSiteTimeout) {
    $text = $text.Replace($siteFetchOld, $siteFetchWallClockNew).Replace($siteFetchNew, $siteFetchWallClockNew)
  }
  if ($p.NeedsSiteProxy) {
    $text = $text.Replace($siteFetchNew, $siteFetchProxyNew).Replace($siteFetchProxyOld, $siteFetchProxyNew).Replace($siteFetchSignalOnlyOld, $siteFetchProxyNew)
  }
  if ($p.NeedsCachedExpression) {
    $text = $text.Replace($cachedExpressionOld, $cachedExpressionNew)
  }
  if ($p.NeedsFocusTimeout) {
    $text = $text.Replace($focusEmulationOld, $focusEmulationNew)
  }
  if ($p.NeedsOopifAutoAttachTimeout) {
    $text = $text.Replace($oopifAutoAttachOld, $oopifAutoAttachNew)
  }
  if ($p.NeedsNavigateTimeout) {
    $text = $text.Replace($navigateTimeoutOld, $navigateTimeoutNew)
  }
  if ($p.NeedsScrollWheel) {
    $text = $text.Replace($scrollGestureOld, $scrollWheelNew).Replace($scrollGestureOldW, $scrollWheelNewW).Replace($scrollGestureOldQ, $scrollWheelNewQ).Replace($scrollWheelBlockingW, $scrollWheelNonBlockingW).Replace($scrollWheelNonBlockingW, $scrollWheelFinalW).Replace($scrollWheelBlockingQ, $scrollWheelNonBlockingQ).Replace($scrollWheelMoveBlockingQ, $scrollWheelFinalQ)
  }
  if ($p.NeedsHistoryNavigation) {
    $text = $text.Replace($historyBackOld, $historyBackNew).Replace($historyForwardOld, $historyForwardNew)
  }
  if ($p.NeedsResponseMetaLatency) {
    $text = $text.Replace($responseMetaOld, $responseMetaNew)
  }
  $expected = $text
  Set-Text $p.Path $text
  # A sandboxed or permission-restricted write can fail without throwing, which would
  # otherwise make this script report success while the file stays unpatched.
  $actual = Get-Text $p.Path
  if ($actual -ne $expected) {
    Write-Host "WRITE VERIFICATION FAILED: $($p.Path)"
    Write-Host "  The file on disk does not match the patched content. The write was blocked or reverted."
    Write-Host "  This is a write-permission problem, NOT a plugin-version problem. Grant write access and re-run."
    exit 4
  }
  $changed.Add($p.Path)
  Write-Detailed "Patched: $($p.Path)"
}

Write-Section "Verify"
if (-not (Invoke-SyntaxCheck $targets)) { exit 1 }

if ($changed.Count -eq 0) {
  Write-Host "No changes were necessary."
} else {
  Write-Host ("Patched {0} files. Backups created." -f $changed.Count)
  if ($Detailed) {
    Write-Host "Changed files:"
    $changed | ForEach-Object { Write-Host "- $_" }
  }
  Write-Host "Reset the Node REPL or restart Codex/extension-host before live retesting."
}
if ($changed.Count -gt 0) {
  Write-Host "State: RECONNECT_REQUIRED (run the live Chrome ACK after reconnect.)"
} else {
  Write-Host "State: ACK_REQUIRED (static checks passed; live Chrome ACK still required.)"
}

