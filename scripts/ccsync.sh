#!/usr/bin/env bash
# ccsync — синхронизация Claude Code (и Orca) между компьютерами через приватный git-репозиторий.
#
#   ccsync.sh start            SessionStart: подтянуть изменения, открыть проекты и вкладки с другого компьютера
#   ccsync.sh prompt           UserPromptSubmit: проверить, не дописан ли текущий чат на другом компьютере
#   ccsync.sh stop             Stop: отправить свои изменения (по умолчанию после каждого ответа)
#   ccsync.sh end              SessionEnd: отправить свои изменения сразу
#   ccsync.sh bg               фоновая синхронизация (её запускает prompt, чтобы не задерживать сообщение)
#   ccsync.sh now              ручная полная синхронизация
#   ccsync.sh tabs             открыть проекты, workspaces и вкладки с незакрытыми чатами другого компьютера
#   ccsync.sh setup <url>      подключить репозиторий с данными (один раз на каждом компьютере)
#   ccsync.sh status           что настроено и когда была последняя синхронизация
#
# Что лежит в репозитории с данными:
#   projects/   всё из ~/.claude/projects/<папка>/ — чаты (*.jsonl, <id>/subagents, <id>/tool-results) и память (memory/*.md)
#   global/     общие правила: ~/.claude/CLAUDE.md, rules/, skills/ (кроме synced/), commands/, agents/
#   files/      файлы проектов и workspaces Orca: CLAUDE.md, .claude/ и мелкие файлы (без .git, секретов и *.local.*)
#   structure/  проекты и workspaces Orca каждого компьютера; aliases.tsv — какие старые папки чему соответствуют
#   tabs/       открытые вкладки Orca с чатами Claude на каждом компьютере
# Пути считаются относительно домашней папки, поэтому разные имена пользователя не мешают.

set -u
export LC_ALL=C.UTF-8

MODE="${1:-now}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOCAL_ROOT="$CLAUDE_DIR/projects"
DATA="${CCSYNC_DIR:-$HOME/.claude-sync-data}"
REPO_ROOT="$DATA/projects"
STATE_DIR="${CCSYNC_STATE_DIR:-$HOME/.claude-sync-state}"
HOME_DIR="${CCSYNC_HOME:-$HOME}"
INTERVAL="${CCSYNC_INTERVAL:-0}"
MACHINE="${CCSYNC_MACHINE:-$(hostname 2>/dev/null || echo unknown)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAX_FILE=5242880

mkdir -p "$STATE_DIR"

# Путь к плагину запоминаем, чтобы слэш-команды могли найти этот скрипт.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  printf '%s\n' "$CLAUDE_PLUGIN_ROOT" > "$STATE_DIR/plugin-root"
fi

# Хуки получают JSON на stdin; из него нужны id текущего чата и путь к его файлу.
SID=""
TRANSCRIPT=""
json_field() { printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1; }
case "$MODE" in
  start|prompt|stop|end)
    INPUT="$(cat)"
    SID="$(json_field session_id)"
    TRANSCRIPT="$(json_field transcript_path | sed 's/\\\\/\\/g')"
    if [ -n "$TRANSCRIPT" ] && command -v cygpath >/dev/null 2>&1; then TRANSCRIPT="$(cygpath -u "$TRANSCRIPT")"; fi ;;
esac

[ "${CCSYNC_DISABLE:-0}" = 1 ] && exit 0

say() { printf 'ccsync: %s\n' "$*"; }

# Claude Code называет папку проекта по его пути, заменяя всё, кроме букв и цифр, на «-».
encode() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

if [ -n "${CCSYNC_HOME_NATIVE:-}" ]; then
  HOME_NATIVE="$CCSYNC_HOME_NATIVE"
elif [ -n "${USERPROFILE:-}" ]; then
  HOME_NATIVE="$USERPROFILE"
else
  HOME_NATIVE="$HOME"
fi
PREFIX="$(encode "$HOME_NATIVE")"

