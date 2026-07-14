#!/bin/bash
# ==============================================================================
# Script de Instalação para Arch Linux e derivados
# Compatível com: Arch Linux, Manjaro, BigLinux, EndeavourOS, Garuda, CachyOS,
#                 Arcolinux, Artix (sem systemd → pula systemctl)
#
# Ferramentas: NVM + Node.js LTS, VS Code (Microsoft), Insomnia, JetBrains
#              Toolbox (→ DataGrip), Docker CE com compose e buildx
#
# Princípios de robustez aplicados:
#   - set -Eeuo pipefail + trap ERR com linha e comando
#   - Tudo idempotente: re-executar é seguro (skip em vez de reinstalar)
#   - Diretório temporário único por execução, limpo em qualquer saída
#   - Sudo keepalive em background (uma senha só, sem timeout)
#   - Log paralelo em arquivo com timestamp
#   - Cores auto-desativadas fora de TTY
#   - Lock file para impedir execuções concorrentes
#   - Detecção de arquitetura (x86_64 / aarch64)
#   - Fallbacks em cascata para cada componente (pacman → AUR → manual)
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="install-arch.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly LOG_DIR="${HOME}/.local/share/fslab/logs"
readonly LOG_FILE="${LOG_DIR}/install-arch-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/fslab-install-arch.lock"
readonly TMP_ROOT="$(mktemp -d -t fslab-arch-XXXXXX)"

# ------------------------------------------------------------------------------
# Colors (auto-disable when not a TTY)
# ------------------------------------------------------------------------------
if [[ -t 1 && -t 2 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ------------------------------------------------------------------------------
# Logging — stdout + log file (with timestamp)
# ------------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
  local level="$1"; shift
  local msg="$*"
  printf '%s\n' "$msg" | tee -a "$LOG_FILE" >&2
}

log()   { _log INFO  "${GREEN}[✔]${NC} $*"; }
warn()  { _log WARN  "${YELLOW}[!]${NC} $*"; }
info()  { _log INFO  "${BLUE}[»]${NC} $*"; }
step()  { _log STEP  "${CYAN}[—]${NC} $*"; }
error() {
  _log ERROR "${RED}[✘]${NC} $*"
  exit 1
}

# ------------------------------------------------------------------------------
# ERR trap — shows line number and offending command
# ------------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no=$1
  local cmd="$2"
  echo "" >&2
  error "Falha na linha ${line_no} (código ${exit_code}): ${cmd}"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# Cleanup — always remove tmp dir and lock file on exit
# ------------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  # Mata o keepalive do sudo se ainda estiver rodando
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  # Remove o diretório temporário
  rm -rf "$TMP_ROOT" 2>/dev/null || true
  # Libera o lock file
  rm -f "$LOCK_FILE" 2>/dev/null || true
  if [[ $exit_code -eq 0 ]]; then
    log "Log completo salvo em: $LOG_FILE"
  else
    warn "Script falhou. Log completo em: $LOG_FILE"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Lock file — impede duas instâncias simultâneas
# ------------------------------------------------------------------------------
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      error "Outra instância deste script já está rodando (PID $pid)."
    fi
    # Lock stale — remove
    rm -f "$LOCK_FILE" 2>/dev/null || true
  fi
  echo "$$" > "$LOCK_FILE"
}

# ------------------------------------------------------------------------------
# Validations
# ------------------------------------------------------------------------------
if [[ "$EUID" -eq 0 ]]; then
  error "Não execute este script como root. Use um usuário comum com sudo."
fi

if [[ ! -f /etc/os-release ]]; then
  error "Não foi possível detectar a distribuição (/etc/os-release ausente)."
fi

# shellcheck disable=SC1091
. /etc/os-release
DISTRO="${ID:-unknown}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO}"
DISTRO_VERSION="${VERSION_ID:-}"
ARCH="$(uname -m)"

# Lista de IDs reconhecidos como base Arch
ARCH_BASED=("arch" "manjaro" "biglinux" "endeavouros" "garuda" "arcolinux" "artix" "cachyos")
IS_ARCH_BASED=false
for d in "${ARCH_BASED[@]}"; do
  if [[ "$DISTRO" == "$d" ]]; then
    IS_ARCH_BASED=true
    break
  fi
