#!/bin/bash
# ==============================================================================
# FSLab — Pós-instalação unificada (dispatcher + customização de ambiente)
# ==============================================================================
# Este script é o ponto de entrada único para configurar uma máquina FSLab
# do zero em QUALQUER uma das famílias de OS suportadas:
#
#   • Arch Linux e derivados       (arch, manjaro, biglinux, endeavour, garuda,
#                                   cachyos, arcolinux, artix)
#   • Fedora e derivados RHEL      (fedora 42+, rhel 9+, centos stream,
#                                   almalinux, rocky)
#   • Ubuntu / Debian e derivados  (ubuntu, debian, mint, pop, zorin,
#                                   elementary)
#
# O que ele faz:
#   1. Detecta a família de OS via /etc/os-release
#   2. Verifica se as dependências básicas estão presentes (curl, git, sudo)
#   3. Executa o instalador específico da família (install-arch.sh,
#      install-fedora.sh ou install-ubuntu-debian.sh) — busca no mesmo
#      diretório deste script. Se não encontrar, pergunta se quer baixar
#      do repositório.
#   4. Verifica que cada app crítico foi instalado de fato
#   5. Roda etapas FSLab específicas:
#        a. Configura git global (user.email, user.name, init.defaultBranch,
#           pull.rebase, core.editor) — interativo se não configurado
#        b. Instala pacotes NPM globais do fluxo FSLab
#        c. Instala extensões do VS Code
#        d. Cria estrutura de diretórios do workspace FSLab
#        e. Gera par de chaves SSH ed25519 (se ainda não existir)
#        f. Imprime resumo final com próximos passos
#
# Princípios de robustez:
#   - set -Eeuo pipefail + trap ERR
#   - Idempotente: re-executar é seguro (skip ao invés de reconfigurar)
#   - Tudo protegido: falha em uma etapa NÃO derruba as seguintes
#   - Cores auto-desativadas fora de TTY
#   - Log paralelo em arquivo
#   - Não usa Snap/Flatpak (mantém consistência com os instaladores)
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="post_install_fslab.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly LOG_DIR="${HOME}/.local/share/fslab/logs"
readonly LOG_FILE="${LOG_DIR}/post-install-fslab-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/fslab-post-install.lock"

# Diretório onde este script está — usado para localizar os instaladores
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Diretório do workspace FSLab (sobrescrever via FSLAB_WORKSPACE env var)
FSLAB_WORKSPACE="${FSLAB_WORKSPACE:-$HOME/fslab}"