configured() { [ -d "$DATA/.git" ] && git -C "$DATA" remote get-url origin >/dev/null 2>&1; }

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Всё, что говорит с Orca (проекты, workspaces, вкладки), — в ccsync-orca.ps1: Orca есть только на Windows.
# Без PowerShell или без запущенной Orca эта часть просто пропускается.
orca_helper() {
  [ "${CCSYNC_NO_ORCA:-0}" = 1 ] && return 0
  command -v powershell.exe >/dev/null 2>&1 || return 0
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(winpath "$SCRIPT_DIR/ccsync-orca.ps1")" \
    -Mode "$1" -Data "$(winpath "$DATA")" -State "$(winpath "$STATE_DIR")" -HomeDir "$(winpath "$HOME_DIR")" \
    -ClaudeProjects "$(winpath "$LOCAL_ROOT")" -Machine "$MACHINE" "${@:2}" 2>/dev/null | tr -d '\r'
}

# Запустить команду этого скрипта полностью отдельно от хука: хук не ждёт её, и её не убивают вместе с ним.
detach() {
  if command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    local bash_exe="${CLAUDE_CODE_GIT_BASH_PATH:-$(cygpath -w "$(command -v bash)")}"
    powershell.exe -NoProfile -NonInteractive -Command \
      "Start-Process -WindowStyle Hidden -FilePath '$bash_exe' -ArgumentList '\"$(winpath "$SCRIPT_DIR/ccsync.sh")\" $1'" >/dev/null 2>&1
  else
    nohup bash "$SCRIPT_DIR/ccsync.sh" "$1" </dev/null >/dev/null 2>&1 &
  fi
}

# --- блокировка: в Orca одновременно работают несколько сессий ---------------

LOCK="$STATE_DIR/lock"
lock() {
  local tries="$1" i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    local since now
    since="$(cat "$LOCK/since" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ $((now - since)) -gt 300 ]; then
      rm -rf "$LOCK"
      continue
    fi
    i=$((i + 1))
    [ "$i" -ge "$tries" ] && return 1
    sleep 1
  done
  date +%s > "$LOCK/since"
  trap 'rm -rf "$LOCK"' EXIT
}
unlock() { rm -rf "$LOCK"; trap - EXIT; }

# --- чаты и память: ~/.claude/projects ----------------------------------------

# Строки вида «<тег> <число> <путь>» для awk; путь приводится к виду HOME-orca-projects-x/…
scan() {
  local dirs=() d
  if [ -d "$LOCAL_ROOT" ]; then
    for d in "$LOCAL_ROOT/$PREFIX" "$LOCAL_ROOT/$PREFIX"-*; do
      [ -d "$d" ] && dirs+=("./${d##*/}")
    done
  fi
  if [ "${#dirs[@]}" -gt 0 ]; then
    (cd "$LOCAL_ROOT" && find "${dirs[@]}" -type f -exec wc -c {} +) | awk -v p="$PREFIX" '$2 ~ /^\.\// { n=$1; sub(/^ *[0-9]+ \.\//, ""); sub("^" p, "HOME"); print "L", n, $0 }'
    (cd "$LOCAL_ROOT" && find "${dirs[@]}" -type f -path '*/memory/*' -exec cksum {} +) | awk -v p="$PREFIX" '{ c=$1; sub(/^[0-9]+ [0-9]+ \.\//, ""); sub("^" p, "HOME"); print "LC", c, $0 }'
  fi
  if [ -d "$REPO_ROOT" ]; then
    (cd "$REPO_ROOT" && find . -type f -exec wc -c {} +) | awk '$2 ~ /^\.\// { n=$1; sub(/^ *[0-9]+ \.\//, ""); print "R", n, $0 }'
    (cd "$REPO_ROOT" && find . -type f -path '*/memory/*' -exec cksum {} +) | awk '{ c=$1; sub(/^[0-9]+ [0-9]+ \.\//, ""); print "RC", c, $0 }'
  fi
  [ -f "$STATE_DIR/memory-state" ] && awk '{ c=$1; sub(/^[0-9]+ /, ""); print "B", c, $0 }' "$STATE_DIR/memory-state"
}

