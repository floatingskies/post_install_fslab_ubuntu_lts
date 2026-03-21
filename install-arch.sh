#!/bin/bash
# ==============================================================================
# Script de Instalação para Arch Linux
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
# Usa repositórios oficiais (extra, community) e AUR apenas como último recurso
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

if [[ "$DISTRO" != "arch" && "$DISTRO" != "manjaro" && "$DISTRO" != "endeavouros" && "$DISTRO" != "garuda" ]]; then
  error "Este script é para Arch Linux e derivados. Distro detectada: $DISTRO"
fi

info "Distro detectada: ${PRETTY_NAME:-Arch Linux}"

# ------------------------------------------------------------------------------
# Função auxiliar: instala pacote AUR com yay ou paru (instala o helper se necessário)
# ------------------------------------------------------------------------------
install_aur() {
  local PKG="$1"
  info "Instalando '$PKG' via AUR..."

  # Verifica se yay está disponível
  if command -v yay &>/dev/null; then
    yay -S --noconfirm --needed "$PKG"
    return 0
  fi

  # Verifica se paru está disponível
  if command -v paru &>/dev/null; then
    paru -S --noconfirm --needed "$PKG"
    return 0
  fi

  # Nenhum helper AUR encontrado — instala yay
  warn "Nenhum helper AUR encontrado. Instalando 'yay'..."
  sudo pacman -S --noconfirm --needed git base-devel go
  TMP_DIR=$(mktemp -d)
  git clone https://aur.archlinux.org/yay.git "$TMP_DIR/yay"
  (cd "$TMP_DIR/yay" && makepkg -si --noconfirm)
  rm -rf "$TMP_DIR"
  log "yay instalado."
  yay -S --noconfirm --needed "$PKG"
}

# ------------------------------------------------------------------------------
# 1. Atualiza o sistema e instala dependências base
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo pacman -Syu --noconfirm
sudo pacman -S --noconfirm --needed curl wget git base-devel ca-certificates gnupg
log "Dependências base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js
# Arch tem 'nodejs' nos repos oficiais, mas NVM é preferível para flexibilidade
# ------------------------------------------------------------------------------
info "Instalando NVM (Node Version Manager)..."
export NVM_DIR="$HOME/.nvm"

if [ -d "$NVM_DIR" ]; then
  warn "NVM já está instalado. Pulando..."
else
  # Tenta instalar nvm do repositório AUR (nvm) — mais integrado ao pacman
  if sudo pacman -Si nvm &>/dev/null 2>&1; then
    sudo pacman -S --noconfirm --needed nvm
    source /usr/share/nvm/init-nvm.sh
  else
    # Fallback: instala via script oficial
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# Verifica também o caminho do pacman
[ -f /usr/share/nvm/init-nvm.sh ] && source /usr/share/nvm/init-nvm.sh

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
# 3. VS Code
# Disponível no repositório 'extra' do Arch como 'code' (open-source build)
# Para a versão proprietária com Marketplace completo, usa AUR (visual-studio-code-bin)
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code..."

if command -v code &>/dev/null; then
  warn "VS Code já está instalado. Pulando..."
else
  # Primeiro tenta o repositório oficial (build open-source)
  if sudo pacman -S --noconfirm --needed code 2>/dev/null; then
    log "VS Code (OSS build) instalado via repositório oficial."
  else
    # Fallback: versão binária proprietária via AUR
    warn "Repositório oficial não disponível. Instalando via AUR (visual-studio-code-bin)..."
    install_aur "visual-studio-code-bin"
    log "VS Code instalado via AUR."
  fi
fi

# ------------------------------------------------------------------------------
# 4. Insomnia
# Disponível no repositório 'extra' do Arch
# ------------------------------------------------------------------------------
info "Instalando Insomnia..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia já está instalado. Pulando..."
else
  # Tenta repositório oficial primeiro
  if sudo pacman -S --noconfirm --needed insomnia 2>/dev/null; then
    log "Insomnia instalado via repositório oficial."
  else
    # Fallback: AUR
    warn "Repositório oficial não disponível. Tentando AUR (insomnia-bin)..."
    install_aur "insomnia-bin"
    log "Insomnia instalado via AUR."
  fi
fi

# ------------------------------------------------------------------------------
# 5. DataGrip (JetBrains Toolbox)
# Toolbox disponível no AUR como 'jetbrains-toolbox'
# É a forma recomendada pela JetBrains no Arch
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox (para gerenciar DataGrip)..."

TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox já está instalado. Pulando..."
else
  # Dependências necessárias
  sudo pacman -S --noconfirm --needed fuse2 libxtst libxi

  # Tenta via AUR (jetbrains-toolbox)
  if install_aur "jetbrains-toolbox"; then
    log "JetBrains Toolbox instalado via AUR."
  else
    # Fallback manual via download direto
    warn "AUR falhou. Baixando JetBrains Toolbox manualmente..."
    TOOLBOX_URL=$(curl -s "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
      | grep -oP '"linux":\{"link":"\K[^"]+' | head -1)

    if [ -z "$TOOLBOX_URL" ]; then
      TOOLBOX_URL="https://download.jetbrains.com/toolbox/jetbrains-toolbox-2.5.2.35332.tar.gz"
    fi

    wget -O /tmp/jetbrains-toolbox.tar.gz "$TOOLBOX_URL"
    tar -xzf /tmp/jetbrains-toolbox.tar.gz -C /tmp/
    TOOLBOX_BIN=$(find /tmp -name "jetbrains-toolbox" -type f | head -1)
    mkdir -p "$TOOLBOX_DIR"
    mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/"
    chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"
    rm -f /tmp/jetbrains-toolbox.tar.gz
    log "JetBrains Toolbox instalado manualmente em $TOOLBOX_DIR"
  fi
fi

warn "Abra o JetBrains Toolbox e instale o DataGrip de lá."
warn "Caso instalado via AUR, execute: jetbrains-toolbox"

# ------------------------------------------------------------------------------
# 6. Docker (repositório oficial Arch — pacote 'docker')
# ------------------------------------------------------------------------------
info "Instalando Docker via repositório oficial Arch..."

if command -v docker &>/dev/null; then
  warn "Docker já está instalado. Pulando..."
else
  sudo pacman -S --noconfirm --needed docker docker-compose

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
echo -e "${GREEN}  Instalação concluída com sucesso! (Arch Linux)${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Node.js:${NC}   $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM:${NC}       $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code:${NC}   $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Docker:${NC}    $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}DataGrip:${NC}  Instale via JetBrains Toolbox"
echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
