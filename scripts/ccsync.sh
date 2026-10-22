#!/usr/bin/env bash
# ccsync — синхронизация чатов и памяти Claude Code между компьютерами через приватный git-репозиторий.
#
#   ccsync.sh start            SessionStart: подтянуть изменения с другого компьютера
#   ccsync.sh stop             Stop: отправить свои изменения (не чаще раза в CCSYNC_INTERVAL секунд)
#   ccsync.sh end              SessionEnd: отправить свои изменения сразу
#   ccsync.sh now              ручная полная синхронизация
#   ccsync.sh setup <url>      подключить репозиторий с данными (один раз на каждом компьютере)
#   ccsync.sh status           что настроено и когда была последняя синхронизация
#
# Что синхронизируется: всё из ~/.claude/projects/<папка проекта>/ — чаты (*.jsonl),
# вложения чатов (<id>/subagents, <id>/tool-results) и память (memory/*.md).
# Папки проектов сопоставляются по пути относительно домашней папки, поэтому
# C:\Users\anna\orca\projects\x и /Users/anna.k/orca/projects/x считаются одним проектом.

set -u

MODE="${1:-now}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOCAL_ROOT="$CLAUDE_DIR/projects"
DATA="${CCSYNC_DIR:-$HOME/.claude-sync-data}"
REPO_ROOT="$DATA/projects"
STATE_DIR="${CCSYNC_STATE_DIR:-$HOME/.claude-sync-state}"
INTERVAL="${CCSYNC_INTERVAL:-600}"
MACHINE="$(hostname 2>/dev/null || echo unknown)"

mkdir -p "$STATE_DIR"

# Путь к плагину запоминаем, чтобы слэш-команды могли найти этот скрипт.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  printf '%s\n' "$CLAUDE_PLUGIN_ROOT" > "$STATE_DIR/plugin-root"
fi

# Хуки получают JSON на stdin; из него нужен id текущего чата.
SID=""
if [ "$MODE" = start ] || [ "$MODE" = stop ] || [ "$MODE" = end ]; then
  INPUT="$(cat)"
  SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi

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

# --- сверка локальной папки и репозитория ------------------------------------

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
plan() {
  scan | awk -v sid="$SID" '
    { tag=$1; val=$2; sub(/^[A-Z]+ [0-9]+ /, ""); p=$0; all[p]=1
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
          if (!(p in R) || (p in L && L[p]+0 > R[p]+0)) print "L2R", p
          else if (!current && (!(p in L) || R[p]+0 > L[p]+0)) print "R2L", p
        }
      }
    }'
}

local_path() { local key="${1%%/*}" rest="${1#*/}"; printf '%s/%s%s/%s' "$LOCAL_ROOT" "$PREFIX" "${key#HOME}" "$rest"; }
copy() { mkdir -p "$(dirname "$2")" && cp -p "$1" "$2"; }

PULLED_CHATS=0
PULLED_MEMORY=0
CONFLICTS=0

reconcile() {
  local action p l r stamp
  stamp="$(date +%Y-%m-%d_%H%M)"
  while read -r action p; do
    [ -n "$p" ] || continue
    l="$(local_path "$p")"
    r="$REPO_ROOT/$p"
    case "$action" in
      L2R) copy "$l" "$r" ;;
      R2L)
        copy "$r" "$l"
        case "$p" in
          */memory/*) PULLED_MEMORY=$((PULLED_MEMORY + 1)) ;;
          *.jsonl) PULLED_CHATS=$((PULLED_CHATS + 1)) ;;
        esac ;;
      RML) rm -f "$l" ;;
      RMR) rm -f "$r" ;;
      MERGE)
        awk 'NR==FNR { seen[$0]=1; print; next } !($0 in seen) { print }' "$r" "$l" > "$l.ccsync" \
          && mv "$l.ccsync" "$l" && cp -p "$l" "$r"
        PULLED_MEMORY=$((PULLED_MEMORY + 1)) ;;
      CONFLICT)
        copy "$r" "$DATA/conflicts/$stamp/$p"
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
# на двух компьютерах попадает в reconcile как конфликт, а не теряется при rebase.
sync_all() {
  pull
  reconcile
  commit_all
  if [ "$PULL_OK" = 1 ] && ! git -C "$DATA" push -q >/dev/null 2>&1; then
    # Кто-то успел отправить своё между нашими pull и push.
    pull
    push
  fi
  date +%s > "$STATE_DIR/last-sync"
}

# --- файлы самого проекта (необязательно) --------------------------------------

# При CCSYNC_PROJECT_GIT=1 папка проекта, если это git-репозиторий с origin, тоже синхронизируется:
# на старте подтягивается, в конце коммитится и пушится в основную ветку.
project_sync() {
  [ "${CCSYNC_PROJECT_GIT:-0}" = 1 ] || return 0
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}" main
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 0
  main="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  main="${main#origin/}"
  [ -n "$main" ] || main=main
  if [ "$1" = push ]; then
    git -C "$dir" add -A
    git -C "$dir" diff --cached --quiet || git -C "$dir" commit -qm "auto: $MACHINE $(date '+%Y-%m-%d %H:%M')"
  fi
  git -C "$dir" fetch -q origin 2>/dev/null || return 0
  if ! git -C "$dir" rebase -q --autostash "origin/$main" >/dev/null 2>&1; then
    git -C "$dir" rebase --abort >/dev/null 2>&1
    say "файлы проекта не синхронизированы: один и тот же файл изменён на двух компьютерах."
    return 0
  fi
  [ "$1" = push ] && git -C "$dir" push -q origin "HEAD:$main" >/dev/null 2>&1
  return 0
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
}

report() {
  [ "$PULLED_CHATS" -gt 0 ] && say "с другого компьютера пришло чатов: $PULLED_CHATS"
  [ "$PULLED_MEMORY" -gt 0 ] && say "обновлено файлов памяти: $PULLED_MEMORY"
  [ "$CONFLICTS" -gt 0 ] && say "файлов памяти, изменённых на двух компьютерах сразу: $CONFLICTS (оставлена версия этого компьютера, вторая лежит в $DATA/conflicts)"
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
  [ -d "$DATA/conflicts" ] && say "есть сохранённые конфликты: $DATA/conflicts"
  return 0
}

case "$MODE" in
  setup) setup "${2:-}" ;;
  status) status ;;
  start)
    project_sync pull
    if ! configured; then
      say "синхронизация чатов не настроена. Чтобы включить, запусти /ccsync:setup"
      exit 0
    fi
    lock 20 || exit 0
    sync_all
    report ;;
  stop)
    configured || exit 0
    last="$(cat "$STATE_DIR/last-sync" 2>/dev/null || echo 0)"
    [ $(($(date +%s) - last)) -lt "$INTERVAL" ] && exit 0
    lock 1 || exit 0
    sync_all ;;
  end)
    project_sync push
    configured || exit 0
    lock 10 || exit 0
    sync_all ;;
  now)
    project_sync push
    configured || { status; exit 0; }
    lock 30 || { say "идёт другая синхронизация, попробуй через минуту"; exit 0; }
    sync_all
    say "синхронизировано"
    report ;;
  *) say "неизвестная команда: $MODE"; exit 1 ;;
esac
exit 0
