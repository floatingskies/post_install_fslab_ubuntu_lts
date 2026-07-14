#!/bin/bash
# ==============================================================================
# Script de Instalação para Ubuntu / Debian e derivados
# Compatível com: Ubuntu 20.04+, Debian 11+, Linux Mint, Pop!_OS, Elementary,
#                 Zorin e outras distros baseadas em Debian
#
# Ferramentas: NVM + Node.js LTS, VS Code (Microsoft), Insomnia, JetBrains
#              Toolbox (→ DataGrip), Docker CE com compose e buildx
#
# Princípios de robustez aplicados:
#   - set -Eeuo pipefail + trap ERR com linha e comando
#   - Tudo idempotente: re-executar é seguro
#   - Diretório temporário único por execução, limpo em qualquer saída
#   - Sudo keepalive em background (uma senha só, sem timeout)
#   - Log paralelo em arquivo com timestamp
#   - Cores auto-desativadas fora de TTY
#   - Lock file para impedir execuções concorrentes
#   - Detecção de arquitetura (amd64, arm64, armhf)
#   - Codename resolvido via /etc/os-release (não lsb_release, que mente em derivadas)
#   - Validação de repos Docker/Microsoft antes de instalar
#
# Correções aplicadas nesta versão:
#   - VS Code: /etc/apt/keyrings criado explicitamente antes de gravar a chave GPG
#   - Insomnia: repositório APT da Kong descontinuado; usa GitHub Releases
#   - Docker: VERSION_CODENAME do os-release em vez de lsb_release -cs
#   - Suporta Debian sid/testing (codename "não-LTS") com fallback para "bookworm"
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="install-ubuntu-debian.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly LOG_DIR="${HOME}/.local/share/fslab/logs"
readonly LOG_FILE="${LOG_DIR}/install-ubuntu-debian-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/fslab-install-ubuntu-debian.lock"
readonly TMP_ROOT="$(mktemp -d -t fslab-debian-XXXXXX)"

# ------------------------------------------------------------------------------
# Colors
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
# ERR trap
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
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# VERSION_CODENAME é mais confiável que lsb_release -cs em distros derivadas
# Para Debian sid/testing, VERSION_CODENAME pode não estar definido
CODENAME="${VERSION_CODENAME:-}"
if [[ -z "$CODENAME" ]]; then
  CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
fi

# Detecta upstream (ubuntu ou debian) — derivadas reportam codename próprio
# que não existe nos repositórios Docker/Microsoft
if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
  UPSTREAM_DISTRO="$DISTRO"
elif [[ "${ID_LIKE:-}" == *"ubuntu"* ]]; then
  UPSTREAM_DISTRO="ubuntu"
elif [[ "${ID_LIKE:-}" == *"debian"* ]]; then
  UPSTREAM_DISTRO="debian"
else
  UPSTREAM_DISTRO="debian"  # fallback conservador
fi

# Debian sid/testing não tem codename fixo no repo Docker — usa bookworm como fallback
DEBIAN_SID_CODENAMES=("sid" "trixie" "forky")
NEEDS_CODENAME_FALLBACK=false
for sid_name in "${DEBIAN_SID_CODENAMES[@]}"; do
  if [[ "$CODENAME" == "$sid_name" ]]; then
    NEEDS_CODENAME_FALLBACK=true
    break
  fi
done

if [[ "$NEEDS_CODENAME_FALLBACK" == true ]]; then
  warn "Codename '$CODENAME' (Debian testing/sid) não tem repo Docker dedicado."
  warn "Usando 'bookworm' como fallback para o repositório Docker."
  CODENAME="bookworm"
fi

# Validação final
if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" && "${ID_LIKE:-}" != *"debian"* && "${ID_LIKE:-}" != *"ubuntu"* ]]; then
  error "Este script é para Ubuntu/Debian. Distro detectada: $DISTRO_NAME"
fi

