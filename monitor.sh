#!/usr/bin/env bash
# --------------------------------------------------------------
# Modos: instalação do zero ou atualização (-u)
#
# Instala e configura:
# - Zabbix Agent 2 (Ubuntu/Debian e RHEL-like)
# - Repo Zabbix conforme ARQUITETURA:
#     * Ubuntu: usa ubuntu-arm64 quando arm64
#     * RHEL-like: usa x86_64/aarch64 no caminho do repo
# - Cria venv Python e scripts customizados (pinga.py / packet_loss.py)
# - Configura UserParameters no Zabbix Agent 2
# - Instala plugins específicos:
#     zabbix-agent2-plugin-mongodb
#     zabbix-agent2-plugin-mssql
#     zabbix-agent2-plugin-postgresql
# --------------------------------------------------------------

set -euo pipefail

log()  { echo -e "[INFO]  $*"; }
warn() { echo -e "[WARN]  $*" >&2; }
die()  { echo -e "[ERRO]  $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

cleanup() { [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Execute como root (sudo)."; }

DEFAULT_ZABBIX_SERVER="0.0.0.0"
SERVER_IP="$DEFAULT_ZABBIX_SERVER"
ZABBIX_VER="7.4"
MODE="install"   # install | update

# Plugins desejados (instala individualmente e não falha o script se algum não existir)
ZBX_PLUGINS=(
  "zabbix-agent2-plugin-mongodb"
  "zabbix-agent2-plugin-mssql"
  "zabbix-agent2-plugin-postgresql"
)

usage() {
  cat <<EOF
Uso: $0 [-s <ip_ou_hostname_zabbix>] [-v <zabbix_version>] [-u]

Opções:
  -s    IP/hostname do servidor Zabbix (padrão: ${DEFAULT_ZABBIX_SERVER})
  -v    Versão do Zabbix (padrão: ${ZABBIX_VER})
  -u    Modo atualização: atualiza repo, pacotes e scripts (exige agente já instalado)
  -h    Ajuda

Sem -u: instalação do zero. Se o agente já estiver instalado, o script pode perguntar
       se deseja apenas atualizar tudo em vez de reinstalar.
EOF
}

while getopts ":s:v:uh" opt; do
  case "$opt" in
    s) SERVER_IP="$OPTARG" ;;
    v) ZABBIX_VER="$OPTARG" ;;
    u) MODE="update" ;;
    h) usage; exit 0 ;;
    \?) die "Opção inválida: -$OPTARG (use -h)" ;;
    :) die "A opção -$OPTARG exige um argumento." ;;
  esac
done

require_root

# -----------------------------
# 1) Detectar SO
# -----------------------------
[[ -f /etc/os-release ]] || die "/etc/os-release não encontrado."
# shellcheck disable=SC1091
source /etc/os-release

OS_FAMILY=""
if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *"debian"* ]]; then
  OS_FAMILY="debian"
elif [[ "${ID:-}" == "almalinux" || "${ID:-}" == "rocky" || "${ID:-}" == "cloudlinux" || "${ID_LIKE:-}" == *"rhel"* ]]; then
  OS_FAMILY="rhel"
else
  die "Distribuição não suportada: ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}"
fi

log "Sistema: ${PRETTY_NAME:-?}"
log "Versão: ${VERSION_ID:-?}"
log "Família: ${OS_FAMILY}"

# -----------------------------
# 1.1) Detectar Arquitetura
# -----------------------------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)   ARCH="amd64";  ZBX_RHEL_DIR="x86_64" ;;
  aarch64|arm64)  ARCH="arm64";  ZBX_RHEL_DIR="aarch64" ;;
  *) die "Arquitetura não suportada: $ARCH_RAW" ;;
esac
log "Arquitetura: ${ARCH_RAW} (apt: ${ARCH}; rhel repo dir: ${ZBX_RHEL_DIR})"

# -----------------------------
# 2) Package manager helpers
# -----------------------------
PKG_UPDATE=""
PKG_INSTALL=""
if [[ "$OS_FAMILY" == "debian" ]]; then
  PKG_UPDATE="apt-get update -y"
  PKG_INSTALL="apt-get install -y"