# Решает, что куда копировать.
#   Чаты только дописываются, поэтому побеждает более длинная версия; удаление не переносим.
#   Память сверяем с тем, что было при прошлой синхронизации: изменилось только с одной стороны —
#   переносим, удалено с одной стороны — удаляем, изменено с обеих — MEMORY.md склеиваем,
#   остальное оставляем локальную версию, а чужую кладём в conflicts/.
#   Чаты, которые ждут переоткрытия в свежей версии ($STATE_DIR/pending), не трогаем совсем.
#   Чаты, открытые сейчас в любом окне Claude на этом компьютере, только отправляем: их файл держит
#   запущенный Claude, и подменять его нельзя (свежую версию подставит reopen, Т12).
plan() {
  { scan
    ls "$STATE_DIR/pending" 2>/dev/null | sed -n 's/\.jsonl$//p' | awk '{ print "H 0 " $0 }'
    open_sids | awk '{ print "O 0 " $0 }'
  } | awk -v sid="$SID" '
    $1=="H" { hold[$3]=1; next }
    $1=="O" { open[$3]=1; next }
    { tag=$1; val=$2; sub(/^[A-Z]+ [0-9]+ /, ""); p=$0
      for (h in hold) if (index(p, "/" h ".jsonl") || index(p, "/" h "/")) next
      all[p]=1
      if (tag=="L") L[p]=val; else if (tag=="R") R[p]=val
      else if (tag=="LC") LC[p]=val; else if (tag=="RC") RC[p]=val; else if (tag=="B") B[p]=val }
    END {
      for (p in all) {
        if (p ~ /\/memory\//) {
          l=(p in LC)?LC[p]:""; r=(p in RC)?RC[p]:""; b=(p in B)?B[p]:""
          if (l!="" && r!="") {
            if (l==r) continue
            if (l==b) print "R2L", p
            else if (r==b) print "L2R", p
            else if (p ~ /\/MEMORY\.md$/) print "MERGE", p
            else print "CONFLICT", p
          } else if (l!="") { if (b!="" && l==b) print "RML", p; else print "L2R", p }
          else if (r!="") { if (b!="" && r==b) print "RMR", p; else print "R2L", p }
        } else {
          current = (sid!="" && (index(p, "/" sid ".jsonl") || index(p, "/" sid "/")))
          for (o in open) if (index(p, "/" o ".jsonl") || index(p, "/" o "/")) current=1
          if (!(p in R) || (p in L && L[p]+0 > R[p]+0)) print "L2R", p
          else if (!current && (!(p in L) || R[p]+0 > L[p]+0)) print "R2L", p
        }
      }
    }'
}

# id чатов, открытых сейчас в запущенных Claude: Claude ведёт ~/.claude/sessions/<pid>.json.
open_sids() {
  local dir="$CLAUDE_DIR/sessions" f pid alive=""
  [ -d "$dir" ] || return 0
  if command -v tasklist >/dev/null 2>&1; then alive="$(tasklist //FO CSV //NH 2>/dev/null | awk -F'","' '{ print $2 }')"; fi
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; pid="${pid%.json}"
    if [ -n "$alive" ]; then printf '%s\n' "$alive" | grep -qx "$pid" || continue
    else kill -0 "$pid" 2>/dev/null || continue; fi
    printf '%s\n' "$(sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")"
  done
}

local_path() { local key="${1%%/*}" rest="${1#*/}"; printf '%s/%s%s/%s' "$LOCAL_ROOT" "$PREFIX" "${key#HOME}" "$rest"; }
copy() { mkdir -p "$(dirname "$2")" && cp -p "$1" "$2"; }
STAMP="$(date +%Y-%m-%d_%H%M)"

# Сколько байт чата было одинаковым здесь и в репозитории при последней синхронизации.
# Если в репозитории чат стал длиннее этого числа — его дописали на другом компьютере (Т12).
known_size() { cat "$STATE_DIR/known/$1" 2>/dev/null || echo 0; }
set_known() { mkdir -p "$STATE_DIR/known" && printf '%s\n' "$2" > "$STATE_DIR/known/$1"; }
chat_sid() { case "$1" in *.jsonl) local b="${1##*/}"; printf '%s' "${b%.jsonl}" ;; esac; }

# Перед тем как заменить чат более длинной версией, проверяем, что старая — её начало.
# Если нет (чат дописывали на двух компьютерах одновременно), старую сохраняем в conflicts/ (Т7).
keep_if_diverged() {
  local old="$1" new="$2" p="$3" n
  [ -f "$old" ] && [ -f "$new" ] || return 0
  n="$(wc -c < "$old")"
  cmp -s -n "$n" "$old" "$new" && return 0
  copy "$old" "$DATA/conflicts/$STAMP/projects/$p"
  CONFLICTS=$((CONFLICTS + 1))
}

PULLED_CHATS=0
PULLED_MEMORY=0
PULLED_FILES=0
CONFLICTS=0