info "Distro detectada : $DISTRO_NAME"
info "Codename         : $CODENAME"
info "Upstream         : $UPSTREAM_DISTRO"
info "Arquitetura      : $ARCH"
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
if ! curl -fsSL --max-time 10 https://launchpad.net > /dev/null 2>&1; then
  if ! curl -fsSL --max-time 10 https://www.google.com > /dev/null 2>&1; then
    error "Sem conexão com a internet. Verifique sua rede e tente novamente."
  fi
fi
log "Conexão OK."

# ==============================================================================
# INSTALAÇÕES
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Dependências base
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo apt-get update -y
sudo apt-get upgrade -y

sudo apt-get install -y \
  curl wget git build-essential \
  ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common \
  jq unzip tar

# Necessário em Ubuntu 20.04 e instalações mínimas
sudo mkdir -p /etc/apt/keyrings

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

if ! grep -qF 'export NVM_DIR="$HOME/.nvm"' ~/.bashrc 2>/dev/null; then
  printf '\n# NVM\n%s\n' "$NVM_INIT" >> ~/.bashrc
fi
if [[ -f ~/.zshrc ]] && ! grep -qF 'export NVM_DIR="$HOME/.nvm"' ~/.zshrc 2>/dev/null; then
  printf '\n# NVM\n%s\n' "$NVM_INIT" >> ~/.zshrc
fi
log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code (repo Microsoft — codename "stable" é fixo)
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code..."
if command -v code &>/dev/null; then
  warn "VS Code já está instalado. Pulando..."
else
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/microsoft-vscode.gpg > /dev/null
  sudo chmod a+r /etc/apt/keyrings/microsoft-vscode.gpg

  # "stable" é codename fixo do repo Microsoft — independe da distro/versão
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft-vscode.gpg] \
https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y code
fi
log "VS Code instalado: $(code --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------------------
# 4. Insomnia via GitHub Releases (.deb)
# ------------------------------------------------------------------------------
info "Instalando Insomnia via GitHub Releases..."
if command -v insomnia &>/dev/null; then
  warn "Insomnia já está instalado. Pulando..."
else
  INSOMNIA_TAG=$(curl -fsSL https://api.github.com/repos/Kong/insomnia/releases \
    | grep -oP '"tag_name":\s*"\Kcore@[^"]+' \
    | head -1)

  if [[ -z "$INSOMNIA_TAG" ]]; then
    # Fallback: usa a tag "latest" do endpoint /releases/latest
    INSOMNIA_TAG=$(curl -fsSL https://api.github.com/repos/Kong/insomnia/releases/latest \
      | jq -r '.tag_name // empty')
  fi

  if [[ -z "$INSOMNIA_TAG" ]]; then
    warn "Não foi possível obter a versão mais recente do Insomnia."
    warn "Instale manualmente: https://insomnia.rest/download"
  else
    INSOMNIA_VERSION="${INSOMNIA_TAG#core@}"
    INSOMNIA_URL="https://github.com/Kong/insomnia/releases/download/${INSOMNIA_TAG}/Insomnia.Core-${INSOMNIA_VERSION}.deb"

    info "Baixando Insomnia ${INSOMNIA_VERSION}..."
    INSOMNIA_DEB="$TMP_ROOT/insomnia.deb"
    wget -q -O "$INSOMNIA_DEB" "$INSOMNIA_URL"

    # Valida tamanho mínimo (5MB)
    FILESIZE=$(stat -c%s "$INSOMNIA_DEB" 2>/dev/null || echo 0)
    if (( FILESIZE < 5000000 )); then
      warn "Download do Insomnia falhou (${FILESIZE} bytes). Pulando."
    else
      sudo apt-get install -y "$INSOMNIA_DEB"
      log "Insomnia ${INSOMNIA_VERSION} instalado."
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 5. JetBrains Toolbox
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."
TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"
TOOLBOX_INSTALLED=false

if [[ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]]; then
  warn "JetBrains Toolbox já instalado. Pulando..."
  TOOLBOX_INSTALLED=true
