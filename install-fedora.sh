#!/bin/bash
# ==============================================================================
# Script de Instalação para Fedora (42, 43, 44)
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
# ==============================================================================

set -e
trap 'echo -e "\n${RED}[✘ FATAL] O script parou na linha $LINENO — comando: ${BASH_COMMAND}${NC}\n" >&2; exit 1' ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
info()  { echo -e "${BLUE}[»]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1" >&2; exit 1; }

if [ "$EUID" -eq 0 ]; then error "Não execute como root."; fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
  DISTRO_VERSION=$VERSION_ID
else
  error "Não foi possível detectar a distribuição."
fi

if [[ "$DISTRO" != "fedora" ]]; then error "Este script é para Fedora."; fi
if (( DISTRO_VERSION < 42 )); then error "Requer Fedora 42+."; fi

info "Distro detectada: $PRETTY_NAME"
DNF_BIN="dnf"

# ------------------------------------------------------------------------------
# 1. Atualiza o sistema
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo "$DNF_BIN" upgrade --refresh -y
sudo "$DNF_BIN" install -y curl wget git gcc make ca-certificates gnupg dnf-plugins-core unzip jq
log "Dependências base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js
# ------------------------------------------------------------------------------
info "Instalando NVM..."
export NVM_DIR="$HOME/.nvm"
if [ -d "$NVM_DIR" ]; then warn "NVM já instalado. Pulando..."; else curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash; fi

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

nvm install --lts
nvm use --lts
nvm alias default 'lts/*'
log "Node.js $(node -v) instalado."

NVM_INIT='export NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
if ! grep -q 'NVM_DIR="$HOME/.nvm"' ~/.bashrc 2>/dev/null; then echo -e "\n# NVM\n$NVM_INIT" >> ~/.bashrc; fi
if [ -f ~/.zshrc ] && ! grep -q 'NVM_DIR="$HOME/.nvm"' ~/.zshrc 2>/dev/null; then echo -e "\n# NVM\n$NVM_INIT" >> ~/.zshrc; fi

# ------------------------------------------------------------------------------
# 3. VS Code
# ------------------------------------------------------------------------------
info "Instalando VS Code..."
if command -v code &>/dev/null; then warn "VS Code já instalado. Pulando..."; else
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
log "VS Code instalado."

# ------------------------------------------------------------------------------
# 4. Insomnia
# ------------------------------------------------------------------------------
info "Instalando Insomnia..."
if command -v insomnia &>/dev/null; then warn "Insomnia já instalado. Pulando..."; else
  INSOMNIA_URL=$(curl -sL https://api.github.com/repos/Kong/insomnia/releases/latest | jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' 2>/dev/null | head -1)
  if [ -z "$INSOMNIA_URL" ]; then
    INSOMNIA_TAG=$(curl -sL https://api.github.com/repos/Kong/insomnia/releases/latest | jq -r '.tag_name')
    INSOMNIA_URL="https://github.com/Kong/insomnia/releases/download/${INSOMNIA_TAG}/Insomnia.Core-${INSOMNIA_TAG#core@}.rpm"
  fi
  wget -O /tmp/insomnia.rpm "$INSOMNIA_URL"
  sudo "$DNF_BIN" install -y /tmp/insomnia.rpm
  rm -f /tmp/insomnia.rpm
  log "Insomnia instalado."
fi

# ------------------------------------------------------------------------------
# 5. JetBrains Toolbox (Protegido para não travar o resto do script)
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."
TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"
TOOLBOX_INSTALLED=false

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox já instalado. Pulando..."
  TOOLBOX_INSTALLED=true
else
  set +e # Desliga falha automática aqui
  sudo "$DNF_BIN" install -y fuse fuse-libs libXtst libX11 libXext libXrender libXi
  
  TOOLBOX_URL=$(curl -sL "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" | jq -r '.TBA[0].downloads.linux.link // empty' 2>/dev/null)
  if [ -z "$TOOLBOX_URL" ]; then
    TOOLBOX_URL=$(curl -sL "https://www.jetbrains.com/toolbox-app/download/" | grep -oP 'https://download\.jetbrains\.com/toolbox/jetbrains-toolbox-[^"]+\.tar\.gz' | head -1)
  fi

  if [ -n "$TOOLBOX_URL" ]; then
    TMPDIR_TOOLBOX=$(mktemp -d)
    wget -qO "$TMPDIR_TOOLBOX/toolbox.tar.gz" "$TOOLBOX_URL"
    FILESIZE=$(stat -c%s "$TMPDIR_TOOLBOX/toolbox.tar.gz" 2>/dev/null || echo 0)
    
    if (( FILESIZE > 5000000 )); then
      tar -xzf "$TMPDIR_TOOLBOX/toolbox.tar.gz" -C "$TMPDIR_TOOLBOX/" 2>/dev/null
      TOOLBOX_BIN=$(find "$TMPDIR_TOOLBOX" -name "jetbrains-toolbox" -type f -print -quit 2>/dev/null)
      if [ -n "$TOOLBOX_BIN" ] && [ -s "$TOOLBOX_BIN" ]; then
        mkdir -p "$TOOLBOX_DIR"
        mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/"
        chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"
        TOOLBOX_INSTALLED=true
      fi
    fi
    rm -rf "$TMPDIR_TOOLBOX"
  fi
  set -e # Reativa falha automática
fi

if [ "$TOOLBOX_INSTALLED" = true ]; then
  log "JetBrains Toolbox instalado em $TOOLBOX_DIR"
else
  warn "============================================================="
  warn "FALHA AO INSTALAR O JETBRAINS TOOLBOX (API bloqueou/ignorou)."
  warn "============================================================="
  warn "Instale manualmente em: https://www.jetbrains.com/toolbox-app/"
fi

# ------------------------------------------------------------------------------
# 6. Docker CE
# ------------------------------------------------------------------------------
info "Instalando Docker CE..."
if command -v docker &>/dev/null; then
  warn "Docker já instalado. Pulando..."
else
  sudo "$DNF_BIN" remove -y docker docker-client docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine podman-docker 2>/dev/null || true

  # Solução definitiva: baixar o .repo direto, evita bug do config-manager no DNF5
  info "Adicionando repositório oficial do Docker..."
  curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo -o /tmp/docker-ce.repo
  sudo mv /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo

  sudo "$DNF_BIN" install -y --allowerasure docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
fi
log "Docker $(docker --version) instalado e habilitado."

# ------------------------------------------------------------------------------
# Resumo
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Instalação concluída! (${PRETTY_NAME})${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Node.js:${NC}   $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM:${NC}       $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code:${NC}   $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Docker:${NC}    $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
[ "$TOOLBOX_INSTALLED" = true ] && echo -e "  ${BLUE}DataGrip:${NC}  Instale via Toolbox" || echo -e "  ${YELLOW}DataGrip:${NC}  Requer instalação manual do Toolbox"
echo ""
warn "Reinicie o terminal (source ~/.bashrc) e faça logout/login para o Docker."