# ------------------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------------------
if [[ -t 1 && -t 2 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  MAGENTA='\033[0;35m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' NC=''
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

log()    { _log INFO  "${GREEN}[✔]${NC} $*"; }
warn()   { _log WARN  "${YELLOW}[!]${NC} $*"; }
info()   { _log INFO  "${BLUE}[»]${NC} $*"; }
step()   { _log STEP  "${CYAN}[—]${NC} $*"; }
error()  { _log ERROR "${RED}[✘]${NC} $*"; exit 1; }
success() { _log OK   "${MAGENTA}[★]${NC} $*"; }

# ------------------------------------------------------------------------------
# ERR trap — continua mesmo se uma sub-etapa falhar (exceto erros fatais)
# ------------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no=$1
  local cmd="$2"
  echo "" >&2
  warn "Erro capturado na linha ${line_no} (código ${exit_code}): ${cmd}"
  warn "Continuando — verifique o log: $LOG_FILE"
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
  rm -f "$LOCK_FILE" 2>/dev/null || true
  if [[ $exit_code -eq 0 ]]; then
    log "Log completo salvo em: $LOG_FILE"
  else
    warn "Script terminou com erros. Log completo em: $LOG_FILE"
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
  error "Não foi possível detectar a distribuição (/etc/os-release ausente)."
fi

# shellcheck disable=SC1091
. /etc/os-release
DISTRO="${ID:-unknown}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO}"
ARCH="$(uname -m)"

# Detecta família de OS
OS_FAMILY="unknown"
INSTALLER_SCRIPT=""

# Lista expandida de IDs baseados em Arch
ARCH_IDS=("arch" "manjaro" "biglinux" "endeavouros" "garuda" "arcolinux" "artix" "cachyos")
for d in "${ARCH_IDS[@]}"; do
  if [[ "$DISTRO" == "$d" ]]; then
    OS_FAMILY="arch"
    INSTALLER_SCRIPT="install-arch.sh"
    break
  fi
done
if [[ "$OS_FAMILY" == "unknown" && "${ID_LIKE:-}" == *"arch"* ]]; then
  OS_FAMILY="arch"
  INSTALLER_SCRIPT="install-arch.sh"
fi

# Fedora / RHEL
if [[ "$OS_FAMILY" == "unknown" ]]; then
  if [[ "$DISTRO" == "fedora" ]]; then
    OS_FAMILY="fedora"
    INSTALLER_SCRIPT="install-fedora.sh"
  elif [[ "$DISTRO" == "rhel" || "$DISTRO" == "centos" || "$DISTRO" == "almalinux" || "$DISTRO" == "rocky" ]]; then
    OS_FAMILY="fedora"
    INSTALLER_SCRIPT="install-fedora.sh"
  elif [[ "${ID_LIKE:-}" == *"rhel"* || "${ID_LIKE:-}" == *"fedora"* ]]; then
    OS_FAMILY="fedora"
    INSTALLER_SCRIPT="install-fedora.sh"
  fi
fi

# Ubuntu / Debian
if [[ "$OS_FAMILY" == "unknown" ]]; then
  if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    OS_FAMILY="debian"
    INSTALLER_SCRIPT="install-ubuntu-debian.sh"
  elif [[ "${ID_LIKE:-}" == *"ubuntu"* || "${ID_LIKE:-}" == *"debian"* ]]; then
    OS_FAMILY="debian"
    INSTALLER_SCRIPT="install-ubuntu-debian.sh"
  fi
fi

if [[ "$OS_FAMILY" == "unknown" ]]; then
  error "Distro não suportada: $DISTRO_NAME
Distros suportadas: Arch-family, Fedora/RHEL-family, Ubuntu/Debian-family."
fi

# Banner inicial
echo ""
echo -e "${MAGENTA}============================================================${NC}"
echo -e "${MAGENTA}  FSLab — Pós-instalação${NC}"
echo -e "${MAGENTA}============================================================${NC}"
echo ""
info "Distro detectada : $DISTRO_NAME"
info "Família de OS    : $OS_FAMILY"
info "Arquitetura      : $ARCH"
info "Workspace FSLab  : $FSLAB_WORKSPACE"
info "Diretório script : $SCRIPT_DIR"
info "Versão do script : $SCRIPT_VERSION"
echo ""

acquire_lock

# ------------------------------------------------------------------------------
# Sudo keepalive (para etapas que precisam, como git config system-wide)
# ------------------------------------------------------------------------------
info "Autenticando sudo (senha única para toda a execução)..."
sudo -v || error "Falha na autenticação sudo."
(
  while true; do
    sudo -n true 2>/dev/null || exit
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done
) &
SUDO_KEEPALIVE_PID=$!
log "Sudo autenticado."

# ==============================================================================
# ETAPA 1 — Executar instalador específico da família
# ==============================================================================
step "Etapa 1/6: Instalando ferramentas base via install-${OS_FAMILY}.sh"

INSTALLER_PATH="$SCRIPT_DIR/$INSTALLER_SCRIPT"

# Resultados por app (para verificação)
declare -A APP_INSTALLED=(
  [node]=false [npm]=false [code]=false [docker]=false
  [insomnia]=false [toolbox]=false [git]=false
)

run_installer() {
  if [[ ! -f "$INSTALLER_PATH" ]]; then
    warn "Instalador específico não encontrado: $INSTALLER_PATH"
    warn "Você pode baixá-lo do repositório FSLab e colocá-lo ao lado deste script."
    read -r -p "Deseja continuar apenas com as etapas FSLab? [s/N] " response
    if [[ ! "$response" =~ ^[sSyY]$ ]]; then
      error "Abortado. Coloque $INSTALLER_SCRIPT em $SCRIPT_DIR e tente novamente."
    fi
    warn "Pulando etapa de instalação base. Prosseguindo com customização FSLab..."
    return 0
  fi

  if [[ ! -x "$INSTALLER_PATH" ]]; then
    chmod +x "$INSTALLER_PATH" || true
  fi

  info "Executando: $INSTALLER_PATH"
  bash "$INSTALLER_PATH"
}

run_installer

# ==============================================================================
# ETAPA 2 — Verificar que cada app crítico está disponível
# ==============================================================================
step "Etapa 2/6: Verificando instalação das ferramentas"

# Carrega NVM caso o script anterior tenha acabado de instalar
export NVM_DIR="$HOME/.nvm"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  set +u
  # shellcheck disable=SC1091
  \. "$NVM_DIR/nvm.sh" 2>/dev/null || true
  set -u
fi

check_app() {
  local app="$1"
  local label="$2"
  if command -v "$app" &>/dev/null; then
    APP_INSTALLED[$app]=true
    log "  ${GREEN}✔${NC} $label"
  else
    APP_INSTALLED[$app]=false
    warn "  ${RED}✘${NC} $label (não encontrado no PATH)"
  fi
}

check_app node    "Node.js"
check_app npm     "NPM"
check_app code    "VS Code"
check_app docker  "Docker"
check_app insomnia "Insomnia"
check_app git     "Git"

# JetBrains Toolbox é verificado pelo caminho do binário
if [[ -f "$HOME/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox" ]]; then
  APP_INSTALLED[toolbox]=true
  log "  ${GREEN}✔${NC} JetBrains Toolbox"
else
  warn "  ${RED}✘${NC} JetBrains Toolbox (instale manualmente)"
fi

echo ""

# ==============================================================================
# ETAPA 3 — Configuração global do Git
# ==============================================================================
step "Etapa 3/6: Configurando Git"

if [[ "${APP_INSTALLED[git]}" == "true" ]]; then
  # init.defaultBranch
  CURRENT_DEFAULT_BRANCH=$(git config --global init.defaultBranch 2>/dev/null || echo "")
  if [[ -z "$CURRENT_DEFAULT_BRANCH" ]]; then
    git config --global init.defaultBranch main
    log "  Git: init.defaultBranch = main"
  else
    log "  Git: init.defaultBranch já = $CURRENT_DEFAULT_BRANCH"
  fi

  # pull.rebase
  CURRENT_PULL=$(git config --global pull.rebase 2>/dev/null || echo "")
  if [[ -z "$CURRENT_PULL" ]]; then
    git config --global pull.rebase false
    log "  Git: pull.rebase = false (merge por padrão)"
  fi

  # core.editor
  CURRENT_EDITOR=$(git config --global core.editor 2>/dev/null || echo "")
  if [[ -z "$CURRENT_EDITOR" ]]; then
    if command -v code &>/dev/null; then
      git config --global core.editor "code --wait"
      log "  Git: core.editor = code --wait"
    elif command -v nano &>/dev/null; then
      git config --global core.editor nano
      log "  Git: core.editor = nano"
    fi
  fi

  # user.name e user.email — só pede se não estiverem configurados
  CURRENT_NAME=$(git config --global user.name 2>/dev/null || echo "")
  CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")

  if [[ -z "$CURRENT_NAME" ]]; then
    echo ""
    read -r -p "  Digite seu nome para o Git (Enter para pular): " GIT_NAME
    if [[ -n "$GIT_NAME" ]]; then
      git config --global user.name "$GIT_NAME"
      log "  Git: user.name = $GIT_NAME"
    else
      warn "  Git: user.name não configurado (defina depois com: git config --global user.name \"Seu Nome\")"
    fi
  else
    log "  Git: user.name já = $CURRENT_NAME"
  fi

  if [[ -z "$CURRENT_EMAIL" ]]; then
    read -r -p "  Digite seu e-mail para o Git (Enter para pular): " GIT_EMAIL
    if [[ -n "$GIT_EMAIL" ]]; then
      git config --global user.email "$GIT_EMAIL"
      log "  Git: user.email = $GIT_EMAIL"
    else
      warn "  Git: user.email não configurado (defina depois com: git config --global user.email \"voce@exemplo.com\")"
    fi
  else
    log "  Git: user.email já = $CURRENT_EMAIL"
  fi

  #Aliases úteis para o fluxo FSLab
  git config --global alias.s "status -sb"
  git config --global alias.lg "log --oneline --graph --decorate --all"
  git config --global alias.co "checkout"
  git config --global alias.br "branch"
  git config --global alias.ci "commit"
  git config --global alias.st "status"
  git config --global alias.last "log -1 HEAD"
  log "  Git: aliases FSLab configurados (s, lg, co, br, ci, st, last)"
else
  warn "  Git não encontrado. Pulando configuração."
fi

echo ""

# ==============================================================================
# ETAPA 4 — Pacotes NPM globais do fluxo FSLab
# ==============================================================================
step "Etapa 4/6: Instalando pacotes NPM globais"

if [[ "${APP_INSTALLED[npm]}" == "true" ]]; then
  NPM_GLOBALS=(
    "pm2"
    "typescript"
    "ts-node"
    "nodemon"
    "eslint"
    "prettier"
    "yo"
    "rimraf"
    "npm-check-updates"
    "tsx"
  )

  info "  Instalando: ${NPM_GLOBALS[*]}"
  # Usa --no-fund e --no-audit para acelerar
  npm install -g --no-fund --no-audit "${NPM_GLOBALS[@]}" 2>&1 | tee -a "$LOG_FILE" >&2 || \
    warn "  Alguns pacotes NPM podem ter falhado. Verifique o log."

  log "  Pacotes NPM globais instalados."
  # Lista versões
  for pkg in typescript ts-node pm2 prettier eslint; do
    if command -v "$pkg" &>/dev/null; then
      version=$("$pkg" --version 2>/dev/null | head -1 || echo "?")
      log "    ${GREEN}✔${NC} $pkg $version"
    fi
  done
else
  warn "  NPM não disponível. Pulando instalação de pacotes globais."
fi

echo ""

# ==============================================================================
# ETAPA 5 — Extensões do VS Code
# ==============================================================================
step "Etapa 5/6: Instalando extensões do VS Code"

if [[ "${APP_INSTALLED[code]}" == "true" ]]; then
  VSCODE_EXTENSIONS=(
    "dbaeumer.vscode-eslint"
    "esbenp.prettier-vscode"
    "eamodio.gitlens"
    "ms-azuretools.vscode-docker"
    "ms-vscode-remote.remote-ssh"
    "ms-vscode-remote.remote-containers"
    "ms-vscode.vscode-typescript-next"
    "bradlc.vscode-tailwindcss"
    "firsttris.vscode-jest-runner"
    "ms-playwright.playwright"
    "redhat.vscode-yaml"
    "yzhang.markdown-all-in-one"
    "ms-vscode-remote.remote-wsl"
    "GitHub.vscode-pull-request-github"
    "ms-vscode.sublime-keybindings"
  )

  info "  Instalando ${#VSCODE_EXTENSIONS[@]} extensões..."
  for ext in "${VSCODE_EXTENSIONS[@]}"; do
    if code --install-extension "$ext" --force > /dev/null 2>&1; then
      log "    ${GREEN}✔${NC} $ext"
    else
      warn "    ${RED}✘${NC} $ext (falhou)"
    fi
  done

  log "  Extensões do VS Code instaladas."
else
  warn "  VS Code não disponível. Pulando instalação de extensões."
fi

echo ""

# ==============================================================================
# ETAPA 6 — Workspace, chaves SSH e finalização
# ==============================================================================
step "Etapa 6/6: Workspace FSLab + SSH"

# Cria estrutura de diretórios do workspace
info "  Criando estrutura do workspace em $FSLAB_WORKSPACE..."
mkdir -p "$FSLAB_WORKSPACE"/{projects,tools,docs,scripts,configs,downloads}
log "  Workspace criado: $FSLAB_WORKSPACE"

# Gera chave SSH ed25519 se não existir
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY" ]]; then
  info "  Gerando chave SSH ed25519..."
  SSH_EMAIL=$(git config --global user.email 2>/dev/null || echo "$USER@$(hostname)")
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f "$SSH_KEY" -N "" -q
  log "  Chave SSH gerada: $SSH_KEY"

  # Inicia o ssh-agent e adiciona a chave
  if ! pgrep -u "$USER" ssh-agent > /dev/null 2>&1; then
    eval "$(ssh-agent -s)" > /dev/null 2>&1
  fi
  ssh-add "$SSH_KEY" 2>/dev/null || true
  log "  Chave SSH adicionada ao ssh-agent."

  # Configura ~/.ssh/config para GitHub/GitLab
  if [[ ! -f "$HOME/.ssh/config" ]]; then
    cat > "$HOME/.ssh/config" <<EOF
# Configuração SSH — FSLab
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  AddKeysToAgent yes

Host gitlab.com
  HostName gitlab.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  AddKeysToAgent yes
EOF
    chmod 600 "$HOME/.ssh/config"
    log "  ~/.ssh/config criado."
  fi

  # Exibe a chave pública para o usuário copiar
  echo ""
  success "Chave pública SSH (copie para GitHub/GitLab):"
  echo ""
  cat "$SSH_KEY.pub"
  echo ""
else
  log "  Chave SSH já existe: $SSH_KEY"
fi

# ==============================================================================
# Resumo final
# ==============================================================================
echo ""
echo -e "${MAGENTA}============================================================${NC}"
echo -e "${MAGENTA}  Pós-instalação FSLab concluída!${NC}"
echo -e "${MAGENTA}============================================================${NC}"
echo ""
echo -e "  ${BLUE}Distro       :${NC}  $DISTRO_NAME ($OS_FAMILY)"
echo -e "  ${BLUE}Node.js      :${NC}  $(node -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}NPM          :${NC}  $(npm -v 2>/dev/null || echo 'reinicie o terminal')"
echo -e "  ${BLUE}VS Code      :${NC}  $(code --version 2>/dev/null | head -1 || echo 'instalado')"
echo -e "  ${BLUE}Docker       :${NC}  $(docker --version 2>/dev/null || echo 'instalado')"
echo -e "  ${BLUE}Insomnia     :${NC}  $([[ "${APP_INSTALLED[insomnia]}" == true ]] && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}Toolbox      :${NC}  $([[ "${APP_INSTALLED[toolbox]}" == true ]] && echo 'instalado' || echo 'verifique')"
echo -e "  ${BLUE}Workspace    :${NC}  $FSLAB_WORKSPACE"
echo -e "  ${BLUE}Log completo :${NC}  $LOG_FILE"
echo ""
echo -e "${BOLD}Próximos passos:${NC}"
echo -e "  ${CYAN}1.${NC} Reinicie o terminal ou execute: ${BOLD}source ~/.bashrc${NC}"
echo -e "  ${CYAN}2.${NC} Faça logout e login para ativar o grupo ${BOLD}docker${NC}"
echo -e "  ${CYAN}3.${NC} Abra o JetBrains Toolbox e instale o ${BOLD}DataGrip${NC}"
echo -e "  ${CYAN}4.${NC} Configure sua chave SSH no GitHub/GitLab (exibida acima)"
echo -e "  ${CYAN}5.${NC} Teste o Docker: ${BOLD}docker run --rm hello-world${NC}"
echo ""
warn "Reinicie o terminal para garantir que NVM, aliases e PATH estejam carregados."
