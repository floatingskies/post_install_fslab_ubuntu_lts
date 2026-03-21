#!/bin/bash
# ==============================================================================
# Script de Instalação para Fedora (37+)
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
# Sem Snap ou Flatpak (usado apenas como último recurso)
# ==============================================================================

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
info()   { echo -e "${BLUE}[»]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }

if [ "$EUID" -eq 0 ]; then
  error "Não execute este script como root. Use um usuário comum com sudo."
fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
else
  error "Não foi possível detectar a distribuição."
fi

if [[ "$DISTRO" != "fedora" ]]; then
  error "Este script é para Fedora. Distro detectada: $DISTRO"
fi

info "Distro detectada: $PRETTY_NAME"

# ------------------------------------------------------------------------------
# 1. Atualiza o sistema e instala dependências base
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo dnf upgrade --refresh -y
sudo dnf install -y curl wget git gcc make ca-certificates gnupg2 lsb-release dnf-plugins-core
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

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

info "Instalando Node.js LTS via NVM..."
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'

log "Node.js $(node -v) instalado. NPM $(npm -v)."

NVM_INIT='export NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.bashrc || echo -e "\n$NVM_INIT" >> ~/.bashrc
[ -f ~/.zshrc ] && grep -qxF 'export NVM_DIR="$HOME/.nvm"' ~/.zshrc || ([ -f ~/.zshrc ] && echo -e "\n$NVM_INIT" >> ~/.zshrc)
log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code (repositório oficial Microsoft RPM)
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code via repositório oficial Microsoft..."

if command -v code &>/dev/null; then
  warn "VS Code já está instalado. Pulando..."
else
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc

  cat <<EOF | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

  sudo dnf install -y code
fi
log "VS Code instalado."

# ------------------------------------------------------------------------------
# 4. Insomnia (repositório oficial Kong RPM)
# ------------------------------------------------------------------------------
info "Instalando Insomnia via repositório oficial..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia já está instalado. Pulando..."
else
  curl -fsSL https://insomnia.rest/inso-pkg/key.gpg | sudo gpg --dearmor -o /etc/pki/rpm-gpg/insomnia.gpg 2>/dev/null || true

  cat <<EOF | sudo tee /etc/yum.repos.d/insomnia.repo > /dev/null
[insomnia]
name=Insomnia
baseurl=https://packages.konghq.com/public/insomnia/rpm/el/8
enabled=1
gpgcheck=0
EOF

  if sudo dnf install -y insomnia 2>/dev/null; then
    log "Insomnia instalado via repositório oficial."
  else
    warn "Repositório falhou. Baixando .rpm diretamente..."
    INSOMNIA_VERSION=$(curl -s https://api.github.com/repos/Kong/insomnia/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    INSOMNIA_RPM="Insomnia.Core-${INSOMNIA_VERSION#core@}.rpm"
    wget -O /tmp/insomnia.rpm "https://github.com/Kong/insomnia/releases/download/${INSOMNIA_VERSION}/${INSOMNIA_RPM}"
    sudo dnf install -y /tmp/insomnia.rpm
    rm -f /tmp/insomnia.rpm
    log "Insomnia instalado via .rpm direto."
  fi
fi

# ------------------------------------------------------------------------------
# 5. DataGrip (JetBrains Toolbox — sem Flatpak)
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox (para gerenciar DataGrip)..."

TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox já está instalado. Pulando..."
else
  # Dependências necessárias para a Toolbox no Fedora
  sudo dnf install -y fuse libXtst libX11 libXext libXrender libXi

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
warn "Abra o JetBrains Toolbox e instale o DataGrip: $TOOLBOX_DIR/jetbrains-toolbox"

# ------------------------------------------------------------------------------
# 6. Docker CE (repositório oficial Docker)
# ------------------------------------------------------------------------------
info "Instalando Docker CE via repositório oficial..."

if command -v docker &>/dev/null; then
  warn "Docker já está instalado. Pulando..."
else
  # Remove versões antigas ou conflitantes
  sudo dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine 2>/dev/null || true

  # Adiciona repositório Docker CE para Fedora
  sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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
echo -e "${GREEN}  Instalação concluída com sucesso! (Fedora)${NC}"
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
