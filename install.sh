#!/usr/bin/env bash
#
# Установка стека «Claude в OpenCode по подписке» на macOS-хост.
#
#   OpenCode → ai-gateway (:8130) → kraube serve (:8787) → Anthropic OAuth
#
# Идемпотентно: существующие конфиги и LaunchAgents не перезаписываются
# (без --force — тогда с бэкапом). Токены генерируются openssl rand.
# Один интерактивный шаг: `kraube login` (браузер).
#
# Usage:
#   ./install.sh                 # полная установка
#   ./install.sh --check         # только проверка зависимостей
#   ./install.sh --skip-kraube   # шлюз и конфиги; kraube уже установлен
#   ./install.sh --force         # перезаписывать существующее (с бэкапом)
#
set -euo pipefail

GATEWAY_REPO="https://github.com/Mobiss11/ai-gateway.git"
KRAUBE_REPO="https://github.com/scott-walker/kraube-api.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/ai-gateway}"
KRAUBE_SRC_DIR="${KRAUBE_SRC_DIR:-$HOME/src/kraube-api}"
KRAUBE_BIN="$HOME/.local/bin/kraube"
CONF_DIR="$HOME/.config/ai-gateway"
KRAUBE_CONF_DIR="$HOME/.config/kraube"
SOLUTION_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

FORCE=0
SKIP_KRAUBE=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --skip-kraube) SKIP_KRAUBE=1 ;;
    --check) CHECK_ONLY=1 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '     \033[1;32mok\033[0m %s\n' "$*"; }
warn()  { printf '     \033[1;33m!!\033[0m %s\n' "$*"; }

need() {  # need <cmd> <зачем>
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ОШИБКА: не найден '$1' ($2). Установите и повторите." >&2
    exit 1
  fi
}

random_token() { openssl rand -hex 24; }

backup_if_exists() {  # backup_if_exists <файл>
  local f="$1"
  [[ -e "$f" ]] || return 0
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  cp "$f" "$f.bak-$ts"
  warn "существующий файл забэкаплен: $f.bak-$ts"
}

write_unless_exists() {  # write_unless_exists <файл> <источник>
  local dst="$1" src="$2"
  if [[ -e "$dst" && $FORCE -eq 0 ]]; then
    ok "уже есть, не трогаю: $dst (перезапись — --force)"
    return 0
  fi
  [[ $FORCE -eq 1 ]] && backup_if_exists "$dst"
  cp "$src" "$dst"
}

# ------------------------------------------------------------------ #
# 0. Preflight
# ------------------------------------------------------------------ #
info "Preflight"
[[ "$(uname -s)" == "Darwin" ]] || { echo "ОШИБКА: только macOS (launchd)." >&2; exit 1; }
need git "клонирование ai-gateway"
need uv "окружение шлюза (https://docs.astral.sh/uv/)"
need launchctl "управление LaunchAgents"
need openssl "генерация токенов"
need curl "проверка healthz"
if [[ $SKIP_KRAUBE -eq 0 && ! -x "$KRAUBE_BIN" ]]; then
  need go "сборка kraube из исходников (или --skip-kraube, если бинарь уже есть)"
fi
ok "зависимости на месте"

if [[ $CHECK_ONLY -eq 1 ]]; then
  info "--check: готово к установке в $INSTALL_DIR"
  exit 0
fi

# ------------------------------------------------------------------ #
# 1. ai-gateway: код и окружение
# ------------------------------------------------------------------ #
info "ai-gateway → $INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
  ok "обновлён (git pull)"
else
  git clone "$GATEWAY_REPO" "$INSTALL_DIR"
  ok "склонирован"
fi
(cd "$INSTALL_DIR" && uv sync --extra dev)

# ------------------------------------------------------------------ #
# 2. Конфиги шлюза: токены генерируем, не перезаписываем
# ------------------------------------------------------------------ #
info "Конфиги → $CONF_DIR"
mkdir -p "$CONF_DIR"
write_unless_exists "$CONF_DIR/config.json" "$SOLUTION_DIR/config/gateway.config.example.json"
if [[ ! -f "$CONF_DIR/env" || $FORCE -eq 1 ]]; then
  [[ -f "$CONF_DIR/env" ]] && backup_if_exists "$CONF_DIR/env"
  GW_TOKEN=$(random_token)
  KRAUBE_KEY=$(random_token)
  umask 177
  cat > "$CONF_DIR/env" <<EOF
AI_GATEWAY_TOKEN=$GW_TOKEN
KRAUBE_SERVE_KEY=$KRAUBE_KEY
EOF
  umask 022
  ok "env создан (0600), токены сгенерированы"
else
  ok "env уже есть, не трогаю"
  KRAUBE_KEY=$(sed -n 's/^KRAUBE_SERVE_KEY=//p' "$CONF_DIR/env" | head -1)
fi
info "Токен шлюза для клиентов: см. $CONF_DIR/env → AI_GATEWAY_TOKEN"