done

# Fallback: ID_LIKE
if [[ "$IS_ARCH_BASED" == false && "${ID_LIKE:-}" == *"arch"* ]]; then
  IS_ARCH_BASED=true
fi

if [[ "$IS_ARCH_BASED" == false ]]; then
  error "Distro não reconhecida como base Arch: $DISTRO_NAME
Distros suportadas: Arch, Manjaro, BigLinux, EndeavourOS, Garuda, CachyOS, Arcolinux, Artix."
fi

# Detecta Artix (sem systemd) — usa service management diferente
HAS_SYSTEMD=true
if [[ "$DISTRO" == "artix" ]] || [[ "${ID_LIKE:-}" == *"artix"* ]]; then
  HAS_SYSTEMD=false
fi

info "Distro detectada : $DISTRO_NAME"
info "Arquitetura      : $ARCH"
info "Systemd          : $HAS_SYSTEMD"
info "Versão do script : $SCRIPT_VERSION"

acquire_lock

# ------------------------------------------------------------------------------
# Sudo keepalive
# ------------------------------------------------------------------------------
info "Autenticando sudo (senha única para toda a execução)..."
sudo -v || error "Falha na autenticação sudo. Verifique sua senha e tente novamente."

(
  while true; do
    sudo -n true 2>/dev/null || exit
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done
) &
SUDO_KEEPALIVE_PID=$!

log "Sudo autenticado. Cache renovado em background."

# ------------------------------------------------------------------------------
# Internet check
# ------------------------------------------------------------------------------
info "Verificando conexão com a internet..."
if ! curl -fsSL --max-time 10 https://archlinux.org > /dev/null 2>&1; then
  # Tenta um segundo endpoint antes de desistir
  if ! curl -fsSL --max-time 10 https://www.google.com > /dev/null 2>&1; then
    error "Sem conexão com a internet. Verifique sua rede e tente novamente."
  fi
fi
log "Conexão OK."

# ==============================================================================
# HELPERS
# ==============================================================================

# Instala helper AUR (yay) — compilado via makepkg, sem root
install_yay() {
  info "Instalando helper AUR 'yay'..."

  sudo pacman -S --noconfirm --needed --overwrite '/usr/bin/*' git base-devel go

  local YAY_DIR="$TMP_ROOT/yay"
  git clone --depth=1 https://aur.archlinux.org/yay.git "$YAY_DIR"

  (cd "$YAY_DIR" && makepkg -si --noconfirm --clean --nocheck)

  if ! command -v yay &>/dev/null; then
    error "Instalação do yay falhou."
  fi
  log "yay instalado: $(yay --version | head -1)"
}

# Wrapper AUR — prioriza yay > paru > instala yay
aur_install() {
  local PKG="$1"
  info "Instalando '$PKG' via AUR..."

  if command -v yay &>/dev/null; then
    yay -S --noconfirm --needed --removemake --cleanafter --batchinstall "$PKG"
  elif command -v paru &>/dev/null; then
    paru -S --noconfirm --needed --removemake --cleanafter "$PKG"
  else
    warn "Nenhum helper AUR encontrado. Instalando yay automaticamente..."
    install_yay
    yay -S --noconfirm --needed --removemake --cleanafter --batchinstall "$PKG"
  fi
  log "'$PKG' instalado via AUR."
}

# Tenta pacman primeiro, cai para AUR
pacman_or_aur() {
  local PKG="$1"
  local AUR_PKG="${2:-$PKG}"

  if sudo pacman -Si "$PKG" &>/dev/null; then
    sudo pacman -S --noconfirm --needed "$PKG"
    log "'$PKG' instalado via pacman."
  else
    warn "'$PKG' não encontrado nos repositórios oficiais. Usando AUR ($AUR_PKG)..."
    aur_install "$AUR_PKG"
  fi
}

