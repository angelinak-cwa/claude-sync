# ccsync-orca.ps1 — часть ccsync, которая говорит с Orca. Вызывается из ccsync.sh.
#
#   -Mode snapshot   записать проекты/workspaces (structure/<компьютер>.json), открытые вкладки с чатами
#                    (tabs/<компьютер>.json) и список папок для синхронизации файлов ($State\units)
#   -Mode apply      создать проекты и workspaces, которые есть на другом компьютере (Т4, Т5),
#                    и открыть вкладки с его незакрытыми чатами (Т2, Т3, Т12)
#   -Mode reopen     закрыть вкладку с устаревшим чатом, подставить свежую версию и открыть его заново (Т12)
#   -Mode status     что сделано и что не получилось
#
# Orca нужна запущенной: без неё всё молча пропускается и пишется в $State\orca.log.

param(
  [string]$Mode,
  [string]$Data,
  [string]$State,
  [string]$HomeDir,
  [string]$ClaudeProjects,
  [string]$Machine,
  [string]$Request
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$orcaData = if ($env:ORCA_USER_DATA_PATH) { $env:ORCA_USER_DATA_PATH } else { Join-Path $env:APPDATA 'orca' }
$homeNorm = ($HomeDir -replace '\\', '/').TrimEnd('/')

function Log([string]$msg) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm') + " $msg"
  $f = Join-Path $State 'orca.log'
  $old = @()
  if (Test-Path -LiteralPath $f) { $old = @([IO.File]::ReadAllLines($f, $utf8) | Select-Object -Last 200) }
  [IO.File]::WriteAllLines($f, [string[]]($old + $line), $utf8)
}

