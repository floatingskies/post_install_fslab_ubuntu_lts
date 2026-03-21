# FSLab — Development Environment Setup

**Guia de Instalacao para Ambientes Linux**
Versao 2.0 | Marco 2026 | Infraestrutura e DevOps

---

## Sumario

1. [Visao Geral](#1-visao-geral)
2. [Ferramentas Instaladas](#2-ferramentas-instaladas)
3. [Scripts Disponiveis](#3-scripts-disponiveis)
4. [Estrategia por Ferramenta e Distro](#4-estrategia-por-ferramenta-e-distro)
5. [Pre-requisitos](#5-pre-requisitos)
6. [Como Usar](#6-como-usar)
7. [Comportamento dos Scripts](#7-comportamento-dos-scripts)
8. [Decisoes Tecnicas](#8-decisoes-tecnicas)
9. [Correcoes e Historico](#9-correcoes-e-historico)
10. [Estrutura do Repositorio](#10-estrutura-do-repositorio)
11. [Observacoes Importantes](#11-observacoes-importantes)
12. [Suporte e Manutencao](#12-suporte-e-manutencao)

---

## 1. Visao Geral

Este repositorio centraliza os scripts de provisionamento do ambiente de desenvolvimento padronizado do FSLab. O objetivo e garantir que todos os membros da equipe operem com o mesmo conjunto de ferramentas, versoes e configuracoes, independentemente da distribuicao Linux adotada.

Os scripts utilizam exclusivamente os repositorios e pacotes nativos de cada distribuicao, priorizando canais oficiais dos fornecedores. Gerenciadores universais como Snap e Flatpak sao evitados e acionados somente como ultimo recurso, garantindo maior controle sobre versoes e dependencias.

---

## 2. Ferramentas Instaladas

O stack cobre as necessidades de desenvolvimento backend, acesso a banco de dados, testes de API e conteinerizacao:

- **Node.js** — Runtime JavaScript gerenciado via NVM (Node Version Manager), com suporte a multiplas versoes por projeto
- **Visual Studio Code** — Editor de codigo principal na versao proprietaria Microsoft com Marketplace completo
- **Insomnia** — Cliente REST/GraphQL para testes de API
- **DataGrip** — IDE de banco de dados JetBrains, provisionada via JetBrains Toolbox
- **Docker CE** — Plataforma de conteinerizacao com Docker Compose e Buildx incluidos

---

## 3. Scripts Disponiveis

Cada script e destinado a uma familia de distribuicoes especifica. A deteccao da distro e automatica: o script recusa prosseguir caso identifique incompatibilidade com o sistema em execucao.

| Script | Distribuicao alvo | Gerenciador | Fallback |
|---|---|---|---|
| `install-ubuntu-debian.sh` | Ubuntu 20.04+ / Debian 11+ | APT | `.deb` direto / JetBrains Toolbox |
| `install-fedora.sh` | Fedora 37+ | DNF | `.rpm` direto / JetBrains Toolbox |
| `install-arch.sh` | Arch, Manjaro, BigLinux, EndeavourOS, Garuda | Pacman | AUR via `yay` |

### Distros derivadas suportadas

**Base Debian/Ubuntu:** Pop!_OS, Linux Mint, elementaryOS e demais com `ID_LIKE=ubuntu` ou `ID_LIKE=debian`.

**Base Arch:** Manjaro, BigLinux, EndeavourOS, Garuda, ArcoLinux, Artix, CachyOS e demais com `ID_LIKE=arch`.

---

## 4. Estrategia por Ferramenta e Distro

| Ferramenta | Ubuntu / Debian | Fedora | Arch / Manjaro / BigLinux |
|---|---|---|---|
| Node.js | NVM (script oficial) | NVM (script oficial) | NVM (script oficial) |
| VS Code | Repo Microsoft `.deb` | Repo Microsoft `.rpm` | AUR `visual-studio-code-bin` |
| Insomnia | GitHub Releases `.deb` | GitHub Releases `.rpm` | Pacman -> AUR `insomnia-bin` |
| DataGrip | JetBrains Toolbox | JetBrains Toolbox | AUR `jetbrains-toolbox` |
| Docker CE | Repo oficial Docker | Repo oficial Docker | Pacman `docker` (repo extra) |

---

## 5. Pre-requisitos

### 5.1 Sistema

- Usuario com privilegios `sudo` configurados
- Conexao com a internet ativa durante toda a execucao
- Sistema operacional atualizado antes de iniciar o script

### 5.2 Dependencias Automaticas

Todas as dependencias de sistema necessarias — incluindo `curl`, `wget`, `git`, `gnupg`, `base-devel` e bibliotecas graficas — sao instaladas automaticamente na etapa inicial de cada script. Nenhuma preparacao manual previa e exigida ao desenvolvedor.

### 5.3 Arch / Manjaro / BigLinux — yay

O helper AUR `yay` e instalado automaticamente pelo script caso nao esteja presente. Se `paru` ja estiver instalado, ele sera utilizado no lugar. O processo de compilacao do `yay` requer `git`, `base-devel` e `go`, todos instalados automaticamente.

---

## 6. Como Usar

### 6.1 Clone do Repositorio

```bash
git clone https://github.com/fslab/dev-setup.git
cd dev-setup
```

### 6.2 Permissao de Execucao

```bash
chmod +x install-ubuntu-debian.sh install-fedora.sh install-arch.sh
```

### 6.3 Execucao por Distribuicao

**Ubuntu e Debian**

```bash
./install-ubuntu-debian.sh
```

**Fedora**

```bash
./install-fedora.sh
```

**Arch Linux, Manjaro, BigLinux e EndeavourOS**

```bash
./install-arch.sh
```

### 6.4 Pos-instalacao

Reinicie o terminal ou recarregue o perfil do shell para ativar as variaveis do NVM:

```bash
source ~/.bashrc   # bash
source ~/.zshrc    # zsh
```

O Docker requer logout e login para que as permissoes do grupo `docker` tenham efeito, eliminando a necessidade de `sudo` em comandos subsequentes.

O DataGrip deve ser instalado pelo proprio desenvolvedor atraves da interface grafica do JetBrains Toolbox, que e provisionado automaticamente pelo script.

---

## 7. Comportamento dos Scripts

### 7.1 Idempotencia

Todos os scripts verificam a existencia de cada ferramenta antes de iniciar sua instalacao. Caso a ferramenta ja esteja presente, a etapa e ignorada com um aviso informativo. Os scripts podem ser executados multiplas vezes sem causar duplicidades ou erros de estado.

### 7.2 Deteccao de Distribuicao

Cada script le os campos `ID`, `ID_LIKE` e `VERSION_CODENAME` do arquivo `/etc/os-release`. Caso haja incompatibilidade, a execucao e interrompida imediatamente com uma mensagem de erro descritiva.

### 7.3 Hierarquia de Fontes (Fallback)

A ordem de preferencia para cada ferramenta e a seguinte:

1. Repositorio nativo da distribuicao (APT, DNF ou Pacman)
2. Repositorio oficial do fornecedor da ferramenta
3. Download direto do pacote binario (`.deb`, `.rpm` ou tarball via GitHub Releases)
4. AUR exclusivamente no Arch Linux e derivados

### 7.4 Saida e Logs

| Prefixo | Significado |
|---|---|
| `[✔]` | Operacao concluida com sucesso |
| `[!]` | Aviso informativo, execucao continua |
| `[»]` | Etapa em andamento |
| `[✘]` | Erro fatal, execucao interrompida |

Um resumo com as versoes instaladas e exibido ao final de cada execucao bem-sucedida.

### 7.5 Sudo Keepalive (Arch)

O script Arch autentica o `sudo` uma unica vez no inicio e renova o cache automaticamente em background a cada 60 segundos. Isso evita timeout de senha durante etapas longas como compilacao de pacotes AUR (`yay`, `visual-studio-code-bin`).

---

## 8. Decisoes Tecnicas

### VS Code — `visual-studio-code-bin` no Arch

O pacote `code` disponivel nos repositorios oficiais do Arch e o build open-source (equivalente ao VSCodium). Ele nao inclui as extensoes proprietarias da Microsoft nem acesso completo ao Marketplace oficial. Para o fluxo de desenvolvimento do FSLab, o script instala `visual-studio-code-bin` via AUR — a versao binaria proprietaria identica a distribuida pela Microsoft para outras distros.

Caso o script detecte o build OSS ja instalado, ele remove o pacote `code` e instala a versao correta automaticamente.

### Insomnia — GitHub Releases

O repositorio APT/RPM da Kong (`packages.konghq.com/public/insomnia`) foi descontinuado pela propria Kong e nao recebe mais atualizacoes. A unica fonte oficial atual e o GitHub Releases do repositorio `Kong/insomnia`. O script detecta automaticamente a versao mais recente pela API do GitHub (tag `core@x.x.x`) e monta a URL do pacote correspondente.

### NVM — `set +u` temporario

O NVM usa variaveis internas como `PROVIDED_VERSION` que ficam propositalmente sem valor em determinados fluxos. Com `set -u` (nounset) ativo, o bash encerra o script ao encontrar essas variaveis. O script desativa `nounset` apenas durante o carregamento e uso do NVM, restaurando a flag imediatamente apos.

### Docker — `VERSION_CODENAME`

O campo `VERSION_CODENAME` do `/etc/os-release` e utilizado no lugar de `lsb_release -cs`. Em distros derivadas (Pop!_OS, Linux Mint), `lsb_release -cs` retorna o codename da propria distro, que nao existe no repositorio Docker. `VERSION_CODENAME` sempre contem o codename upstream correto (ex: `noble`, `jammy`).

### JetBrains Toolbox — `mktemp -d`

A extracao do tarball usa um diretorio temporario isolado criado com `mktemp -d` em vez de descompactar direto em `/tmp`. O `find` sobre `/tmp` cruza com diretorios privados do systemd (`systemd-private-*`) que retornam `Permission denied`, o que com `set -e` ativo encerra o script antes de encontrar o binario.

---

## 9. Correcoes e Historico

### v2.0 — Marco 2026

- **Arch:** adicionado suporte explicito a Manjaro, BigLinux e EndeavourOS na deteccao de distro
- **Arch:** VS Code alterado para `visual-studio-code-bin` (AUR) como fonte primaria
- **Arch:** deteccao e substituicao automatica do build OSS caso ja instalado
- **Arch:** sudo keepalive em background para evitar timeout durante compilacao AUR
- **Arch:** atualizacao do keyring (`archlinux-keyring` / `manjaro-keyring`) antes do `pacman -Syu`
- **Arch:** `set -euo pipefail` com `set +u` seletivo ao redor do NVM
- **Arch/Ubuntu:** `mktemp -d` para extracao do JetBrains Toolbox, corrigindo falha com diretorios `systemd-private-*` em `/tmp`
- **Ubuntu:** `sudo mkdir -p /etc/apt/keyrings` adicionado antes da instalacao do VS Code
- **Ubuntu:** Insomnia migrado do repositorio APT da Kong (descontinuado) para GitHub Releases
- **Ubuntu:** Docker corrigido para usar `VERSION_CODENAME` e `UPSTREAM_DISTRO` corretos em distros derivadas

---

## 10. Estrutura do Repositorio

```
dev-setup/
|-- install-ubuntu-debian.sh
|-- install-fedora.sh
|-- install-arch.sh
`-- README.md
```

---

## 11. Observacoes Importantes

- Nao execute os scripts como `root`. Utilize um usuario comum com privilegios `sudo`.
- O NVM e instalado no perfil do usuario, nao globalmente. Cada membro da equipe deve executar o script individualmente em sua conta.
- A compilacao de pacotes AUR (`yay`, `visual-studio-code-bin`) pode levar varios minutos dependendo do hardware. Nao interrompa o processo.
- Licencas de produtos JetBrains (DataGrip) devem ser gerenciadas conforme o acordo de licenciamento vigente no FSLab.
- Em ambientes com proxy corporativo, configure as variaveis `http_proxy` e `https_proxy` antes de executar os scripts.

---

## 12. Suporte e Manutencao

Em caso de falha na execucao ou necessidade de adicionar novas ferramentas ao stack, abra uma issue no repositorio ou entre em contato com o time de Infraestrutura do FSLab.

**Mantenedor:** Time de Infraestrutura e DevOps — FSLab
**Repositorio:** https://github.com/fslab/dev-setup