else
  if command_exists dnf; then
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
  else
    PKG_UPDATE="yum -y makecache"
    PKG_INSTALL="yum install -y"
  fi
fi

# -----------------------------
# 3) Perguntar IP do Zabbix se não veio por -s
# -----------------------------
if [[ "$SERVER_IP" == "$DEFAULT_ZABBIX_SERVER" ]]; then
  read -rp "Digite o IP/hostname do servidor Zabbix [padrão: ${DEFAULT_ZABBIX_SERVER}]: " USER_INPUT || true
  [[ -n "${USER_INPUT:-}" ]] && SERVER_IP="$USER_INPUT"
fi
log "Servidor Zabbix: $SERVER_IP"

# -----------------------------
# 3.1) Modo: instalação vs atualização
# -----------------------------
is_zabbix_installed() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -l zabbix-agent2 2>/dev/null | grep -q '^ii'
  else
    rpm -q zabbix-agent2 &>/dev/null
  fi
}

if [[ "$MODE" == "update" ]]; then
  if ! is_zabbix_installed; then
    die "Zabbix Agent 2 não está instalado. Execute o script sem -u para instalação do zero."
  fi
  log "Modo: ATUALIZAÇÃO (repo, pacotes e scripts serão atualizados)"
elif is_zabbix_installed; then
  log "Zabbix Agent 2 já está instalado."
  read -rp "Deseja [1] Atualizar tudo (repo, pacotes, scripts) ou [2] Instalação do zero (reinstalar)? [1/2]: " choice || true
  if [[ "${choice:-}" == "2" ]]; then
    MODE="install"
    log "Modo: instalação do zero"
  else
    MODE="update"
    log "Modo: ATUALIZAÇÃO"
  fi
fi

if [[ "$MODE" == "update" ]]; then
  INSTALL_VERB="Atualizando"
else
  INSTALL_VERB="Instalando"
fi

# -----------------------------
# 4) Pré-requisitos
# -----------------------------
log "Atualizando cache de pacotes..."
eval "$PKG_UPDATE"

if ! command_exists wget && ! command_exists curl; then
  log "Instalando wget..."
  eval "$PKG_INSTALL wget"
fi

if ! command_exists ping; then
  warn "Comando ping não encontrado. Instalando..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    eval "$PKG_INSTALL iputils-ping"
  else
    eval "$PKG_INSTALL iputils"
  fi
fi

download_file() {
  local url="$1"
  local out="$2"
  if command_exists wget; then
    wget -q "$url" -O "$out"
  else
    curl -fsSL "$url" -o "$out"
  fi
}

# -----------------------------
# 5) Montar URL do repo do Zabbix
# -----------------------------
ZBX_REPO_URL=""
ZBX_REPO_PKG=""

if [[ "$OS_FAMILY" == "debian" ]]; then
  if [[ "${ID:-}" == "ubuntu" ]]; then
    case "${VERSION_ID:-}" in
      "20.04"|"22.04"|"24.04") ;;
      *) die "Ubuntu ${VERSION_ID:-?} não suportado automaticamente para Zabbix ${ZABBIX_VER}." ;;
    esac

    UB_REPO_DIR="ubuntu"
    [[ "$ARCH" == "arm64" ]] && UB_REPO_DIR="ubuntu-arm64"

    ZBX_REPO_PKG="zabbix-release_latest_${ZABBIX_VER}+ubuntu${VERSION_ID}_all.deb"
    ZBX_REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/${UB_REPO_DIR}/pool/main/z/zabbix-release/${ZBX_REPO_PKG}"
  else
    # Debian puro (ID=debian)
    case "${VERSION_ID:-}" in
      11|12|13) ;;
      *) die "Debian ${VERSION_ID:-?} não suportado automaticamente para Zabbix ${ZABBIX_VER}." ;;
    esac

    DEB_REPO_DIR="debian"
    [[ "$ARCH" == "arm64" ]] && DEB_REPO_DIR="debian-arm64"

    ZBX_REPO_PKG="zabbix-release_latest_${ZABBIX_VER}+debian${VERSION_ID}_all.deb"
    ZBX_REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/${DEB_REPO_DIR}/pool/main/z/zabbix-release/${ZBX_REPO_PKG}"
  fi
