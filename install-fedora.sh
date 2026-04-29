#!/bin/bash
# ==============================================================================
# Script de Instalação para Fedora (42, 43, 44)
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
# Sem Snap ou Flatpak
# ==============================================================================

set -e
# Interceptor de erro que mostra a linha exata antes de fechar
trap 'echo -e "\n${RED}[✘ FATAL] O script parou na linha $LINENO — comando: ${BASH_COMMAND}${NC}\n" >&2; exit 1' ERR

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
info()  { echo -e "${BLUE}[»]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 0. Validações iniciais
# ------------------------------------------------------------------------------
if [ "$EUID" -eq 0 ]; then
  error "Não execute este script como root. Use um usuário comum com sudo."
fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
  DISTRO_VERSION=$VERSION_ID
else
  error "Não foi possível detectar a distribuição."
fi

if [[ "$DISTRO" != "fedora" ]]; then
  error "Este script é para Fedora. Distro detectada: $DISTRO"
fi

if (( DISTRO_VERSION < 42 )); then
  error "Este script requer Fedora 42+. Versão detectada: $DISTRO_VERSION"
fi

info "Distro detectada: $PRETTY_NAME"

# Detecta se estamos sob dnf5 (padrão no Fedora 41+)
DNF_BIN="dnf"
if dnf --version 2>/dev/null | head -1 | grep -q "dnf5"; then
  DNF5=true
  info "DNF5 detectado."
else
  DNF5=false
fi

# ------------------------------------------------------------------------------
# 1. Atualiza o sistema e instala dependências base
# ------------------------------------------------------------------------------
info "Atualizando pacotes do sistema..."
sudo "$DNF_BIN" upgrade --refresh -y

sudo "$DNF_BIN" install -y \
  curl wget git gcc make ca-certificates gnupg \
  dnf-plugins-core unzip jq

log "Dependências base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js
# ------------------------------------------------------------------------------
info "Instalando NVM (Node Version Manager)..."
export NVM_DIR="$HOME/.nvm"
NVM_VERSION="0.40.1"

if [ -d "$NVM_DIR" ]; then
  warn "NVM já está instalado. Pulando..."
else
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
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

if ! grep -q 'NVM_DIR="$HOME/.nvm"' ~/.bashrc 2>/dev/null; then
  echo -e "\n# NVM\n$NVM_INIT" >> ~/.bashrc
fi

if [ -f ~/.zshrc ] && ! grep -q 'NVM_DIR="$HOME/.nvm"' ~/.zshrc 2>/dev/null; then
  echo -e "\n# NVM\n$NVM_INIT" >> ~/.zshrc
fi

log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code..."

if command -v code &>/dev/null; then
  warn "VS Code já está instalado. Pulando..."
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
log "VS Code instalado."

# ------------------------------------------------------------------------------
# 4. Insomnia
# ------------------------------------------------------------------------------
info "Instalando Insomnia..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia já está instalado. Pulando..."
else
  INSOMNIA_URL=$(curl -sL https://api.github.com/repos/Kong/insomnia/releases/latest \
    | jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' 2>/dev/null \
    | head -1)

  if [ -z "$INSOMNIA_URL" ]; then
    INSOMNIA_TAG=$(curl -sL https://api.github.com/repos/Kong/insomnia/releases/latest | jq -r '.tag_name')
    INSOMNIA_VER="${INSOMNIA_TAG#core@}"
    INSOMNIA_URL="https://github.com/Kong/insomnia/releases/download/${INSOMNIA_TAG}/Insomnia.Core-${INSOMNIA_VER}.rpm"
  fi

  if [ -z "$INSOMNIA_URL" ]; then
    error "Não foi possível obter a URL do Insomnia."
  fi

  info "Baixando Insomnia de: $INSOMNIA_URL"
  wget -O /tmp/insomnia.rpm "$INSOMNIA_URL"
  sudo "$DNF_BIN" install -y /tmp/insomnia.rpm
  rm -f /tmp/insomnia.rpm
  log "Insomnia instalado."
fi

# ------------------------------------------------------------------------------
# 5. DataGrip (JetBrains Toolbox)
# ATENÇÃO: Este bloco NÃO vai fechar o script se falhar. Ele apenas avisa.
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."

TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"
TOOLBOX_INSTALLED=false

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox já está instalado. Pulando..."
  TOOLBOX_INSTALLED=true
else
  # Desativa o set -e temporariamente para garantir que o script continue para o Docker
  set +e
  
  sudo "$DNF_BIN" install -y fuse fuse-libs libXtst libX11 libXext libXrender libXi

  TOOLBOX_URL=$(curl -sL "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | jq -r '.TBA[0].downloads.linux.link // empty' 2>/dev/null)

  if [ -z "$TOOLBOX_URL" ]; then
    TOOLBOX_URL=$(curl -sL "https://www.jetbrains.com/toolbox-app/download/" \
      | grep -oP 'https://download\.jetbrains\.com/toolbox/jetbrains-toolbox-[^"]+\.tar\.gz' \
      | head -1)
  fi

  if [ -n "$TOOLBOX_URL" ]; then
    info "Baixando Toolbox de: $TOOLBOX_URL"
    TMPDIR_TOOLBOX=$(mktemp -d)
    wget -qO "$TMPDIR_TOOLBOX/toolbox.tar.gz" "$TOOLBOX_URL"
    
    # Verifica se o arquivo baixado é válido (maior que 5MB)
    FILESIZE=$(stat -c%s "$TMPDIR_TOOLBOX/toolbox.tar.gz" 2>/dev/null || echo 0)
    
    if (( FILESIZE > 5000000 )); then
      tar -xzf "$TMPDIR_TOOLBOX/toolbox.tar.gz" -C "$TMPDIR_TOOLBOX/" 2>/dev/null
      
      # -print -quit evita que o pipe quebre com SIGPIPE
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
  
  # Reativa o set -e
  set -e
fi

if [ "$TOOLBOX_INSTALLED" = true ]; then
  log "JetBrains Toolbox instalado em $TOOLBOX_DIR"
  warn "Ao abrir o Toolbox pela PRIMEIRA VEZ, ele criará o ícone no menu de aplicativos."
  warn "Após abri-lo, use-o para instalar o DataGrip."
else
  warn "============================================================="
  warn "NÃO FOI POSSÍVEL INSTALAR O JETBRAINS TOOLBOX AUTOMATICAMENTE."
  warn "A API da JetBrains é instável e bloqueou/ignorou o download."
  warn "============================================================="
  warn "Instale manualmente acessando: https://www.jetbrains.com/toolbox-app/"
  warn "O script vai continuar para instalar o Docker..."
fi

# ------------------------------------------------------------------------------
# 6. Docker CE
# ------------------------------------------------------------------------------
info "Instalando Docker CE..."

if command -v docker &>/dev/null; then
  warn "Docker já está instalado. Pulando..."
else
  sudo "$DNF_BIN" remove -y \
    docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine podman-docker 2>/dev/null || true

  if sudo "$DNF_BIN" config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null; then
    info "Repositório Docker adicionado via dnf5."
  else
    warn "Fallback: adicionando repositório Docker via sintaxe antiga..."
    sudo "$DNF_BIN" config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  fi

  sudo "$DNF_BIN" install -y --allowerasure \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
fi

log "Docker $(docker --version) instalado e habilitado."
warn "Faça logout e login para que as permissões do grupo 'docker' tenham efeito."

# ------------------------------------------------------------------------------
# Resumo final
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

if [ "$TOOLBOX_INSTALLED" = true ]; then
  echo -e "  ${BLUE}DataGrip:${NC}  Abra o Toolbox para instalar: $TOOLBOX_DIR/jetbrains-toolbox"
else
  echo -e "  ${YELLOW}DataGrip:${NC}  Requer instalação manual do Toolbox (link acima)"
fi

echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
