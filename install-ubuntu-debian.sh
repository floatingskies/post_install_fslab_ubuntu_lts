#!/bin/bash
# ==============================================================================
# Script de Instalação para Ubuntu / Debian
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
# Sem Snap ou Flatpak (usado apenas como último recurso)
#
# Correções aplicadas:
#   - VS Code: /etc/apt/keyrings criado explicitamente antes de gravar a chave GPG
#   - Insomnia: repositório APT da Kong foi descontinuado; usa GitHub Releases
#   - Docker: VERSION_CODENAME (os-release) em vez de lsb_release -cs,
#             que retorna codename errado em distros derivadas e Ubuntu 24.04
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
info()  { echo -e "${BLUE}[»]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; exit 1; }

# ------------------------------------------------------------------------------
# Validacoes iniciais
# ------------------------------------------------------------------------------
if [ "$EUID" -eq 0 ]; then
  error "Nao execute este script como root. Use um usuario comum com sudo."
fi

if [ ! -f /etc/os-release ]; then
  error "Nao foi possivel detectar a distribuicao."
fi

. /etc/os-release
DISTRO="$ID"

# VERSION_CODENAME e mais confiavel que lsb_release -cs em distros derivadas
CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}"

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
  error "Este script e para Ubuntu/Debian. Distro detectada: $DISTRO"
fi

# Distros derivadas (Pop!_OS, Mint) reportam seu proprio codename, que nao
# existe nos repositorios Docker/Microsoft. Forcamos ubuntu ou debian.
if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
  UPSTREAM_DISTRO="$DISTRO"
elif [[ "$ID_LIKE" == *"ubuntu"* ]]; then
  UPSTREAM_DISTRO="ubuntu"
else
  UPSTREAM_DISTRO="debian"
fi

info "Distro detectada : $PRETTY_NAME"
info "Codename         : $CODENAME"
info "Upstream         : $UPSTREAM_DISTRO"

# ------------------------------------------------------------------------------
# Autenticacao sudo antecipada com keepalive
# Solicita a senha uma unica vez e renova o cache em background
# evitando timeout em etapas longas como download e instalacao de pacotes
# ------------------------------------------------------------------------------
info "Autenticando sudo..."
sudo -v || error "Falha na autenticacao sudo. Verifique sua senha e tente novamente."

(
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done
) &
SUDO_KEEPALIVE_PID=$!

trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

log "Sudo autenticado. Cache sera renovado automaticamente."

# ------------------------------------------------------------------------------
# 1. Dependencias base
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
  curl wget git build-essential \
  ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common

# Necessario em Ubuntu 20.04 e instalacoes minimas que nao trazem este diretorio
sudo mkdir -p /etc/apt/keyrings

log "Dependencias base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js
# ------------------------------------------------------------------------------
info "Instalando NVM..."
export NVM_DIR="$HOME/.nvm"

if [ -d "$NVM_DIR" ]; then
  warn "NVM ja esta instalado. Pulando..."
else
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# Desabilita nounset (-u) ao carregar e usar o NVM
# O NVM usa variaveis internas nao inicializadas que causam erro com set -u
set +u

[ -s "$NVM_DIR/nvm.sh" ]          && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

info "Instalando Node.js LTS..."
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'

set -u

log "Node.js $(node -v) | NPM $(npm -v)"

NVM_INIT='export NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.bashrc \
  || echo -e "\n$NVM_INIT" >> ~/.bashrc
{ [ -f ~/.zshrc ] && grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.zshrc; } \
  || { [ -f ~/.zshrc ] && echo -e "\n$NVM_INIT" >> ~/.zshrc; }

log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code
# FIX: sudo mkdir -p /etc/apt/keyrings e obrigatorio antes de gravar o .gpg
#      O repositorio usa "stable" como codename — independente da distro/versao
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code..."

if command -v code &>/dev/null; then
  warn "VS Code ja esta instalado. Pulando..."
else
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/microsoft-vscode.gpg > /dev/null
  sudo chmod a+r /etc/apt/keyrings/microsoft-vscode.gpg

  # "stable" e um codename fixo do repositorio Microsoft — nao varia com a distro
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft-vscode.gpg] \
https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y code
fi