else
  case "${VERSION_ID:-}" in
    8*) RHEL_MAJOR="8" ;;
    9*) RHEL_MAJOR="9" ;;
    *) die "RHEL-like ${VERSION_ID:-?} não suportado automaticamente." ;;
  esac

  ZBX_REPO_PKG_PRIMARY="zabbix-release-latest.el${RHEL_MAJOR}.noarch.rpm"
  ZBX_REPO_PKG_FALLBACK="zabbix-release-latest-${ZABBIX_VER}.el${RHEL_MAJOR}.noarch.rpm"

  ZBX_REPO_URL_PRIMARY="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/rhel/${RHEL_MAJOR}/${ZBX_RHEL_DIR}/${ZBX_REPO_PKG_PRIMARY}"
  ZBX_REPO_URL_FALLBACK="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/rhel/${RHEL_MAJOR}/${ZBX_RHEL_DIR}/${ZBX_REPO_PKG_FALLBACK}"
fi

# -----------------------------
# 6) Baixar e instalar repo
# -----------------------------
TMP_DIR="$(mktemp -d)"
cd "$TMP_DIR"

log "$([[ "$MODE" == "update" ]] && echo "Atualizando" || echo "Baixando") pacote do repositório Zabbix (v${ZABBIX_VER})..."

if [[ "$OS_FAMILY" == "rhel" ]]; then
  log "Tentando [1/2]: $ZBX_REPO_URL_PRIMARY"
  if download_file "$ZBX_REPO_URL_PRIMARY" "$ZBX_REPO_PKG_PRIMARY"; then
    ZBX_REPO_PKG="$ZBX_REPO_PKG_PRIMARY"
  else
    warn "Falhou [1/2]. Tentando [2/2]: $ZBX_REPO_URL_FALLBACK"
    download_file "$ZBX_REPO_URL_FALLBACK" "$ZBX_REPO_PKG_FALLBACK" || die "Falha ao baixar repo Zabbix (RHEL)."
    ZBX_REPO_PKG="$ZBX_REPO_PKG_FALLBACK"
  fi
else
  download_file "$ZBX_REPO_URL" "$ZBX_REPO_PKG" || die "Falha ao baixar repo Zabbix. URL: $ZBX_REPO_URL"
fi

log "$INSTALL_VERB pacote de repositório do Zabbix: $ZBX_REPO_PKG"
if [[ "$OS_FAMILY" == "debian" ]]; then
  dpkg -i "$ZBX_REPO_PKG" >/dev/null
else
  rpm -Uvh "$ZBX_REPO_PKG" >/dev/null
fi

log "Atualizando cache de pacotes após adicionar repo..."
eval "$PKG_UPDATE"

# -----------------------------
# 7) Instalar/atualizar Zabbix Agent 2 + plugins desejados
# -----------------------------
log "$INSTALL_VERB Zabbix Agent 2..."
eval "$PKG_INSTALL zabbix-agent2" || die "Não consegui instalar/atualizar zabbix-agent2. (Repo/arch não compatível?)"

log "$INSTALL_VERB plugins desejados..."
for p in "${ZBX_PLUGINS[@]}"; do
  if eval "$PKG_INSTALL $p"; then
    log "Plugin instalado: $p"
  else
    warn "Não foi possível instalar o plugin: $p (talvez não exista nessa versão/repo)."
  fi
done

# -----------------------------
# 8) Configurar Zabbix Agent 2
# -----------------------------
CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
[[ -f "$CONFIG_FILE" ]] || die "Arquivo de configuração não encontrado: $CONFIG_FILE"

