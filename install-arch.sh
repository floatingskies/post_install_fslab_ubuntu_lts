#!/bin/bash
# ==============================================================================
# Script de Instalação para Arch Linux e derivados
# Compativel com: Arch Linux, Manjaro, BigLinux, EndeavourOS, Garuda
#
# Ferramentas: NVM + Node.js, VS Code, Insomnia, DataGrip, Docker
#
# Estrategia de fontes:
#   - Pacman (repositorios oficiais) sempre que possivel
#   - AUR via yay para pacotes nao disponiveis nos repos oficiais
#   - yay e instalado automaticamente caso nenhum helper AUR seja encontrado
#   - VS Code: visual-studio-code-bin (AUR) — versao proprietaria completa
#     com suporte ao Marketplace oficial da Microsoft
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${BLUE}[»]${NC} $1"; }
step()    { echo -e "${CYAN}[—]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }

# ------------------------------------------------------------------------------
# Validacoes iniciais
# ------------------------------------------------------------------------------
if [ "$EUID" -eq 0 ]; then
  error "Nao execute este script como root. Use um usuario comum com sudo."
fi

if [ ! -f /etc/os-release ]; then
  error "Nao foi possivel detectar a distribuicao (/etc/os-release ausente)."
fi

. /etc/os-release
DISTRO="${ID:-unknown}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO}"

# Lista de IDs reconhecidos baseados em Arch
ARCH_BASED=("arch" "manjaro" "biglinux" "endeavouros" "garuda" "arcolinux" "artix" "cachyos")
IS_ARCH_BASED=false
for d in "${ARCH_BASED[@]}"; do
  if [[ "$DISTRO" == "$d" ]]; then
    IS_ARCH_BASED=true
    break
  fi
done

# Fallback: verifica ID_LIKE para distros derivadas nao listadas acima
if [[ "$IS_ARCH_BASED" == false && "${ID_LIKE:-}" == *"arch"* ]]; then
  IS_ARCH_BASED=true
fi

if [[ "$IS_ARCH_BASED" == false ]]; then
  error "Distro nao reconhecida como base Arch: $DISTRO_NAME
Distros suportadas: Arch, Manjaro, BigLinux, EndeavourOS, Garuda e derivados."
fi

info "Distro detectada: $DISTRO_NAME"

# ------------------------------------------------------------------------------
# Autenticacao sudo antecipada com keepalive
# Solicita a senha uma unica vez no inicio e renova o cache em background
# durante toda a execucao, evitando timeout em etapas longas (ex: compilacao AUR)
# ------------------------------------------------------------------------------
info "Autenticando sudo..."
sudo -v || error "Falha na autenticacao sudo. Verifique sua senha e tente novamente."

# Renova o cache sudo a cada 60 segundos em background
# O processo e encerrado automaticamente quando o script terminar
(
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done
) &
SUDO_KEEPALIVE_PID=$!

# Garante que o processo keepalive seja encerrado ao sair (sucesso ou erro)
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

log "Sudo autenticado. Cache sera renovado automaticamente."

# ------------------------------------------------------------------------------
# Verifica conexao com a internet antes de comecar
# ------------------------------------------------------------------------------
info "Verificando conexao com a internet..."
if ! curl -fsSL --max-time 10 https://archlinux.org > /dev/null 2>&1; then
  error "Sem conexao com a internet. Verifique sua rede e tente novamente."
fi
log "Conexao OK."

# ------------------------------------------------------------------------------
# Funcao: instala helper AUR (yay)
# Compilado via makepkg — nao requer privilégios root
# ------------------------------------------------------------------------------
install_yay() {
  info "Instalando helper AUR 'yay'..."

  # Dependencias de compilacao
  sudo pacman -S --noconfirm --needed git base-devel go

  local TMP_DIR
  TMP_DIR=$(mktemp -d)

  # Garante limpeza do diretorio temporario ao sair (sucesso ou falha)
  trap "rm -rf '$TMP_DIR'" EXIT

  git clone --depth=1 https://aur.archlinux.org/yay.git "$TMP_DIR/yay"

  # makepkg nao pode ser executado como root
  if [ "$EUID" -eq 0 ]; then
    error "makepkg nao pode ser executado como root."
  fi

  (cd "$TMP_DIR/yay" && makepkg -si --noconfirm --clean)

  # Remove o trap apos conclusao bem-sucedida
  trap - EXIT
  rm -rf "$TMP_DIR"

  if ! command -v yay &>/dev/null; then
    error "Instalacao do yay falhou. Verifique os logs acima."
  fi

  log "yay instalado: $(yay --version | head -1)"
}

# ------------------------------------------------------------------------------
# Funcao: wrapper para instalacao via AUR
# Prioridade: yay > paru > instala yay
# ------------------------------------------------------------------------------
aur_install() {
  local PKG="$1"
  info "Instalando '$PKG' via AUR..."

  if command -v yay &>/dev/null; then
    # --removemake: remove dependencias de build apos compilacao
    # --cleanafter: limpa arquivos de build
    yay -S --noconfirm --needed --removemake --cleanafter "$PKG"
  elif command -v paru &>/dev/null; then
    paru -S --noconfirm --needed "$PKG"
  else
    warn "Nenhum helper AUR encontrado. Instalando yay automaticamente..."
    install_yay
    yay -S --noconfirm --needed --removemake --cleanafter "$PKG"
  fi

  log "'$PKG' instalado via AUR."
}

# ------------------------------------------------------------------------------
# Funcao: tenta instalar via pacman, cai para AUR se nao encontrar
# ------------------------------------------------------------------------------
pacman_or_aur() {
  local PKG="$1"
  local AUR_PKG="${2:-$PKG}"  # pacote AUR pode ter nome diferente

  if sudo pacman -Si "$PKG" &>/dev/null 2>&1; then
    sudo pacman -S --noconfirm --needed "$PKG"
    log "'$PKG' instalado via pacman."
  else
    warn "'$PKG' nao encontrado nos repos oficiais. Usando AUR ($AUR_PKG)..."
    aur_install "$AUR_PKG"
  fi
}

# ------------------------------------------------------------------------------
# Funcao: download seguro do JetBrains Toolbox (fallback manual)
# ------------------------------------------------------------------------------
install_toolbox_manual() {
  local TOOLBOX_DIR="$1"

  info "Baixando JetBrains Toolbox via download direto..."

  local TOOLBOX_URL
  TOOLBOX_URL=$(curl -fsSL \
    "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | grep -oP '"linux":\{"link":"\K[^"]+' \
    | head -1)

  if [ -z "$TOOLBOX_URL" ]; then
    warn "API JetBrains indisponivel. Usando versao fixa..."
    TOOLBOX_URL="https://download.jetbrains.com/toolbox/jetbrains-toolbox-2.5.2.35332.tar.gz"
  fi

  # Diretorio temporario isolado — evita conflito com /tmp do systemd
  local TMP_DIR
  TMP_DIR=$(mktemp -d)
  trap "rm -rf '$TMP_DIR'" EXIT

  wget -O "$TMP_DIR/toolbox.tar.gz" "$TOOLBOX_URL"
  tar -xzf "$TMP_DIR/toolbox.tar.gz" -C "$TMP_DIR/"

  local TOOLBOX_BIN
  TOOLBOX_BIN=$(find "$TMP_DIR" -name "jetbrains-toolbox" -type f | head -1)

  if [ -z "$TOOLBOX_BIN" ]; then
    error "Binario jetbrains-toolbox nao encontrado apos extracao."
  fi

  mkdir -p "$TOOLBOX_DIR"
  mv "$TOOLBOX_BIN" "$TOOLBOX_DIR/jetbrains-toolbox"
  chmod +x "$TOOLBOX_DIR/jetbrains-toolbox"

  trap - EXIT
  rm -rf "$TMP_DIR"

  log "JetBrains Toolbox instalado manualmente em $TOOLBOX_DIR"
}

# ==============================================================================
# INSTALACOES
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Atualiza o sistema
# Manjaro e BigLinux: o --noconfirm pode pedir confirmacao em atualizacoes
# de keyring; --overwrite evita conflitos comuns em mirrors desatualizados
# ------------------------------------------------------------------------------
info "Atualizando o sistema..."

# Atualiza o keyring primeiro para evitar falhas de assinatura GPG
# (problema comum em instalacoes Manjaro/BigLinux desatualizadas)
sudo pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null \
  || sudo pacman -S --noconfirm --needed manjaro-keyring 2>/dev/null \
  || true

sudo pacman -Syu --noconfirm
sudo pacman -S --noconfirm --needed \
  curl wget git \
  base-devel \
  gnupg \
  fuse2 \
  libxtst libxi libxext libxrender \
  unzip tar

log "Sistema atualizado e dependencias base instaladas."

# ------------------------------------------------------------------------------
# 2. NVM + Node.js
# O pacote 'nvm' esta disponivel no AUR do Arch e no repo comunitario do Manjaro
# Prefere o script oficial do NVM por ser mais portatil entre as distros derivadas
# ------------------------------------------------------------------------------
info "Instalando NVM (Node Version Manager)..."
export NVM_DIR="$HOME/.nvm"

if [ -d "$NVM_DIR" ]; then
  warn "NVM ja esta instalado. Pulando..."
else
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# Desabilita nounset (-u) ao carregar e usar o NVM
# O NVM usa variaveis internas nao inicializadas (ex: PROVIDED_VERSION)
# que causam "variavel nao associada" com set -u ativo
set +u

[ -s "$NVM_DIR/nvm.sh" ]          && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

if ! command -v nvm &>/dev/null; then
  set -u
  error "NVM nao foi carregado corretamente. Verifique sua conexao e tente novamente."
fi

info "Instalando Node.js LTS..."
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'

# Reativa nounset apos uso do NVM
set -u

log "Node.js $(node -v) | NPM $(npm -v)"

# Persiste NVM no bashrc e zshrc
NVM_BLOCK='# NVM — Node Version Manager
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

grep -qF 'NVM_DIR' ~/.bashrc \
  || printf "\n%s\n" "$NVM_BLOCK" >> ~/.bashrc

[ -f ~/.zshrc ] && grep -qF 'NVM_DIR' ~/.zshrc \
  || { [ -f ~/.zshrc ] && printf "\n%s\n" "$NVM_BLOCK" >> ~/.zshrc; }

log "NVM configurado no shell."

# ------------------------------------------------------------------------------
# 3. VS Code — visual-studio-code-bin (AUR)
# Motivo: a versao 'code' dos repos oficiais e o build open-source (VSCodium),
# que nao inclui as extensoes proprietarias da Microsoft nem o Marketplace oficial.
# Para o fluxo de desenvolvimento do FSLab, a versao binaria proprietaria
# (visual-studio-code-bin) e necessaria para acesso completo ao Marketplace.
# ------------------------------------------------------------------------------
info "Instalando Visual Studio Code (versao proprietaria via AUR)..."

if command -v code &>/dev/null; then
  # Verifica se e o build correto (proprietario) ou o OSS
  if code --version 2>/dev/null | grep -q "microsoft"; then
    warn "VS Code (Microsoft) ja esta instalado. Pulando..."
  else
    warn "Detectado VS Code OSS. Substituindo pela versao proprietaria..."
    sudo pacman -Rns --noconfirm code 2>/dev/null || true
    aur_install "visual-studio-code-bin"
  fi
else
  aur_install "visual-studio-code-bin"
fi

log "VS Code instalado: $(code --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------------------
# 4. Insomnia
# Disponivel nos repos do Manjaro (extra) e no AUR para Arch puro
# ------------------------------------------------------------------------------
info "Instalando Insomnia..."

if command -v insomnia &>/dev/null; then
  warn "Insomnia ja esta instalado. Pulando..."
else
  # Tenta pacman primeiro (Manjaro/BigLinux tem nos repos)
  if sudo pacman -Si insomnia &>/dev/null 2>&1; then
    sudo pacman -S --noconfirm --needed insomnia
    log "Insomnia instalado via pacman."
  else
    # AUR: insomnia-bin e mais rapido que compilar do fonte
    aur_install "insomnia-bin"
  fi
fi

# ------------------------------------------------------------------------------
# 5. DataGrip via JetBrains Toolbox
# jetbrains-toolbox esta no AUR e e a forma recomendada pela JetBrains no Arch
# Fallback: download direto via API JetBrains
# ------------------------------------------------------------------------------
info "Instalando JetBrains Toolbox..."

TOOLBOX_DIR="$HOME/.local/share/JetBrains/Toolbox/bin"

if [ -f "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
  warn "JetBrains Toolbox ja esta instalado. Pulando..."
else
  # Tenta via AUR primeiro
  if aur_install "jetbrains-toolbox" 2>/dev/null; then
    # O pacote AUR instala o binario no PATH padrao
    # Cria o link no diretorio esperado para consistencia entre distros
    TOOLBOX_BIN_PATH=$(command -v jetbrains-toolbox 2>/dev/null || true)
    if [ -n "$TOOLBOX_BIN_PATH" ] && [ "$TOOLBOX_BIN_PATH" != "$TOOLBOX_DIR/jetbrains-toolbox" ]; then
      mkdir -p "$TOOLBOX_DIR"
      ln -sf "$TOOLBOX_BIN_PATH" "$TOOLBOX_DIR/jetbrains-toolbox"
    fi
    log "JetBrains Toolbox instalado via AUR."
  else
    warn "AUR falhou para jetbrains-toolbox. Usando download direto..."
    install_toolbox_manual "$TOOLBOX_DIR"
  fi
fi

log "JetBrains Toolbox disponivel."
warn "Abra o Toolbox e instale o DataGrip pela interface grafica."
warn "Executavel: ${TOOLBOX_DIR}/jetbrains-toolbox"

# ------------------------------------------------------------------------------
# 6. Docker
# Pacote oficial 'docker' do repositorio extra do Arch
# docker-compose v2 esta incluido como plugin (docker compose)
# ------------------------------------------------------------------------------
info "Instalando Docker..."

if command -v docker &>/dev/null; then
  warn "Docker ja esta instalado. Pulando..."
else
  sudo pacman -S --noconfirm --needed docker docker-compose docker-buildx

  sudo usermod -aG docker "$USER"
  sudo systemctl enable docker.service
  sudo systemctl enable containerd.service
  sudo systemctl start docker.service
fi

# Valida que o daemon esta rodando
if ! sudo systemctl is-active --quiet docker; then
  warn "Docker instalado mas o servico nao iniciou. Tente: sudo systemctl start docker"
else
  log "Docker instalado e rodando: $(docker --version)"
fi

warn "Faca logout e login para ativar as permissoes do grupo 'docker'."

# ==============================================================================
# Resumo final
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Instalacao concluida!  ($DISTRO_NAME)${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Node.js :${NC}  $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM     :${NC}  $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code :${NC}  $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Insomnia:${NC}  $(command -v insomnia &>/dev/null && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}Docker  :${NC}  $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}DataGrip:${NC}  Instale via JetBrains Toolbox"
echo ""
warn "Reinicie o terminal ou execute: source ~/.bashrc"
warn "Faca logout e login para ativar as permissoes do grupo 'docker'."