# Download seguro do JetBrains Toolbox (fallback manual)
install_toolbox_manual() {
  local TOOLBOX_DIR="$1"
  info "Baixando JetBrains Toolbox via download direto..."

  local TOOLBOX_URL
  TOOLBOX_URL=$(curl -fsSL \
    "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | grep -oP '"linux":\{"link":"\K[^"]+' \
    | head -1)

  if [[ -z "$TOOLBOX_URL" ]]; then
    warn "API JetBrains indisponível. Usando versão fixa..."
    TOOLBOX_URL="https://download.jetbrains.com/toolbox/jetbrains-toolbox-2.5.2.35332.tar.gz"
  fi

  local TB_TMP="$TMP_ROOT/toolbox"
  mkdir -p "$TB_TMP"
  wget -q -O "$TB_TMP/toolbox.tar.gz" "$TOOLBOX_URL"

  # Valida que o download tem tamanho razoável (>5MB)
  local FILESIZE
  FILESIZE=$(stat -c%s "$TB_TMP/toolbox.tar.gz" 2>/dev/null || echo 0)
  if (( FILESIZE < 5000000 )); then
    error "Download do Toolbox falhou ou arquivo muito pequeno (${FILESIZE} bytes)."
  fi

  tar -xzf "$TB_TMP/toolbox.tar.gz" -C "$TB_TMP/"

  local TOOLBOX_BIN
  TOOLBOX_BIN=$(find "$TB_TMP" -name "jetbrains-toolbox" -type f -print -quit 2>/dev/null)
  if [[ -z "$TOOLBOX_BIN" ]]; then
    error "Binário jetbrains-toolbox não encontrado após extração."
  fi

  mkdir -p "$TOOLBOX_DIR"
  mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/jetbrains-toolbox"
  chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"

  log "JetBrains Toolbox instalado manualmente em $TOOLBOX_DIR"
}

# ==============================================================================
# INSTALAÇÕES
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Atualiza sistema + dependências base
# ------------------------------------------------------------------------------
info "Atualizando o sistema e instalando dependências base..."

# Keyring primeiro (problema comum em Manjaro/BigLinux desatualizados)
sudo pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null \
  || sudo pacman -S --noconfirm --needed manjaro-keyring 2>/dev/null \
  || sudo pacman -S --noconfirm --needed biglinux-keyring 2>/dev/null \
  || true

sudo pacman -Syu --noconfirm

sudo pacman -S --noconfirm --needed \
  curl wget git \
  base-devel \
  gnupg \
  fuse2 \
  libxtst libxi libxext libxrender \
  unzip tar jq

log "Sistema atualizado e dependências base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js LTS
# ------------------------------------------------------------------------------
info "Instalando NVM (Node Version Manager)..."
export NVM_DIR="$HOME/.nvm"
NVM_VERSION="v0.40.3"

if [[ -d "$NVM_DIR" && -s "$NVM_DIR/nvm.sh" ]]; then
  warn "NVM já está instalado. Pulando download..."
else
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# NVM usa variáveis não inicializadas — desabilita nounset temporariamente
set +u
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ]          && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

if ! command -v nvm &>/dev/null; then
  set -u
  error "NVM não foi carregado corretamente. Verifique sua conexão e tente novamente."
fi

info "Instalando Node.js LTS..."
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'
set -u

log "Node.js $(node -v) | NPM $(npm -v)"

# Persiste NVM no bashrc e zshrc (idempotente)
NVM_BLOCK='# NVM — Node Version Manager
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

if ! grep -qF 'NVM_DIR' ~/.bashrc 2>/dev/null; then
  printf '\n%s\n' "$NVM_BLOCK" >> ~/.bashrc
fi

if [[ -f ~/.zshrc ]] && ! grep -qF 'NVM_DIR' ~/.zshrc 2>/dev/null; then
  printf '\n%s\n' "$NVM_BLOCK" >> ~/.zshrc
fi

log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code — visual-studio-code-bin (Microsoft) via AUR
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code (versão Microsoft via AUR)..."

if command -v code &>/dev/null; then
  if code --version 2>/dev/null | grep -qi "microsoft"; then
    warn "VS Code (Microsoft) já está instalado. Pulando..."
  else
    warn "Detectado VS Code OSS. Substituindo pela versão Microsoft..."
    sudo pacman -Rns --noconfirm code 2>/dev/null || true
    aur_install "visual-studio-code-bin"
  fi
else
  aur_install "visual-studio-code-bin"
fi

log "VS Code instalado: $(code --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------------------
# 4. Insomnia — tenta pacman, cai para AUR (insomnia-bin)
# ------------------------------------------------------------------------------
info "Instalando Insomnia..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia já está instalado. Pulando..."
else
  if sudo pacman -Si insomnia &>/dev/null; then
    sudo pacman -S --noconfirm --needed insomnia
    log "Insomnia instalado via pacman."
  else
    aur_install "insomnia-bin"
  fi
fi

# ------------------------------------------------------------------------------
# 5. JetBrains Toolbox → DataGrip
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."
TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"
TOOLBOX_INSTALLED=false

if [[ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]]; then
  warn "JetBrains Toolbox já está instalado. Pulando..."
  TOOLBOX_INSTALLED=true
else
  # Tenta AUR primeiro, fallback para download direto
  if aur_install "jetbrains-toolbox" 2>/dev/null; then
    local_toolbox_path=""
    local_toolbox_path=$(command -v jetbrains-toolbox 2>/dev/null || true)
    if [[ -n "$local_toolbox_path" && "$local_toolbox_path" != "$TOOLBOX_DIR/jetbrains-toolbox" ]]; then
      mkdir -p "$TOOLBOX_DIR"
      ln -sf "$local_toolbox_path" "$TOOLBOX_DIR/jetbrains-toolbox"
    fi
    TOOLBOX_INSTALLED=true
    log "JetBrains Toolbox instalado via AUR."
  else
    warn "AUR falhou para jetbrains-toolbox. Usando download direto..."
    install_toolbox_manual "$TOOLBOX_DIR"
    TOOLBOX_INSTALLED=true
  fi
fi

if [[ "$TOOLBOX_INSTALLED" == true ]]; then
  log "JetBrains Toolbox disponível."
  warn "Abra o Toolbox e instale o DataGrip pela interface gráfica."
  warn "Executável: ${TOOLBOX_DIR}/jetbrains-toolbox"
else
  warn "Falha ao instalar JetBrains Toolbox. Instale manualmente:"
  warn "  https://www.jetbrains.com/toolbox-app/"
fi

# ------------------------------------------------------------------------------
# 6. Docker CE + plugins
# ------------------------------------------------------------------------------
info "Instalando Docker..."
if command -v docker &>/dev/null; then
  warn "Docker já está instalado. Pulando..."
else
  sudo pacman -S --noconfirm --needed docker docker-compose docker-buildx

  sudo usermod -aG docker "$USER"

  if [[ "$HAS_SYSTEMD" == true ]]; then
    sudo systemctl enable docker.service
    sudo systemctl enable containerd.service
    sudo systemctl start docker.service
  else
    warn "Artix detectado (sem systemd). Habilite o serviço Docker manualmente:"
    warn "  sudo rc-update add docker default && sudo rc-service docker start"
  fi
fi

# Valida daemon
if [[ "$HAS_SYSTEMD" == true ]]; then
  if sudo systemctl is-active --quiet docker; then
    log "Docker instalado e rodando: $(docker --version)"
  else
    warn "Docker instalado mas o serviço não iniciou. Tente: sudo systemctl start docker"
  fi
else
  log "Docker instalado: $(docker --version 2>/dev/null || echo 'verifique serviço')"
fi

warn "Faça logout e login para ativar as permissões do grupo 'docker'."

# ==============================================================================
# Resumo final
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Instalação concluída!  ($DISTRO_NAME)${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Node.js :${NC}  $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM     :${NC}  $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code :${NC}  $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}Docker  :${NC}  $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}DataGrip:${NC}  $([[ "$TOOLBOX_INSTALLED" == true ]] && echo 'via Toolbox' || echo 'manual')"
echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
warn "Faça logout e login para ativar as permissões do grupo 'docker'."