else
  set +e
  TOOLBOX_URL=$(curl -fsSL \
    "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | grep -oP '"linux":\{"link":"\K[^"]+' \
    | head -1)

  if [[ -z "$TOOLBOX_URL" ]]; then
    # Fallback: parseia a página de download
    TOOLBOX_URL=$(curl -fsSL "https://www.jetbrains.com/toolbox-app/download/" \
      | grep -oP 'https://download\.jetbrains\.com/toolbox/jetbrains-toolbox-[^"]+\.tar\.gz' \
      | head -1)
  fi

  if [[ -z "$TOOLBOX_URL" ]]; then
    warn "URL automática indisponível. Usando versão fixa..."
    TOOLBOX_URL="https://download.jetbrains.com/toolbox/jetbrains-toolbox-2.5.2.35332.tar.gz"
  fi

  TB_TMP="$TMP_ROOT/toolbox"
  mkdir -p "$TB_TMP"
  wget -qO "$TB_TMP/toolbox.tar.gz" "$TOOLBOX_URL"

  FILESIZE=$(stat -c%s "$TB_TMP/toolbox.tar.gz" 2>/dev/null || echo 0)
  if (( FILESIZE < 5000000 )); then
    warn "Download do Toolbox falhou (${FILESIZE} bytes)."
  else
    tar -xzf "$TB_TMP/toolbox.tar.gz" -C "$TB_TMP/"
    TOOLBOX_BIN=$(find "$TB_TMP" -name "jetbrains-toolbox" -type f -print -quit 2>/dev/null)

    if [[ -n "$TOOLBOX_BIN" && -s "$TOOLBOX_BIN" ]]; then
      mkdir -p "$TOOLBOX_DIR"
      mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/"
      chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"
      TOOLBOX_INSTALLED=true
    else
      warn "Binário jetbrains-toolbox não encontrado após extração."
    fi
  fi
  set -e
fi

if [[ "$TOOLBOX_INSTALLED" == true ]]; then
  log "JetBrains Toolbox disponível em: $TOOLBOX_DIR/jetbrains-toolbox"
  warn "Abra o Toolbox e instale o DataGrip pela interface gráfica."
else
  warn "Falha ao instalar JetBrains Toolbox. Instale manualmente:"
  warn "  https://www.jetbrains.com/toolbox-app/"
fi

# ------------------------------------------------------------------------------
# 6. Docker CE
# FIX: VERSION_CODENAME + UPSTREAM_DISTRO + validação de repo antes de instalar
# ------------------------------------------------------------------------------
info "Instalando Docker CE..."
if command -v docker &>/dev/null; then
  warn "Docker já está instalado. Pulando..."
else
  # Remove pacotes conflitantes (sem falhar se não existirem)
  for pkg in docker docker-engine docker.io containerd runc \
              docker-doc docker-compose docker-compose-v2; do
    sudo apt-get remove -y "$pkg" 2>/dev/null || true
  done

  # Chave GPG usando a distro upstream (ubuntu ou debian)
  curl -fsSL "https://download.docker.com/linux/${UPSTREAM_DISTRO}/gpg" \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Repositório usando codename correto
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${UPSTREAM_DISTRO} ${CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y

  # Valida se o repositorio foi reconhecido antes de tentar instalar
  if ! apt-cache policy docker-ce 2>/dev/null | grep -q "download.docker.com"; then
    error "Repositório Docker não reconheceu '${UPSTREAM_DISTRO} ${CODENAME}'.
Verifique as versões suportadas em: https://docs.docker.com/engine/install/${UPSTREAM_DISTRO}/"
  fi

  sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  sudo usermod -aG docker "$USER"
  sudo systemctl enable docker
  sudo systemctl start docker
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
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}Docker  :${NC}  $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}DataGrip:${NC}  $([[ "$TOOLBOX_INSTALLED" == true ]] && echo 'via Toolbox' || echo 'manual')"
echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
warn "Faça logout e login para ativar as permissões do grupo 'docker'."
