#!/bin/bash
# ==============================================================================
# Script de Instalação para Fedora (42+) e derivados RHEL-family
# Compatível com: Fedora 42/43/44/45+, e como fallback experimental para
#                 RHEL 9+, CentOS Stream, AlmaLinux, Rocky Linux (via ID_LIKE)
#
# Ferramentas: NVM + Node.js LTS, VS Code (Microsoft), Insomnia, JetBrains
#              Toolbox (→ DataGrip), Docker CE com compose e buildx
#
# Princípios de robustez aplicados:
#   - set -Eeuo pipefail + trap ERR com linha e comando (depois das cores!)
#   - Tudo idempotente: re-executar é seguro
#   - Diretório temporário único por execução, limpo em qualquer saída
#   - Sudo keepalive em background (uma senha só, sem timeout)
#   - Log paralelo em arquivo com timestamp
#   - Cores auto-desativadas fora de TTY
#   - Lock file para impedir execuções concorrentes
#   - Detecção de arquitetura (x86_64 / aarch64)
#   - Validação de download (tamanho mínimo) antes de extrair
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="install-fedora.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly LOG_DIR="${HOME}/.local/share/fslab/logs"
readonly LOG_FILE="${LOG_DIR}/install-fedora-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/fslab-install-fedora.lock"
readonly TMP_ROOT="$(mktemp -d -t fslab-fedora-XXXXXX)"

# ------------------------------------------------------------------------------
# Colors — definidas ANTES do trap ERR (caso contrário $RED/$NC ficam vazias
# na mensagem de erro quando o trap dispara precocemente)
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
# Logging
# ------------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

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
# ERR trap — agora seguro de usar (variáveis de cor já definidas)
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
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT" 2>/dev/null || true
  rm -f "$LOCK_FILE" 2>/dev/null || true
  if [[ $exit_code -eq 0 ]]; then
    log "Log completo salvo em: $LOG_FILE"
  else
    warn "Script falhou. Log completo em: $LOG_FILE"
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Lock file
# ------------------------------------------------------------------------------
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      error "Outra instância deste script já está rodando (PID $pid)."
    fi
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
  error "Não foi possível detectar a distribuição."
fi

# shellcheck disable=SC1091
. /etc/os-release
DISTRO="${ID:-unknown}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO}"
DISTRO_VERSION="${VERSION_ID:-}"
ARCH="$(uname -m)"

# Detecta família: Fedora puro ou RHEL-like
IS_FEDORA=false
IS_RHEL_LIKE=false
if [[ "$DISTRO" == "fedora" ]]; then
  IS_FEDORA=true
elif [[ "$DISTRO" == "rhel" || "$DISTRO" == "centos" || "$DISTRO" == "almalinux" || "$DISTRO" == "rocky" ]]; then
  IS_RHEL_LIKE=true
elif [[ "${ID_LIKE:-}" == *"rhel"* || "${ID_LIKE:-}" == *"fedora"* ]]; then
  IS_RHEL_LIKE=true
fi

if [[ "$IS_FEDORA" == false && "$IS_RHEL_LIKE" == false ]]; then
  error "Distro não suportada: $DISTRO_NAME
Suportado: Fedora 42+, RHEL 9+, CentOS Stream, AlmaLinux, Rocky Linux."
fi

# Versão mínima para Fedora puro
if [[ "$IS_FEDORA" == true ]]; then
  if [[ -z "$DISTRO_VERSION" || "$DISTRO_VERSION" -lt 42 ]]; then
    error "Requer Fedora 42+. Detectado: ${DISTRO_VERSION:-desconhecida}"
  fi
fi

info "Distro detectada : $DISTRO_NAME"
info "Arquitetura      : $ARCH"
info "Família          : $([[ "$IS_FEDORA" == true ]] && echo 'Fedora' || echo 'RHEL-like')"
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
if ! curl -fsSL --max-time 10 https://fedoraproject.org > /dev/null 2>&1; then
  if ! curl -fsSL --max-time 10 https://www.google.com > /dev/null 2>&1; then
    error "Sem conexão com a internet. Verifique sua rede e tente novamente."
  fi
fi
log "Conexão OK."