set_conf_kv() {
  local key="$1"
  local value="$2"
  local file="$3"
  # Escapar valor para sed: \ e & (evita quebra no replacement)
  local val_escaped="${value//\\/\\\\}"
  val_escaped="${val_escaped//&/\\&}"

  if grep -qE "^[#[:space:]]*${key}=" "$file"; then
    # Substituir a linha inteira (igual ao script antigo) - evita duplicar linha
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${val_escaped}|g" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

log "Configurando Server/ServerActive em $CONFIG_FILE"
set_conf_kv "Server" "$SERVER_IP" "$CONFIG_FILE"
set_conf_kv "ServerActive" "$SERVER_IP" "$CONFIG_FILE"

mkdir -p /etc/zabbix/zabbix_agent2.d/plugins.d/

# -----------------------------
# 9) Python + venv + scripts
# -----------------------------
log "$([[ "$MODE" == "update" ]] && echo "Garantindo" || echo "Instalando") Python 3 e venv..."
if [[ "$OS_FAMILY" == "debian" ]]; then
  eval "$PKG_INSTALL python3 python3-venv"
else
  eval "$PKG_INSTALL python3" || true
  eval "$PKG_INSTALL python3-venv" || true
fi

VENV_DIR="/usr/local/bin/ping_venv"
log "$([[ "$MODE" == "update" ]] && echo "Atualizando" || echo "Criando") venv em: $VENV_DIR"
python3 -m venv "$VENV_DIR"

PINGA="/usr/local/bin/pinga.py"
LOSS="/usr/local/bin/packet_loss.py"

log "$([[ "$MODE" == "update" ]] && echo "Atualizando" || echo "Criando") $PINGA (latência)"
cat <<'EOF' > "$PINGA"
#!/usr/local/bin/ping_venv/bin/python3
import subprocess
import sys
import re

def ping(host: str) -> None:
    try:
        output = subprocess.run(
            ["ping", "-c", "1", host],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        if output.returncode == 0:
            m = re.search(r"time=(\d+\.?\d*) ms", output.stdout)
            print(m.group(1) if m else "0")
        else:
            print("0")
    except Exception:
        print("0")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("0")
    else:
        ping(sys.argv[1])
EOF

log "$([[ "$MODE" == "update" ]] && echo "Atualizando" || echo "Criando") $LOSS (perda de pacotes)"
cat <<'EOF' > "$LOSS"
#!/usr/local/bin/ping_venv/bin/python3
import subprocess
import sys
import re

def packet_loss(host: str) -> None:
    try:
        output = subprocess.run(
            ["ping", "-c", "10", host],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        m = re.search(r"(\d+\.?\d*)% packet loss", output.stdout)
        print(m.group(1) if m else "100.0")
    except Exception:
        print("100.0")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("100.0")
    else:
        packet_loss(sys.argv[1])
EOF

chmod 0755 "$PINGA" "$LOSS"

ZBX_CUSTOM_CONF="/etc/zabbix/zabbix_agent2.d/plugins.d/pinga.conf"
log "$([[ "$MODE" == "update" ]] && echo "Atualizando" || echo "Criando") UserParameters: $ZBX_CUSTOM_CONF"
cat <<EOF > "$ZBX_CUSTOM_CONF"
UserParameter=pinga.custom[*],${PINGA} \$1
UserParameter=packet.loss[*],${LOSS} \$1
EOF
chmod 0644 "$ZBX_CUSTOM_CONF"

# -----------------------------
# 10) Habilitar e reiniciar serviço
# -----------------------------
log "Habilitando e reiniciando zabbix-agent2..."
systemctl enable zabbix-agent2 >/dev/null
systemctl restart zabbix-agent2

if systemctl is-active --quiet zabbix-agent2; then
  log "zabbix-agent2 está ativo."
else
  warn "zabbix-agent2 não está ativo. Logs: journalctl -u zabbix-agent2 -n 200 --no-pager"
fi

log "------------------------------------------------------------"
log "$([[ "$MODE" == "update" ]] && echo "Atualização concluída!" || echo "Concluído!")"
log " -> Zabbix: v${ZABBIX_VER}"
log " -> Servidor Zabbix: $SERVER_IP"
log " -> Sistema: ${PRETTY_NAME:-?}"
log " -> Arquitetura: ${ARCH_RAW}"
log " -> Repo URL usada: ${ZBX_REPO_URL:-${ZBX_REPO_URL_PRIMARY:-}}"
log " -> Plugins solicitados: ${ZBX_PLUGINS[*]}"
log " -> Scripts: $PINGA e $LOSS"
log " -> UserParameters: $ZBX_CUSTOM_CONF"
log "------------------------------------------------------------"