reconcile() {
  local action p l r s
  while read -r action p; do
    [ -n "$p" ] || continue
    l="$(local_path "$p")"
    r="$REPO_ROOT/$p"
    case "$action" in
      L2R)
        keep_if_diverged "$r" "$l" "$p"
        copy "$l" "$r"
        s="$(chat_sid "$p")"; [ -n "$s" ] && set_known "$s" "$(wc -c < "$l")" ;;
      R2L)
        keep_if_diverged "$l" "$r" "$p"
        copy "$r" "$l"
        case "$p" in
          */memory/*) PULLED_MEMORY=$((PULLED_MEMORY + 1)) ;;
          *.jsonl) PULLED_CHATS=$((PULLED_CHATS + 1)); s="$(chat_sid "$p")"; [ -n "$s" ] && set_known "$s" "$(wc -c < "$l")" ;;
        esac ;;
      RML) rm -f "$l" ;;
      RMR) rm -f "$r" ;;
      MERGE)
        awk 'NR==FNR { seen[$0]=1; print; next } !($0 in seen) { print }' "$r" "$l" > "$l.ccsync" \
          && mv "$l.ccsync" "$l" && cp -p "$l" "$r"
        PULLED_MEMORY=$((PULLED_MEMORY + 1)) ;;
      CONFLICT)
        copy "$r" "$DATA/conflicts/$STAMP/projects/$p"
        copy "$l" "$r"
        CONFLICTS=$((CONFLICTS + 1)) ;;
    esac
  done <<EOF
$(plan)
EOF
  # Запоминаем память в том виде, в каком она сейчас совпадает с обеих сторон.
  local dirs=() d
  for d in "$LOCAL_ROOT/$PREFIX" "$LOCAL_ROOT/$PREFIX"-*; do
    [ -d "$d/memory" ] && dirs+=("./${d##*/}")
  done
  if [ "${#dirs[@]}" -gt 0 ]; then
    (cd "$LOCAL_ROOT" && find "${dirs[@]}" -type f -path '*/memory/*' -exec cksum {} +) \
      | awk -v p="$PREFIX" '{ c=$1; sub(/^[0-9]+ [0-9]+ \.\//, ""); sub("^" p, "HOME"); print c, $0 }' > "$STATE_DIR/memory-state"
  else
    : > "$STATE_DIR/memory-state"
  fi
}

# --- старые папки → новые (structure/aliases.tsv) ------------------------------

# Строки «старый путь<TAB>новый путь» относительно домашней папки; «-» вместо нового пути — папку не переносить.
# Чаты старой папки копируются в новую (оригиналы остаются), чтобы открываться в правильном проекте/workspace.
apply_aliases() {
  local f="$DATA/structure/aliases.tsv" src dst sk dk
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r src dst; do
    src="${src%$'\r'}"; dst="${dst%$'\r'}"
    case "$src" in ''|'#'*) continue ;; esac
    [ -n "$dst" ] && [ "$dst" != - ] || continue
    sk="HOME-$(encode "$src")"; dk="HOME-$(encode "$dst")"
    # На Windows папки, которые отличаются только регистром, — одна и та же папка.
    [ "$(printf '%s' "$sk" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$dk" | tr 'A-Z' 'a-z')" ] && continue
    [ -d "$REPO_ROOT/$sk" ] || continue
    (cd "$REPO_ROOT/$sk" && find . -type f -not -path './memory/*' | sed 's#^\./##') | while read -r p; do
      if [ ! -f "$REPO_ROOT/$dk/$p" ] || [ "$(wc -c < "$REPO_ROOT/$sk/$p")" -gt "$(wc -c < "$REPO_ROOT/$dk/$p")" ]; then
        copy "$REPO_ROOT/$sk/$p" "$REPO_ROOT/$dk/$p"
      fi
    done
  done < "$f"
}

# --- правила и файлы проектов: трёхсторонняя сверка, как у памяти ---------------