# ------------------------------------------------------------------------------
# DNF detection (DNF5 no Fedora 41+, DNF4 em RHEL/CentOS)
# ------------------------------------------------------------------------------
DNF_BIN="dnf"
if command -v dnf5 &>/dev/null; then
  DNF_BIN="dnf5"
fi
info "Usando gerenciador de pacotes: $DNF_BIN"

# ==============================================================================
# INSTALAÇÕES
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Atualiza sistema + dependências base
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo "$DNF_BIN" upgrade --refresh -y

sudo "$DNF_BIN" install -y \
  curl wget git gcc make ca-certificates gnupg \
  dnf-plugins-core unzip jq tar \
  libXtst libX11 libXext libXrender libXi \
  fuse fuse-libs

log "Dependências base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js LTS
# ------------------------------------------------------------------------------
info "Instalando NVM..."
export NVM_DIR="$HOME/.nvm"
NVM_VERSION="v0.40.3"

if [[ -d "$NVM_DIR" && -s "$NVM_DIR/nvm.sh" ]]; then
  warn "NVM já está instalado. Pulando download..."
else
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

set +u
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ]          && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

info "Instalando Node.js LTS..."
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'
set -u

log "Node.js $(node -v) | NPM $(npm -v)"

# Persiste no shell (idempotente)
NVM_INIT='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

if ! grep -qF 'NVM_DIR="$HOME/.nvm"' ~/.bashrc 2>/dev/null; then
  printf '\n# NVM\n%s\n' "$NVM_INIT" >> ~/.bashrc
fi
if [[ -f ~/.zshrc ]] && ! grep -qF 'NVM_DIR="$HOME/.nvm"' ~/.zshrc 2>/dev/null; then
  printf '\n# NVM\n%s\n' "$NVM_INIT" >> ~/.zshrc
fi
log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code — repo Microsoft (suporta apenas x86_64 e arm64)
# ------------------------------------------------------------------------------
info "Instalando VS Code..."
if command -v code &>/dev/null; then
  warn "VS Code já instalado. Pulando..."
else
  if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
    warn "Arquitetura $ARCH não suportada pelo repo oficial Microsoft. Pulando VS Code."
  else
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
    sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    sudo "$DNF_BIN" install -y code
  fi
fi
log "VS Code: $(code --version 2>/dev/null | head -1 || echo 'não instalado')"

# ------------------------------------------------------------------------------
# 4. Insomnia via GitHub Releases (.rpm)
# ------------------------------------------------------------------------------
info "Instalando Insomnia..."
if command -v insomnia &>/dev/null; then
  warn "Insomnia já instalado. Pulando..."