# ------------------------------------------------------------------ #
# 3. kraube: бинарь, ключ, логин
# ------------------------------------------------------------------ #
if [[ $SKIP_KRAUBE -eq 1 ]]; then
  info "kraube: пропущен (--skip-kraube)"
else
  info "kraube → $KRAUBE_BIN"
  if [[ ! -x "$KRAUBE_BIN" ]]; then
    if [[ ! -d "$KRAUBE_SRC_DIR/.git" ]]; then
      git clone "$KRAUBE_REPO" "$KRAUBE_SRC_DIR"
    fi
    # патч версии Claude Code в заголовках биллинга (если ещё не применён)
    if [[ -f "$INSTALL_DIR/deploy/kraube-cc-version-2.1.300.patch" ]]; then
      (cd "$KRAUBE_SRC_DIR" \
        && patch -p1 --forward < "$INSTALL_DIR/deploy/kraube-cc-version-2.1.300.patch") \
        || warn "патч cc-version не применился (версия ушла вперёд?) — проверьте заголовки"
    fi
    (cd "$KRAUBE_SRC_DIR" && go build -o "$KRAUBE_BIN" ./cmd/kraube)
    ok "собран и установлен"
  else
    ok "бинарь уже стоит: $KRAUBE_BIN"
  fi

  mkdir -p "$KRAUBE_CONF_DIR"
  if [[ ! -f "$KRAUBE_CONF_DIR/env" ]]; then
    umask 177
    printf 'KRAUBE_SERVE_KEY=%s\n' "$KRAUBE_KEY" > "$KRAUBE_CONF_DIR/env"
    umask 022
    ok "ключ serve записан: $KRAUBE_CONF_DIR/env (0600)"
  else
    ok "ключ serve уже есть: $KRAUBE_CONF_DIR/env"
  fi

  if [[ ! -f "$KRAUBE_CONF_DIR/credentials.json" ]]; then
    echo
    echo "     Требуется интерактивный логин. Выполните:"
    echo "         $KRAUBE_BIN login"
    echo "     ( kraube напечатает URL — откройте в браузере, вставьте код обратно )"
    echo "     Затем запустите ./install.sh ещё раз."
    echo
    exit 1
  fi
  ok "credentials на месте"
fi

# ------------------------------------------------------------------ #
# 4. LaunchAgents: шаблоны из репозитория ai-gateway, пути под $HOME
# ------------------------------------------------------------------ #
info "LaunchAgents → $LAUNCH_AGENTS"
mkdir -p "$LAUNCH_AGENTS" "$INSTALL_DIR/logs" "$HOME/Library/Logs"

install_agent() {  # install_agent <шаблон.example> <итоговый .plist>
  local tpl="$1" dst="$LAUNCH_AGENTS/$2"
  if [[ -e "$dst" && $FORCE -eq 0 ]]; then
    ok "уже есть: $dst"
    return 0
  fi
  [[ $FORCE -eq 1 ]] && launchctl bootout "gui/$(id -u)/${2%.plist}" 2>/dev/null || true
  # шаблоны содержат /Users/youruser (или legacy /Users/alluc) — подставляем $HOME
  sed -e "s|/Users/youruser|$HOME|g" -e "s|/Users/alluc|$HOME|g" "$tpl" > "$dst"
  ok "установлен: $dst"
}

install_agent "$INSTALL_DIR/deploy/com.alluc.kraube-serve.plist.example" com.alluc.kraube-serve.plist
install_agent "$INSTALL_DIR/deploy/com.alluc.ai-gateway.plist.example" com.alluc.ai-gateway.plist

launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS/com.alluc.kraube-serve.plist" 2>/dev/null \
  || launchctl kickstart -k "gui/$(id -u)/com.alluc.kraube-serve"
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS/com.alluc.ai-gateway.plist" 2>/dev/null \
  || launchctl kickstart -k "gui/$(id -u)/com.alluc.ai-gateway"

# ------------------------------------------------------------------ #
# 5. Healthz
# ------------------------------------------------------------------ #
info "Ждём healthz (до 30 c)"
for _ in $(seq 1 30); do
  if curl -sf -m 2 http://127.0.0.1:8130/healthz >/dev/null 2>&1; then
    ok "шлюз поднялся: http://127.0.0.1:8130"
    break
  fi
  sleep 1
done
curl -sf -m 2 http://127.0.0.1:8130/healthz >/dev/null 2>&1 \
  || { echo "ОШИБКА: healthz не отвечает. Логи: $INSTALL_DIR/logs/" >&2; exit 1; }

echo
info "Готово. Дальше:"
echo "   1) проверка:      ./verify.sh"
echo "   2) OpenCode:      вставьте config/opencode.provider.example.json"
echo "                     в ~/.config/opencode/opencode.json (см. README)"
echo "   3) токен клиентов: $CONF_DIR/env → AI_GATEWAY_TOKEN"