# sync3 <имя> <локальная папка> <папка в репозитории> <функция-список> <функция-фильтр>
#   список печатает пути локальных файлов относительно локальной папки;
#   фильтр оставляет из путей репозитория только те, что относятся к этому компьютеру.
# При самой первой сверке (ещё нет состояния) у файла, разного здесь и в репозитории, побеждает
# репозиторий — там структура рабочего компьютера (Т4), — а местная версия сохраняется в conflicts/ (Т7).
sync3() {
  local name="$1" lroot="$2" rroot="$3" list="$4" scope="$5" state="$STATE_DIR/$1-state" first=0 action p l r
  [ -f "$state" ] || first=1
  mkdir -p "$rroot"
  while read -r action p; do
    [ -n "$p" ] || continue
    l="$lroot/$p"; r="$rroot/$p"
    case "$action" in
      L2R) copy "$l" "$r" ;;
      R2L) copy "$r" "$l"; PULLED_FILES=$((PULLED_FILES + 1)) ;;
      RML) rm -f "$l" ;;
      RMR) rm -f "$r" ;;
      MERGE)
        awk 'NR==FNR { seen[$0]=1; print; next } !($0 in seen) { print }' "$r" "$l" > "$l.ccsync" \
          && mv "$l.ccsync" "$l" && cp -p "$l" "$r"
        PULLED_FILES=$((PULLED_FILES + 1)) ;;
      CONFLICT)
        copy "$r" "$DATA/conflicts/$STAMP/$name/$p"
        copy "$l" "$r"
        CONFLICTS=$((CONFLICTS + 1)) ;;
      FIRST)
        copy "$l" "$DATA/conflicts/$STAMP/$name-local/$p"
        copy "$r" "$l"
        PULLED_FILES=$((PULLED_FILES + 1)); CONFLICTS=$((CONFLICTS + 1)) ;;
    esac
  done <<EOF
$( {
    (cd "$lroot" && "$list" | tr '\n' '\0' | xargs -0 -r cksum) | awk '{ c=$1; sub(/^[0-9]+ [0-9]+ /, ""); print "LC", c, $0 }'
    (cd "$rroot" && find . -type f | sed 's#^\./##' | "$scope" | tr '\n' '\0' | xargs -0 -r cksum) | awk '{ c=$1; sub(/^[0-9]+ [0-9]+ /, ""); print "RC", c, $0 }'
    [ -f "$state" ] && awk '{ c=$1; sub(/^[0-9]+ /, ""); print "B", c, $0 }' "$state"
  } | awk -v first="$first" '
    { tag=$1; val=$2; sub(/^[A-Z]+ [0-9]+ /, ""); p=$0; all[p]=1
      if (tag=="LC") LC[p]=val; else if (tag=="RC") RC[p]=val; else if (tag=="B") B[p]=val }
    END {
      for (p in all) {
        l=(p in LC)?LC[p]:""; r=(p in RC)?RC[p]:""; b=(p in B)?B[p]:""
        if (l!="" && r!="") {
          if (l==r) continue
          if (first) print "FIRST", p
          else if (l==b) print "R2L", p
          else if (r==b) print "L2R", p
          else if (p ~ /MEMORY\.md$/) print "MERGE", p
          else print "CONFLICT", p
        } else if (l!="") { if (b!="" && l==b) print "RML", p; else print "L2R", p }
        else if (r!="") { if (b!="" && r==b) print "RMR", p; else print "R2L", p }
      }
    }' )
EOF
  (cd "$lroot" && "$list" | tr '\n' '\0' | xargs -0 -r cksum) | awk '{ c=$1; sub(/^[0-9]+ [0-9]+ /, ""); print c, $0 }' > "$state"
}

# Общие правила (Т10). Скиллы организации (skills/synced) Claude синхронизирует сам — их не трогаем.
list_global() {
  [ -f CLAUDE.md ] && echo CLAUDE.md
  find rules commands agents -type f 2>/dev/null
  find skills -type f -not -path 'skills/synced/*' 2>/dev/null
  return 0
}
scope_global() { grep -v '^skills/synced/' || true; }

# Файлы проектов и workspaces Orca. Список их папок пишет ccsync-orca.ps1 в $STATE_DIR/units.
# Секреты, *.local.*, устаревшие .claude-memory и файлы больше 5 МБ не переносим.
skip_files() {
  grep -Eiv '(^|/)\.git/|(^|/)\.claude-memory/|\.local\.|(^|/)settings\.local\.json$|\.(pem|key|p12|pfx)$|-key\.|(^|/)\.env|token|secret|(^|/)node_modules/' || true
}
list_files() {
  [ -f "$STATE_DIR/units" ] || return 0
  local u
  while read -r u; do
    u="${u%$'\r'}"
    [ -n "$u" ] && [ -d "$u" ] || continue
    { git -C "$u" ls-files -co --exclude-standard 2>/dev/null
      (cd "$u" && find CLAUDE.md .claude -type f 2>/dev/null)
    } | sort -u | sed "s#^#$u/#"
  done < "$STATE_DIR/units" | skip_files | tr '\n' '\0' | xargs -0 -r wc -c \
    | awk -v max="$MAX_FILE" '{ n=$1; sub(/^ *[0-9]+ /, ""); if ($0 != "total" && n+0 <= max) print }'
}
# Файлы папок, которых здесь ещё нет, не скачиваем: сначала папку создаст ccsync-orca.ps1 (Т5).
scope_files() {
  [ -f "$STATE_DIR/units" ] || { cat >/dev/null; return 0; }
  awk 'NR==FNR { u=$0; sub(/\r$/, "", u); if (u!="") units[u]=1; next }
       { for (u in units) if (index($0, u "/")==1) { print; next } }' "$STATE_DIR/units" - | skip_files
}