function Read-Json([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return [IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json } catch { return $null }
}

# Список строк из JSON-массива строк. ConvertFrom-Json в PowerShell 5 путается с пустыми и
# вложенными массивами, поэтому строки просто достаём из текста.
function Read-JsonList([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return ,@() }
  $text = [IO.File]::ReadAllText($path, $utf8)
  return ,@([regex]::Matches($text, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { [regex]::Unescape($_.Groups[1].Value) })
}

function Write-Text([string]$path, [string]$text) {
  $dir = Split-Path $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  [IO.File]::WriteAllText($path, $text, $utf8)
}

# Записать JSON, только если содержимое изменилось: иначе каждая синхронизация давала бы пустой коммит.
function Write-JsonIfChanged([string]$path, $obj) {
  $text = (ConvertTo-Json -InputObject $obj -Depth 8) -replace "`r`n", "`n"
  if ((Test-Path -LiteralPath $path) -and ([IO.File]::ReadAllText($path, $utf8) -eq $text)) { return }
  Write-Text $path $text
}

function To-Rel([string]$p) {
  if (-not $p) { return $null }
  $n = ($p -replace '\\', '/').TrimEnd('/')
  if ($n.ToLower().StartsWith($homeNorm.ToLower() + '/')) { return $n.Substring($homeNorm.Length + 1) }
  return $null
}
function To-Full([string]$rel) { return Join-Path $HomeDir ($rel -replace '/', '\') }

# Claude Code называет папку чатов по пути проекта, заменяя всё, кроме букв и цифр, на «-».
function Encode([string]$p) { return ($p -replace '\\', '/') -replace '[^A-Za-z0-9]', '-' }

# --- Orca CLI ------------------------------------------------------------------

$script:orca = $null
$c = Get-Command orca.exe -ErrorAction SilentlyContinue
if ($c) { $script:orca = $c.Source }
elseif (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\orca\resources\bin\orca.exe')) { $script:orca = Join-Path $env:LOCALAPPDATA 'Programs\orca\resources\bin\orca.exe' }

function Orca([string[]]$a) {
  $out = & $script:orca @a --json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) { throw "orca $($a -join ' '): ошибка" }
  $j = ($out -join "`n") | ConvertFrom-Json
  if (-not $j.ok) { throw "orca $($a -join ' '): $($j.error.message)" }
  return $j.result
}

function Orca-Ready {
  if (-not $script:orca) { return $false }
  try { return [bool](Orca @('status')).runtime.reachable } catch { return $false }
}

# Вкладки с Claude: какой чат (session id) в какой вкладке, по Ф9. Если Orca не знает id,
# берём самый свежий чат в папке этого workspace.
function Get-ClaudeTabs {
  $terms = @((Orca @('terminal', 'list')).terminals)
  $st = Read-Json (Join-Path $orcaData 'agent-hooks\last-status.json')
  foreach ($t in $terms) {
    if ($t.agentIdentity -ne 'claude') { continue }
    $pane = "$($t.tabId):$($t.leafId)"
    $e = $null
    if ($st -and $st.entries) { $e = $st.entries.$pane }
    $sid = $null; $state = $null
    if ($e -and $e.providerSession) { $sid = $e.providerSession.id }
    if ($e -and $e.payload) { $state = $e.payload.state }
    if (-not $sid) {
      $dir = Join-Path $ClaudeProjects (Encode $t.worktreePath)
      $last = Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
      if ($last) { $sid = $last.BaseName }
    }
    [pscustomobject]@{ handle = $t.handle; pane = $pane; path = $t.worktreePath; title = $t.title; sid = $sid; state = $state }
  }
}

function Load-Aliases {
  $map = @{}
  $f = Join-Path $Data 'structure\aliases.tsv'
  if (-not (Test-Path -LiteralPath $f)) { return $map }
  foreach ($line in [IO.File]::ReadAllLines($f, $utf8)) {
    if (-not $line -or $line.StartsWith('#')) { continue }
    $parts = $line.TrimEnd("`r").Split("`t")
    if ($parts.Count -ge 2 -and $parts[0]) { $map[$parts[0].ToLower()] = $parts[1] }
  }
  return $map
}

function Resolve-Alias($aliases, [string]$rel) {
  if ($rel -and $aliases.ContainsKey($rel.ToLower())) { return $aliases[$rel.ToLower()] }
  return $rel
}

function Contains-Path($list, [string]$rel) {
  foreach ($x in $list) { if ($x -and $x.ToLower() -eq $rel.ToLower()) { return $true } }
  return $false
}

# --- snapshot ------------------------------------------------------------------

function Snapshot {
  $repos = @((Orca @('repo', 'list')).repos)
  $wts = @((Orca @('worktree', 'list')).worktrees)

  $repoList = @(); $wtList = @(); $units = @()
  foreach ($r in $repos) {
    $rel = To-Rel $r.path
    if (-not $rel) { continue }
    $main = $wts | Where-Object { $_.repoId -eq $r.id -and $_.isMainWorktree } | Select-Object -First 1
    $branch = 'master'
    if ($main -and $main.branch) { $branch = $main.branch -replace '^refs/heads/', '' }
    $remote = $null
    if ($r.gitRemoteIdentity) { $remote = $r.gitRemoteIdentity.remoteUrl }
    $repoList += [ordered]@{ path = $rel; name = $r.displayName; branch = $branch; remote = $remote }
    $units += $rel
  }
  foreach ($w in $wts) {
    if ($w.isMainWorktree -or $w.isArchived) { continue }
    $rel = To-Rel $w.path
    $repo = $repos | Where-Object { $_.id -eq $w.repoId } | Select-Object -First 1
    if (-not $rel -or -not $repo) { continue }
    $wtList += [ordered]@{ repo = (To-Rel $repo.path); path = $rel; name = (Split-Path $rel -Leaf); display = $w.displayName; branch = ($w.branch -replace '^refs/heads/', '') }
    $units += $rel
  }
  $repoList = @($repoList | Sort-Object { $_.path }); $wtList = @($wtList | Sort-Object { $_.path })

  # Что было здесь раньше, а теперь нет, — удалено на этом компьютере: не создавать заново (Т7, без автоудаления).
  $current = @($repoList | ForEach-Object { $_.path }) + @($wtList | ForEach-Object { $_.path })
  $known = (Read-JsonList (Join-Path $State 'structure-known.json'))
  $removedOld = (Read-JsonList (Join-Path $State 'structure-removed.json'))
  $removed = @(@($known) + @($removedOld) | Where-Object { $_ -and -not (Contains-Path $current $_) } | Sort-Object -Unique)
  Write-JsonIfChanged (Join-Path $State 'structure-known.json') @($current)
  Write-JsonIfChanged (Join-Path $State 'structure-removed.json') @($removed)

  Write-JsonIfChanged (Join-Path $Data "structure\$Machine.json") ([ordered]@{ machine = $Machine; repos = $repoList; worktrees = $wtList; removed = $removed })
  [IO.File]::WriteAllText((Join-Path $State 'units'), (($units | Sort-Object -Unique) -join "`n") + "`n", $utf8)

  # Вкладки: у каждой запоминаем историю чатов, чтобы после /clear другой компьютер понял,
  # какую свою вкладку заменить новым чатом (Т12).
  $histFile = Join-Path $State 'tab-history.json'
  $histOld = Read-Json $histFile
  $hist = [ordered]@{}
  $tabList = @()
  foreach ($t in @(Get-ClaudeTabs)) {
    if (-not $t.sid) { continue }
    $h = @()
    if ($histOld -and $histOld.($t.pane)) { $h = @($histOld.($t.pane)) }
    if ($h.Count -eq 0 -or $h[-1] -ne $t.sid) { $h += $t.sid }
    $h = @($h | Select-Object -Last 20)
    $hist[$t.pane] = $h
    $rel = To-Rel $t.path
    if ($rel) { $tabList += [ordered]@{ path = $rel; title = $t.title; sid = $t.sid; history = $h } }
  }
  Write-JsonIfChanged $histFile $hist
  $tabList = @($tabList | Sort-Object { $_.path }, { $_.sid })
  Write-JsonIfChanged (Join-Path $Data "tabs\$Machine.json") ([ordered]@{ machine = $Machine; tabs = $tabList })
}

# --- apply ---------------------------------------------------------------------

function New-Project([string]$rel, $r) {
  $full = To-Full $rel
  if (-not (Test-Path -LiteralPath (Join-Path $full '.git'))) {
    New-Item -ItemType Directory -Force $full | Out-Null
    $branch = if ($r.branch) { $r.branch } else { 'master' }
    & git -C $full init -q -b $branch 2>$null | Out-Null
    $id = @()
    if (-not (& git -C $full config user.email 2>$null)) { $id = @('-c', 'user.name=ccsync', '-c', 'user.email=ccsync@localhost') }
    & git -C $full @id commit -q --allow-empty -m 'ccsync: init' 2>$null | Out-Null
    # Тот же origin, что на другом компьютере: по нему Orca узнаёт проект (Ф22). Ничего из него не скачиваем.
    if ($r.remote) { & git -C $full remote add origin $r.remote 2>$null | Out-Null }
  }
  Orca @('repo', 'add', '--path', $full) | Out-Null
  Log "создан проект $rel"
}

function New-Workspace([string]$rel, [string]$repoRel, $w) {
  $name = Split-Path $rel -Leaf
  if (Test-Path -LiteralPath (To-Full $rel)) { Log "workspace $rel не создан: папка уже есть, но это не workspace Orca"; return }
  Orca @('worktree', 'create', '--repo', "path:$(To-Full $repoRel)", '--name', $name, '--no-parent', '--setup', 'skip') | Out-Null
  $created = @((Orca @('worktree', 'list')).worktrees) | Where-Object { (To-Rel $_.path) -and (To-Rel $_.path).ToLower() -eq $rel.ToLower() } | Select-Object -First 1
  if (-not $created) { Log "workspace $rel : Orca создала его по другому пути"; return }
  if ($w.display -and $w.display -ne $created.displayName) {
    Orca @('worktree', 'set', '--worktree', "path:$($created.path)", '--display-name', $w.display) | Out-Null
  }
  Log "создан workspace $rel"
}

function Apply {
  $aliases = Load-Aliases
  $removed = (Read-JsonList (Join-Path $State 'structure-removed.json'))
  $repos = @((Orca @('repo', 'list')).repos)
  $wts = @((Orca @('worktree', 'list')).worktrees)
  $localRepos = @($repos | ForEach-Object { To-Rel $_.path } | Where-Object { $_ })
  $localPaths = @($localRepos) + @($wts | ForEach-Object { To-Rel $_.path } | Where-Object { $_ })

  $files = @(Get-ChildItem -LiteralPath (Join-Path $Data 'structure') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ne $Machine })
  foreach ($f in $files) {
    $s = Read-Json $f.FullName
    if (-not $s) { continue }
    foreach ($r in @($s.repos)) {
      $t = Resolve-Alias $aliases $r.path
      if (-not $t -or $t -eq '-' -or (Contains-Path $localPaths $t) -or (Contains-Path $removed $t)) { continue }
      try { New-Project $t $r; $localRepos += $t; $localPaths += $t } catch { Log "проект $t не создан: $($_.Exception.Message)" }
    }
    foreach ($w in @($s.worktrees)) {
      $t = Resolve-Alias $aliases $w.path
      if (-not $t -or $t -eq '-' -or (Contains-Path $localPaths $t) -or (Contains-Path $removed $t)) { continue }
      $repoT = Resolve-Alias $aliases $w.repo
      if (-not (Contains-Path $localRepos $repoT)) { Log "workspace $t ждёт проект $repoT"; continue }
      try { New-Workspace $t $repoT $w; $localPaths += $t } catch { Log "workspace $t не создан: $($_.Exception.Message)" }
    }
  }

  # Вкладки другого компьютера: открыть чаты, которых здесь не открыто (Т2, Т3). Вкладку, которую
  # уже открывали отсюда и потом закрыли, второй раз не открываем.
  $appliedFile = Join-Path $State 'tabs-applied.json'
  $appliedOld = Read-Json $appliedFile
  $applied = @{}
  if ($appliedOld) { foreach ($p in $appliedOld.PSObject.Properties) { $applied[$p.Name] = @($p.Value) } }
  $local = @(Get-ClaudeTabs)
  $open = @($local | ForEach-Object { $_.sid } | Where-Object { $_ })

  $tabFiles = @(Get-ChildItem -LiteralPath (Join-Path $Data 'tabs') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ne $Machine })
  foreach ($f in $tabFiles) {
    $s = Read-Json $f.FullName
    if (-not $s) { continue }
    $m = $f.BaseName
    if (-not $applied.ContainsKey($m)) { $applied[$m] = @() }
    foreach ($t in @($s.tabs)) {
      if (-not $t.sid) { continue }
      if ($open -contains $t.sid) { if ($applied[$m] -notcontains $t.sid) { $applied[$m] += $t.sid }; continue }
      if ($applied[$m] -contains $t.sid) { continue }
      $target = Resolve-Alias $aliases $t.path
      if (-not $target -or $target -eq '-') { continue }
      $full = To-Full $target
      if (-not (Test-Path -LiteralPath $full)) { continue }
      if (-not (Get-ChildItem -Path (Join-Path $ClaudeProjects "*\$($t.sid).jsonl") -File -ErrorAction SilentlyContinue)) { continue }
      # После /clear на другом компьютере во вкладке новый чат: здесь заменяем вкладку со старым.
      $old = $local | Where-Object { $_.sid -and $_.sid -ne $t.sid -and (@($t.history) -contains $_.sid) } | Select-Object -First 1
      try {
        Orca @('terminal', 'create', '--worktree', "path:$full", '--title', $t.title, '--command', "claude --resume $($t.sid)") | Out-Null
        $applied[$m] += $t.sid
        $open += $t.sid
        Log "открыт чат $($t.sid) ($($t.title)) в $target"
        if ($old -and (-not $old.state -or $old.state -eq 'done')) {
          Orca @('terminal', 'close', '--terminal', $old.handle, '--tab') | Out-Null
          Log "закрыта вкладка со старым чатом $($old.sid)"
        }
      } catch { Log "чат $($t.sid) не открыт: $($_.Exception.Message)" }
    }
    $applied[$m] = @($applied[$m] | Select-Object -Last 500)
  }
  Write-JsonIfChanged $appliedFile $applied
}

# --- reopen (Т12) ----------------------------------------------------------------

function Take-Lock {
  $lock = Join-Path $State 'lock'
  for ($i = 0; $i -lt 60; $i++) {
    try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null; [IO.File]::WriteAllText((Join-Path $lock 'since'), [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()); return $true }
    catch { Start-Sleep -Seconds 1 }
  }
  return $false
}

function Reopen {
  $req = @{}
  foreach ($line in [IO.File]::ReadAllLines($Request, $utf8)) { $i = $line.IndexOf('='); if ($i -gt 0) { $req[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
  Start-Sleep -Seconds 2
  $title = $null
  try { $title = (@((Orca @('terminal', 'list')).terminals) | Where-Object { $_.handle -eq $req.terminal } | Select-Object -First 1).title } catch {}
  # Если вкладку закрыть не удалось, ничего не подменяем: свежая версия останется в pending
  # и подставится, когда сессию закроют (SessionEnd в ccsync.sh).
  try { Orca @('terminal', 'close', '--terminal', $req.terminal, '--tab') | Out-Null }
  catch { Log "не удалось закрыть вкладку $($req.terminal): $($_.Exception.Message)"; return }
  Start-Sleep -Seconds 2

  $locked = Take-Lock
  try {
    if (Test-Path -LiteralPath $req.pending) {
      Move-Item -LiteralPath $req.pending -Destination $req.transcript -Force
      New-Item -ItemType Directory -Force (Join-Path $State 'known') | Out-Null
      [IO.File]::WriteAllText((Join-Path $State "known\$($req.sid)"), [string](Get-Item -LiteralPath $req.transcript).Length + "`n")
      Log "чат $($req.sid) заменён свежей версией"
    } else {
      Log "чат $($req.sid): свежей версии нет (уже подставлена?)"
    }
  } finally {
    if ($locked) { Remove-Item -LiteralPath (Join-Path $State 'lock') -Recurse -Force -ErrorAction SilentlyContinue }
  }

  $cargs = @('terminal', 'create', '--worktree', "path:$($req.worktree)", '--command', "claude --resume $($req.sid)", '--focus')
  if ($title) { $cargs += @('--title', $title) }
  try { Orca $cargs | Out-Null; Log "чат $($req.sid) открыт заново" } catch { Log "чат $($req.sid) не открыт заново: $($_.Exception.Message)" }
  Remove-Item -LiteralPath $Request -Force -ErrorAction SilentlyContinue
}

# --- status --------------------------------------------------------------------

function Status {
  if (Orca-Ready) { 'ccsync: Orca: запущена, проекты и вкладки синхронизируются' } else { 'ccsync: Orca: не запущена — проекты и вкладки синхронизируются, когда она будет открыта' }
  $removed = (Read-JsonList (Join-Path $State 'structure-removed.json'))
  if ($removed.Count) { "ccsync: удалено на этом компьютере (на других осталось, само не удаляется): $($removed -join ', ')" }
  $aliases = Load-Aliases
  $units = @()
  if (Test-Path -LiteralPath (Join-Path $State 'units')) { $units = @([IO.File]::ReadAllLines((Join-Path $State 'units'), $utf8)) }
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Data 'structure') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ne $Machine })) {
    $s = Read-Json $f.FullName
    $rem = @($s.removed | Where-Object { $_ -and (Contains-Path $units (Resolve-Alias $aliases $_)) })
    if ($rem.Count) { "ccsync: удалено на $($f.BaseName), а здесь есть (убрать вручную, если не нужно): $($rem -join ', ')" }
  }
  $log = Join-Path $State 'orca.log'
  if (Test-Path -LiteralPath $log) {
    'ccsync: последние действия с Orca:'
    [IO.File]::ReadAllLines($log, $utf8) | Select-Object -Last 8 | ForEach-Object { "  $_" }
  }
}

# --- main ------------------------------------------------------------------------

try {
  switch ($Mode) {
    'snapshot' { if (Orca-Ready) { Snapshot } }
    'apply' { if (Orca-Ready) { Apply } }
    'reopen' { if (Orca-Ready) { Reopen } }
    'status' { Status }
  }
} catch {
  Log "$Mode : $($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber)]"
}
exit 0
