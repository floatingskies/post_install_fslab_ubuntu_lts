#!/bin/bash
# ==============================================================================
# Script de Instalação para Ubuntu / Debian
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
# Sem Snap ou Flatpak (usado apenas como último recurso)
# ==============================================================================

set -e  # Encerra se qualquer comando falhar

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
info()   { echo -e "${BLUE}[»]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }

# Verifica se está rodando como root
if [ "$EUID" -eq 0 ]; then
  error "Não execute este script como root. Use um usuário comum com sudo."
fi

# Detecta distro
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
else
  error "Não foi possível detectar a distribuição."
fi

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
  error "Este script é para Ubuntu/Debian. Distro detectada: $DISTRO"
fi

info "Distro detectada: $PRETTY_NAME"

# ------------------------------------------------------------------------------
# 1. Atualiza o sistema
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git build-essential ca-certificates gnupg lsb-release apt-transport-https software-properties-common
log "Dependências base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js (via repositório oficial NVM)
# ------------------------------------------------------------------------------
info "Instalando NVM (Node Version Manager)..."
export NVM_DIR="$HOME/.nvm"

if [ -d "$NVM_DIR" ]; then
  warn "NVM já está instalado. Pulando..."
else
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# Carrega NVM na sessão atual
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

info "Instalando Node.js LTS via NVM..."
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'

log "Node.js $(node -v) instalado. NPM $(npm -v)."

# Adiciona NVM ao .bashrc e .zshrc se existir
NVM_INIT='export NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.bashrc || echo -e "\n$NVM_INIT" >> ~/.bashrc
[ -f ~/.zshrc ] && grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.zshrc || ([ -f ~/.zshrc ] && echo -e "\n$NVM_INIT" >> ~/.zshrc)
log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code (repositório oficial Microsoft .deb)
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code via repositório oficial Microsoft..."

if command -v code &>/dev/null; then
  warn "VS Code já está instalado. Pulando..."
else
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
  sudo install -o root -g root -m 644 /tmp/microsoft.gpg /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
  sudo apt update
  sudo apt install -y code
  rm -f /tmp/microsoft.gpg
fi
log "VS Code instalado."

# ------------------------------------------------------------------------------
# 4. Insomnia (repositório oficial Kong .deb)
# ------------------------------------------------------------------------------
info "Instalando Insomnia via repositório oficial..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia já está instalado. Pulando..."
else
  curl -fsSL https://insomnia.rest/inso-pkg/key.gpg | gpg --dearmor | \
    sudo tee /etc/apt/keyrings/insomnia.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/insomnia.gpg] https://packages.konghq.com/public/insomnia/deb/ubuntu focal main" \
    | sudo tee /etc/apt/sources.list.d/insomnia.list > /dev/null
  sudo apt update
  if sudo apt install -y insomnia 2>/dev/null; then
    log "Insomnia instalado via repositório oficial."
  else
    warn "Repositório oficial falhou. Baixando .deb diretamente..."
    INSOMNIA_VERSION=$(curl -s https://api.github.com/repos/Kong/insomnia/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    INSOMNIA_DEB="Insomnia.Core-${INSOMNIA_VERSION#core@}.deb"
    wget -O /tmp/insomnia.deb "https://github.com/Kong/insomnia/releases/download/${INSOMNIA_VERSION}/${INSOMNIA_DEB}"
    sudo apt install -y /tmp/insomnia.deb
    rm -f /tmp/insomnia.deb
    log "Insomnia instalado via .deb direto."
  fi
fi

# ------------------------------------------------------------------------------
# 5. DataGrip (JetBrains Toolbox — sem Snap)
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox (para gerenciar DataGrip)..."

TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox já está instalado. Pulando..."
else
  TOOLBOX_URL=$(curl -s "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | grep -oP '"linux":\{"link":"\K[^"]+' | head -1)

  if [ -z "$TOOLBOX_URL" ]; then
    warn "Não foi possível obter URL automática. Usando URL fixa..."
    TOOLBOX_URL="https://download.jetbrains.com/toolbox/jetbrains-toolbox-2.5.2.35332.tar.gz"
  fi

  wget -O /tmp/jetbrains-toolbox.tar.gz "$TOOLBOX_URL"
  tar -xzf /tmp/jetbrains-toolbox.tar.gz -C /tmp/
  TOOLBOX_BIN=$(find /tmp -name "jetbrains-toolbox" -type f | head -1)
  mkdir -p "$TOOLBOX_DIR"
  mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/"
  chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"
  rm -f /tmp/jetbrains-toolbox.tar.gz
fi

log "JetBrains Toolbox instalado em $TOOLBOX_DIR"
warn "Abra o JetBrains Toolbox e instale o DataGrip de lá: $TOOLBOX_DIR/jetbrains-toolbox"

# ------------------------------------------------------------------------------
# 6. Docker (repositório oficial Docker CE)
# ------------------------------------------------------------------------------
info "Instalando Docker CE via repositório oficial..."

if command -v docker &>/dev/null; then
  warn "Docker já está instalado. Pulando..."
else
  # Remove versões antigas
  sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  # Adiciona repositório Docker
  curl -fsSL https://download.docker.com/linux/${DISTRO}/gpg | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${DISTRO} $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Adiciona usuário ao grupo docker
  sudo usermod -aG docker "$USER"
  sudo systemctl enable docker
  sudo systemctl start docker
fi

log "Docker $(docker --version) instalado."
warn "Faça logout e login para que as permissões do grupo 'docker' tenham efeito."

# ------------------------------------------------------------------------------
# Resumo final
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Instalação concluída com sucesso!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Node.js:${NC}   $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM:${NC}       $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code:${NC}   $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Docker:${NC}    $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}DataGrip:${NC}  Instale via JetBrains Toolbox → $TOOLBOX_DIR/jetbrains-toolbox"
echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