# --- git ---------------------------------------------------------------------

COMMIT_OK=1
commit_all() {
  git -C "$DATA" add -A >/dev/null 2>&1 || { COMMIT_OK=0; return; }
  git -C "$DATA" diff --cached --quiet || git -C "$DATA" commit -qm "sync: $MACHINE $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1 || COMMIT_OK=0
}

PULL_OK=1
pull() {
  # -X theirs при rebase оставляет нашу версию, если один и тот же файл правили на двух компьютерах.
  if ! git -C "$DATA" pull -q --rebase --autostash -X theirs >/dev/null 2>&1; then
    git -C "$DATA" rebase --abort >/dev/null 2>&1
    PULL_OK=0
  fi
}

push() { git -C "$DATA" push -q >/dev/null 2>&1 || PULL_OK=0; }

# Сначала забираем чужое, потом сверяем с локальным: так правка одного и того же файла
# на двух компьютерах попадает в сверку как конфликт, а не теряется при rebase.
sync_all() {
  pull
  orca_helper snapshot >/dev/null
  apply_aliases
  reconcile
  sync3 global "$CLAUDE_DIR" "$DATA/global" list_global scope_global
  sync3 files "$HOME_DIR" "$DATA/files" list_files scope_files
  commit_all
  if [ "$PULL_OK" = 1 ] && ! git -C "$DATA" push -q >/dev/null 2>&1; then
    # Кто-то успел отправить своё между нашими pull и push.
    pull
    push
  fi
  date +%s > "$STATE_DIR/last-sync"
}

# --- Т12: текущий чат дописан на другом компьютере ------------------------------

# Путь файла текущего чата в репозитории (projects/HOME-…/<id>.jsonl) или пусто.
repo_chat_path() {
  [ -n "$TRANSCRIPT" ] || return 0
  local rel="${TRANSCRIPT#"$LOCAL_ROOT"/}" dir
  [ "$rel" != "$TRANSCRIPT" ] || return 0
  dir="${rel%%/*}"
  case "$dir" in "$PREFIX"|"$PREFIX"-*) ;; *) return 0 ;; esac
  printf 'projects/HOME%s/%s' "${dir#"$PREFIX"}" "${rel#*/}"
}