log "VS Code instalado: $(code --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------------------
# 4. Insomnia
# FIX: O repositorio APT da Kong (packages.konghq.com/public/insomnia) foi
#      descontinuado e nao recebe mais atualizacoes. A fonte oficial atual
#      e o GitHub Releases do repositorio Kong/insomnia.
#      O script detecta automaticamente a versao mais recente (tag core@x.x.x)
# ------------------------------------------------------------------------------
info "Instalando Insomnia via GitHub Releases..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia ja esta instalado. Pulando..."
else
  INSOMNIA_TAG=$(curl -fsSL https://api.github.com/repos/Kong/insomnia/releases \
    | grep -oP '"tag_name":\s*"\Kcore@[^"]+' \
    | head -1)

  if [ -z "$INSOMNIA_TAG" ]; then
    error "Nao foi possivel obter a versao mais recente do Insomnia. Verifique sua conexao."
  fi

  INSOMNIA_VERSION="${INSOMNIA_TAG#core@}"
  INSOMNIA_URL="https://github.com/Kong/insomnia/releases/download/${INSOMNIA_TAG}/Insomnia.Core-${INSOMNIA_VERSION}.deb"

  info "Baixando Insomnia ${INSOMNIA_VERSION}..."
  wget -O /tmp/insomnia.deb "$INSOMNIA_URL"
  sudo apt-get install -y /tmp/insomnia.deb
  rm -f /tmp/insomnia.deb

  log "Insomnia ${INSOMNIA_VERSION} instalado."
fi

# ------------------------------------------------------------------------------
# 5. DataGrip via JetBrains Toolbox
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."

TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox ja esta instalado. Pulando..."
else
  TOOLBOX_URL=$(curl -fsSL \
    "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | grep -oP '"linux":\{"link":"\K[^"]+' \
    | head -1)

  if [ -z "$TOOLBOX_URL" ]; then
    warn "URL automatica indisponivel. Usando versao fixa..."
    TOOLBOX_URL="https://download.jetbrains.com/toolbox/jetbrains-toolbox-2.5.2.35332.tar.gz"
  fi

  # Extrai para diretório proprio em vez de soltar direto em /tmp
  # Evita que o find atravesse diretorios protegidos do systemd em /tmp
  TOOLBOX_TMP=$(mktemp -d)
  wget -O "$TOOLBOX_TMP/toolbox.tar.gz" "$TOOLBOX_URL"
  tar -xzf "$TOOLBOX_TMP/toolbox.tar.gz" -C "$TOOLBOX_TMP/"
  TOOLBOX_BIN=$(find "$TOOLBOX_TMP" -name "jetbrains-toolbox" -type f | head -1)

  if [ -z "$TOOLBOX_BIN" ]; then
    error "Binario jetbrains-toolbox nao encontrado apos extracao."
  fi

  mkdir -p "$TOOLBOX_DIR"
  mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/"
  chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"
  rm -rf "$TOOLBOX_TMP"
fi

log "JetBrains Toolbox disponivel em: $TOOLBOX_DIR/jetbrains-toolbox"
warn "Abra o Toolbox e instale o DataGrip pela interface grafica."

# ------------------------------------------------------------------------------
# 6. Docker CE
# FIX 1: Usa VERSION_CODENAME do /etc/os-release em vez de lsb_release -cs
#         Em Ubuntu 24.04, lsb_release -cs pode retornar "noble" corretamente
#         mas em distros derivadas retorna o codename da propria distro,
#         que nao existe no repositorio Docker.
# FIX 2: Usa $UPSTREAM_DISTRO (ubuntu|debian) para montar a URL do repositorio,
#         evitando URLs invalidas como download.docker.com/linux/pop ou /linuxmint
# FIX 3: Valida se o repositorio foi reconhecido antes de tentar instalar
# ------------------------------------------------------------------------------
info "Instalando Docker CE..."

if command -v docker &>/dev/null; then
  warn "Docker ja esta instalado. Pulando..."
else
  # Remove pacotes conflitantes
  for pkg in docker docker-engine docker.io containerd runc \
              docker-doc docker-compose docker-compose-v2; do
    sudo apt-get remove -y "$pkg" 2>/dev/null || true
  done

  # Chave GPG usando a distro upstream (ubuntu ou debian)
  curl -fsSL "https://download.docker.com/linux/${UPSTREAM_DISTRO}/gpg" \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Repositorio usando codename correto do /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${UPSTREAM_DISTRO} ${CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y

  # Valida se o repositorio esta acessivel para esta combinacao distro+codename
  if ! apt-cache policy docker-ce 2>/dev/null | grep -q "download.docker.com"; then
    error "Repositorio Docker nao reconheceu '${UPSTREAM_DISTRO} ${CODENAME}'.
Verifique as versoes suportadas em: https://docs.docker.com/engine/install/ubuntu/"
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

log "Docker instalado: $(docker --version)"
warn "Faca logout e login para ativar as permissoes do grupo 'docker'."

# ------------------------------------------------------------------------------
# Resumo final
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Instalacao concluida com sucesso!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Node.js :${NC}  $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM     :${NC}  $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code :${NC}  $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}Docker  :${NC}  $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}DataGrip:${NC}  Instale via Toolbox: $TOOLBOX_DIR/jetbrains-toolbox"
echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