else
  INSOMNIA_URL=""
  INSOMNIA_URL=$(curl -fsSL https://api.github.com/repos/Kong/insomnia/releases/latest \
    | jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' 2>/dev/null \
    | head -1)

  if [[ -z "$INSOMNIA_URL" ]]; then
    # Fallback: constrói a URL a partir da tag
    INSOMNIA_TAG=$(curl -fsSL https://api.github.com/repos/Kong/insomnia/releases/latest \
      | jq -r '.tag_name')
    if [[ -n "$INSOMNIA_TAG" ]]; then
      INSOMNIA_VERSION="${INSOMNIA_TAG#core@}"
      INSOMNIA_URL="https://github.com/Kong/insomnia/releases/download/${INSOMNIA_TAG}/Insomnia.Core-${INSOMNIA_VERSION}.rpm"
    fi
  fi

  if [[ -z "$INSOMNIA_URL" ]]; then
    warn "Não foi possível obter URL do Insomnia. Instale manualmente: https://insomnia.rest/download"
  else
    info "Baixando Insomnia de: $INSOMNIA_URL"
    INSOMNIA_RPM="$TMP_ROOT/insomnia.rpm"
    wget -q -O "$INSOMNIA_RPM" "$INSOMNIA_URL"

    # Valida tamanho mínimo (5MB) antes de instalar
    FILESIZE=$(stat -c%s "$INSOMNIA_RPM" 2>/dev/null || echo 0)
    if (( FILESIZE < 5000000 )); then
      warn "Download do Insomnia falhou (${FILESIZE} bytes). Pulando."
    else
      sudo "$DNF_BIN" install -y "$INSOMNIA_RPM"
      log "Insomnia instalado."
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 5. JetBrains Toolbox (resiliente — não derruba o script se falhar)
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."
TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"
TOOLBOX_INSTALLED=false

if [[ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]]; then
  warn "JetBrains Toolbox já instalado. Pulando..."
  TOOLBOX_INSTALLED=true
else
  set +e
  TOOLBOX_URL=""
  TOOLBOX_URL=$(curl -fsSL "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | jq -r '.TBA[0].downloads.linux.link // empty' 2>/dev/null)

  if [[ -z "$TOOLBOX_URL" ]]; then
    TOOLBOX_URL=$(curl -fsSL "https://www.jetbrains.com/toolbox-app/download/" \
      | grep -oP 'https://download\.jetbrains\.com/toolbox/jetbrains-toolbox-[^"]+\.tar\.gz' \
      | head -1)
  fi

  if [[ -n "$TOOLBOX_URL" ]]; then
    TB_TMP="$TMP_ROOT/toolbox"
    mkdir -p "$TB_TMP"
    wget -qO "$TB_TMP/toolbox.tar.gz" "$TOOLBOX_URL"

    FILESIZE=$(stat -c%s "$TB_TMP/toolbox.tar.gz" 2>/dev/null || echo 0)
    if (( FILESIZE > 5000000 )); then
      tar -xzf "$TB_TMP/toolbox.tar.gz" -C "$TB_TMP/" 2>/dev/null
      TOOLBOX_BIN=$(find "$TB_TMP" -name "jetbrains-toolbox" -type f -print -quit 2>/dev/null)
      if [[ -n "$TOOLBOX_BIN" && -s "$TOOLBOX_BIN" ]]; then
        mkdir -p "$TOOLBOX_DIR"
        mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/"
        chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"
        TOOLBOX_INSTALLED=true
      fi
    fi
  fi
  set -e
fi

if [[ "$TOOLBOX_INSTALLED" == true ]]; then
  log "JetBrains Toolbox instalado em $TOOLBOX_DIR"
else
  warn "============================================================="
  warn "FALHA AO INSTALAR O JETBRAINS TOOLBOX (API bloqueou/indisponível)."
  warn "============================================================="
  warn "Instale manualmente em: https://www.jetbrains.com/toolbox-app/"
fi

# ------------------------------------------------------------------------------
# 6. Docker CE (repo oficial — apenas Fedora; RHEL-family usa podman ou repo)
# ------------------------------------------------------------------------------
info "Instalando Docker CE..."
if command -v docker &>/dev/null; then
  warn "Docker já instalado. Pulando..."
else
  # Remove pacotes conflitantes (sem falhar se não existirem)
  sudo "$DNF_BIN" remove -y \
    docker docker-client docker-common docker-latest \
    docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine podman-docker 2>/dev/null || true

  if [[ "$IS_FEDORA" == true ]]; then
    # Solução definitiva: baixa o .repo direto, evita bug do config-manager no DNF5
    info "Adicionando repositório oficial do Docker (Fedora)..."
    curl -fsSL "https://download.docker.com/linux/fedora/docker-ce.repo" -o "$TMP_ROOT/docker-ce.repo"
    sudo mv "$TMP_ROOT/docker-ce.repo" /etc/yum.repos.d/docker-ce.repo

    sudo "$DNF_BIN" install -y --allowerasure \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  else
    # RHEL/CentOS/Alma/Rocky — usa o repo genérico centos
    info "Adicionando repositório oficial do Docker (RHEL-family)..."
    sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<EOF
[docker-ce-stable]
name=Docker CE Stable
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
    sudo "$DNF_BIN" install -y --allowerasure \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
fi

if sudo systemctl is-active --quiet docker; then
  log "Docker instalado e rodando: $(docker --version)"
else
  warn "Docker instalado mas o serviço não iniciou. Tente: sudo systemctl start docker"
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
echo -e "  ${BLUE}Docker  :${NC}  $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}DataGrip:${NC}  $([[ "$TOOLBOX_INSTALLED" == true ]] && echo 'via Toolbox' || echo 'manual')"
echo ""
warn "Reinicie o terminal (source ~/.bashrc) e faça logout/login para o Docker."