# Есть ли в репозитории (ref) версия текущего чата длиннее той, что мы видели, и с тем же началом.
stale() {
  local ref="$1" rp rs known
  [ -n "$SID" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 1
  rp="$(repo_chat_path)"; [ -n "$rp" ] || return 1
  rs="$(git -C "$DATA" cat-file -s "$ref:$rp" 2>/dev/null)" || return 1
  known="$(known_size "$SID")"
  [ "$known" -gt 0 ] || known="$(wc -c < "$TRANSCRIPT")"
  [ "$rs" -gt "$known" ] || return 1
  git -C "$DATA" cat-file blob "$ref:$rp" | head -c "$known" | cmp -s - <(head -c "$known" "$TRANSCRIPT")
}

# Не переоткрывать один и тот же чат по кругу.
recently_reopened() {
  local t
  t="$(cat "$STATE_DIR/reopened/$SID" 2>/dev/null || echo 0)"
  [ $(( $(date +%s) - t )) -lt 120 ]
}

# Свежая версия сразу сохраняется в $STATE_DIR/pending/<id>.jsonl; пока она там, этот чат не синхронизируется:
# Claude успевает дописать в старую версию заблокированное сообщение, и она не должна затереть свежую.
# В Orca: отдельный процесс закрывает эту вкладку, подставляет свежую версию и открывает чат заново.
# Не в Orca: свежая версия подставится при закрытии сессии (SessionEnd), чат нужно открыть заново самой.
reopen() {
  local ref="$1" req pending="$STATE_DIR/pending/$SID.jsonl"
  mkdir -p "$STATE_DIR/reopened" "$STATE_DIR/pending" && date +%s > "$STATE_DIR/reopened/$SID"
  git -C "$DATA" cat-file blob "$ref:$(repo_chat_path)" > "$pending.tmp" && mv "$pending.tmp" "$pending" || { rm -f "$pending.tmp"; return 1; }
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && [ "${CCSYNC_NO_ORCA:-0}" != 1 ] && command -v powershell.exe >/dev/null 2>&1; then
    req="$STATE_DIR/reopen-$SID.txt"
    {
      printf 'sid=%s\n' "$SID"
      printf 'transcript=%s\n' "$(winpath "$TRANSCRIPT")"
      printf 'pending=%s\n' "$(winpath "$pending")"
      printf 'terminal=%s\n' "$ORCA_TERMINAL_HANDLE"
      printf 'worktree=%s\n' "${ORCA_WORKTREE_ID#*::}"
    } > "$req"
    powershell.exe -NoProfile -NonInteractive -Command \
      "Start-Process -WindowStyle Hidden -FilePath powershell.exe -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$(winpath "$SCRIPT_DIR/ccsync-orca.ps1")\" -Mode reopen -Data \"$(winpath "$DATA")\" -State \"$(winpath "$STATE_DIR")\" -HomeDir \"$(winpath "$HOME_DIR")\" -ClaudeProjects \"$(winpath "$LOCAL_ROOT")\" -Machine $MACHINE -Request \"$(winpath "$req")\"'" >/dev/null 2>&1
    return 0
  fi
  return 2
}

# Подставить сохранённую свежую версию чата (вызывается, когда сессия уже закрывается).
apply_pending() {
  local pending="$STATE_DIR/pending/$SID.jsonl"
  [ -n "$SID" ] && [ -f "$pending" ] && [ -n "$TRANSCRIPT" ] || return 0
  mv "$pending" "$TRANSCRIPT" && set_known "$SID" "$(wc -c < "$TRANSCRIPT")"
}

# --- команды -------------------------------------------------------------------

setup() {
  local url="${1:-}"
  [ -n "$url" ] || { say "нужна ссылка на репозиторий: ccsync.sh setup <url>"; exit 1; }
  if [ -d "$DATA/.git" ]; then
    git -C "$DATA" remote remove origin 2>/dev/null
    git -C "$DATA" remote add origin "$url"
    git -C "$DATA" fetch -q origin || { say "нет доступа к $url"; exit 1; }
    # Переезд на другой репозиторий: пустой получает всю историю, непустой становится основным.
    if git -C "$DATA" rev-parse -q --verify origin/main >/dev/null; then
      git -C "$DATA" branch -q -u origin/main main
    elif git -C "$DATA" rev-parse -q --verify HEAD >/dev/null; then
      git -C "$DATA" push -q -u origin main || { say "не удалось отправить данные в $url"; exit 1; }
    fi
  else
    git -c core.longpaths=true clone -q "$url" "$DATA" 2>/dev/null || { say "не удалось скачать $url — проверь ссылку и доступ"; exit 1; }
  fi
  git -C "$DATA" config core.autocrlf false
  git -C "$DATA" config core.longpaths true
  git -C "$DATA" config core.quotepath false
  git -C "$DATA" config user.name >/dev/null || git -C "$DATA" config user.name "$MACHINE"
  git -C "$DATA" config user.email >/dev/null || git -C "$DATA" config user.email "ccsync@$MACHINE"
  if ! git -C "$DATA" rev-parse -q --verify HEAD >/dev/null; then
    # Пустой репозиторий: создаём первый коммит.
    git -C "$DATA" checkout -q -b main 2>/dev/null
    printf '* -text\n**/memory/MEMORY.md merge=union\n' > "$DATA/.gitattributes"
    printf '# Данные Claude Code\n\nЧаты и память, которые синхронизирует плагин ccsync. Руками не править.\n' > "$DATA/README.md"
    git -C "$DATA" add -A
    git -C "$DATA" commit -qm "ccsync: init"
    git -C "$DATA" push -q -u origin main || { say "не удалось отправить первый коммит в $url"; exit 1; }
  fi
  lock 30 || { say "идёт другая синхронизация, попробуй через минуту"; exit 1; }
  sync_all
  if [ "$COMMIT_OK" = 1 ] && [ "$PULL_OK" = 1 ]; then
    say "готово. Репозиторий: $url, папка: $DATA"
  fi
  report
  unlock
  orca_helper apply
}

report() {
  [ "$PULLED_CHATS" -gt 0 ] && say "с другого компьютера пришло чатов: $PULLED_CHATS"
  [ "$PULLED_MEMORY" -gt 0 ] && say "обновлено файлов памяти: $PULLED_MEMORY"
  [ "$PULLED_FILES" -gt 0 ] && say "обновлено правил и файлов проектов: $PULLED_FILES"
  [ "$CONFLICTS" -gt 0 ] && say "файлов, изменённых на двух компьютерах сразу: $CONFLICTS (вторая версия сохранена в $DATA/conflicts)"
  [ "$COMMIT_OK" = 1 ] || say "не удалось сохранить изменения в $DATA — запусти /ccsync:status и покажи результат тому, кто настраивал"
  [ "$PULL_OK" = 1 ] || say "не удалось связаться с репозиторием (нет интернета или доступа) — синхронизирую в следующий раз"
  return 0
}

status() {
  if ! configured; then say "не настроен. Запусти /ccsync:setup <ссылка на приватный репозиторий>"; return; fi
  say "репозиторий: $(git -C "$DATA" remote get-url origin)"
  say "локальная копия: $DATA"
  if [ -f "$STATE_DIR/last-sync" ]; then
    local t; t="$(cat "$STATE_DIR/last-sync")"
    say "последняя синхронизация: $(( ($(date +%s) - t) / 60 )) мин назад"
  fi
  say "проектов в репозитории: $(ls "$REPO_ROOT" 2>/dev/null | wc -l | tr -d ' '), чатов: $(find "$REPO_ROOT" -name '*.jsonl' -not -path '*/subagents/*' 2>/dev/null | wc -l | tr -d ' ')"
  say "отправка: $([ "$INTERVAL" -gt 0 ] && echo "не чаще раза в $INTERVAL с" || echo "после каждого ответа")"
  [ -d "$DATA/conflicts" ] && say "есть сохранённые конфликты: $DATA/conflicts"
  orca_helper status
  return 0
}

case "$MODE" in
  setup) setup "${2:-}" ;;
  status) status ;;
  start)
    if ! configured; then
      say "синхронизация чатов не настроена. Чтобы включить, запусти /ccsync:setup"
      exit 0
    fi
    lock 20 || exit 0
    sync_all
    unlock
    report
    if stale HEAD && ! recently_reopened; then
      reopen HEAD
      case $? in
        0) say "этот чат дописан на другом компьютере — переоткрываю его в свежей версии" ;;
        2) say "этот чат дописан на другом компьютере. Закрой его (/exit) и открой заново: claude --resume $SID" ;;
      esac
    fi
    detach tabs ;;
  prompt)
    configured || exit 0
    timeout 10 git -C "$DATA" fetch -q origin >/dev/null 2>&1
    if stale origin/main && ! recently_reopened; then
      reopen origin/main
      case $? in
        0) msg="Этот чат дописан на другом компьютере. Открываю его свежую версию в новой вкладке — повтори там своё сообщение." ;;
        2) msg="Этот чат дописан на другом компьютере. Закрой его (/exit), открой заново (claude --resume $SID) и повтори сообщение." ;;
        *) msg="" ;;
      esac
      if [ -n "$msg" ]; then
        printf '{"decision":"block","reason":"%s"}\n' "$msg"
        exit 0
      fi
    fi
    detach bg ;;
  bg)
    configured || exit 0
    lock 1 || exit 0
    sync_all
    unlock
    orca_helper apply >/dev/null ;;
  tabs)
    configured || exit 0
    orca_helper apply ;;
  stop)
    configured || exit 0
    last="$(cat "$STATE_DIR/last-sync" 2>/dev/null || echo 0)"
    [ $(($(date +%s) - last)) -lt "$INTERVAL" ] && exit 0
    lock 5 || exit 0
    sync_all ;;
  end)
    configured || exit 0
    lock 10 || exit 0
    apply_pending
    sync_all ;;
  now)
    configured || { status; exit 0; }
    lock 30 || { say "идёт другая синхронизация, попробуй через минуту"; exit 0; }
    sync_all
    unlock
    say "синхронизировано"
    report
    orca_helper apply ;;
  *) say "неизвестная команда: $MODE"; exit 1 ;;
esac
exit 0
