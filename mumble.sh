#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────────────────────┐
# │                                                                 │
# │   ███╗   ███╗██╗   ██╗███╗   ███╗██████╗ ██╗     ███████╗       │
# │   ████╗ ████║██║   ██║████╗ ████║██╔══██╗██║     ██╔════╝       │
# │   ██╔████╔██║██║   ██║██╔████╔██║██████╔╝██║     █████╗         │
# │   ██║╚██╔╝██║██║   ██║██║╚██╔╝██║██╔══██╗██║     ██╔══╝         │
# │   ██║ ╚═╝ ██║╚██████╔╝██║ ╚═╝ ██║██████╔╝███████╗███████╗       │
# │   ╚═╝     ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚═════╝ ╚══════╝╚══════╝       │
# │                                                                 │
# │             🎙️  I N S T A L L E R   F O R   F I V E M 🎙️       │
# │                                                                 │
# │                        Created by GCN                           │
# │                   Rust-Mumble Voice Server                      │
# │                                                                 │
# └─────────────────────────────────────────────────────────────────┘

#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/mumble"
RUN_USER="mumble"
RUN_GROUP="mumble"

MUMBLE_LISTEN="0.0.0.0:64738"
HTTP_LISTEN="0.0.0.0:8080"
HTTP_USER="admin"
HTTP_PASSWORD="adminFXGCN"
RESTRICT_TO_VERSION="CitizenFX"

CERT_FILE="${INSTALL_DIR}/cert.pem"
KEY_FILE="${INSTALL_DIR}/key.pem"

SERVICE_NAME="mumble"
ENV_FILE="/etc/${SERVICE_NAME}.env"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ===== Helpers =====
log()  { echo -e "\033[1;36m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m   $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERRO]\033[0m $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Execute como root: sudo $0"
}

ufw_is_active() {
  ufw status 2>/dev/null | head -n1 | grep -qi "Status: active"
}

install_packages() {
  log "Atualizando APT e instalando dependências..."
  apt update -y
  apt install -y \
    git curl ca-certificates build-essential pkg-config \
    clang llvm libssl-dev openssl ufw
  ok "Dependências instaladas"
}

create_user() {
  if id -u "${RUN_USER}" >/dev/null 2>&1; then
    ok "Usuário ${RUN_USER} já existe"
  else
    log "Criando usuário dedicado ${RUN_USER}..."
    useradd --system --create-home --home-dir "/home/${RUN_USER}" \
      --shell /usr/sbin/nologin "${RUN_USER}"
    ok "Usuário ${RUN_USER} criado"
  fi
}

install_rust_toolchain() {
  # Instala rustup/cargo para o usuário dedicado (mais limpo que root)
  log "Instalando/Atualizando Rust (rustup) para o usuário ${RUN_USER}..."
  sudo -u "${RUN_USER}" bash -lc '
    if ! command -v rustup >/dev/null 2>&1; then
      # Instala rustup se não existir
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    if [[ -f "$HOME/.cargo/env" ]]; then
      source "$HOME/.cargo/env"
    fi
    # Atualiza para a versão mais recente do Rust
    if command -v rustup >/dev/null 2>&1; then
      rustup update stable
      rustup default stable
    fi
    rustc -V
    cargo -V
  '
  ok "Rust instalado/atualizado para ${RUN_USER}"
}

clone_or_update_repo() {
  local repo="AvarianKnight/rust-mumble"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  
  log "Buscando informações da última release..."
  
  # Busca informações da última release
  local release_info
  release_info=$(curl -sL "${api_url}")
  
  local latest_tag
  latest_tag=$(echo "${release_info}" | grep -o '"tag_name": "[^"]*"' | head -n1 | sed 's/"tag_name": "\(.*\)"/\1/')
  
  if [[ -z "${latest_tag}" ]]; then
    die "Não foi possível encontrar a última release"
  fi
  
  log "Última release encontrada: ${latest_tag}"
  
  # URL do código-fonte da release (tarball)
  local download_url="https://github.com/${repo}/archive/refs/tags/${latest_tag}.tar.gz"
  local temp_file="/tmp/mumble-${latest_tag}.tar.gz"
  
  log "Baixando código-fonte da release ${latest_tag}..."
  curl -L -o "${temp_file}" "${download_url}"
  
  # Remove diretório antigo se existir
  if [[ -d "${INSTALL_DIR}" ]]; then
    log "Removendo instalação anterior..."
    rm -rf "${INSTALL_DIR}"
  fi
  
  # Extrai o código-fonte
  log "Extraindo código-fonte em ${INSTALL_DIR}..."
  mkdir -p "${INSTALL_DIR}"
  tar -xzf "${temp_file}" -C "${INSTALL_DIR}" --strip-components=1
  
  # Limpa arquivo temporário
  rm -f "${temp_file}"
  
  chown -R "${RUN_USER}:${RUN_GROUP}" "${INSTALL_DIR}"
  ok "Código-fonte da release ${latest_tag} pronto"
}

build_release() {
  log "Compilando mumble (cargo build --release)..."
  sudo -u "${RUN_USER}" bash -lc "
    set -e
    cd '${INSTALL_DIR}'
    if [[ -f \"\$HOME/.cargo/env\" ]]; then
      source \"\$HOME/.cargo/env\"
    fi
    cargo build --release
  "
  
  # O binário compilado se chama 'rust-mumble', vamos renomear para 'mumble'
  if [[ -f "${INSTALL_DIR}/target/release/rust-mumble" ]]; then
    log "Renomeando binário de rust-mumble para mumble..."
    mv "${INSTALL_DIR}/target/release/rust-mumble" "${INSTALL_DIR}/target/release/mumble"
  elif [[ ! -f "${INSTALL_DIR}/target/release/mumble" ]]; then
    die "Binário não encontrado após compilação. Verifique os erros acima."
  fi
  
  ok "Build concluído"
}

generate_certs_if_missing() {
  if [[ -f "${CERT_FILE}" && -f "${KEY_FILE}" ]]; then
    ok "Certificados já existem (${CERT_FILE}, ${KEY_FILE})"
    return
  fi

  log "Gerando certificado autoassinado (cert.pem/key.pem)..."
  openssl req -newkey rsa:2048 -days 3650 -nodes -x509 \
    -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
    -subj "/CN=mumble"
  chown "${RUN_USER}:${RUN_GROUP}" "${CERT_FILE}" "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
  ok "Certificados gerados"
}

write_env_file() {
  local http_password
  # Usa a senha definida ou gera uma nova
  if [[ -z "${HTTP_PASSWORD}" ]]; then
    http_password="$(openssl rand -base64 24 | tr -d '\n')"
  else
    http_password="${HTTP_PASSWORD}"
  fi

  log "Criando arquivo de ambiente ${ENV_FILE}..."
  cat > "${ENV_FILE}" <<EOF
# Config do mumble (usado pelo systemd)
MUMBLE_LISTEN=${MUMBLE_LISTEN}
HTTP_LISTEN=${HTTP_LISTEN}
HTTP_USER=${HTTP_USER}
HTTP_PASSWORD=${http_password}
CERT_FILE=${CERT_FILE}
KEY_FILE=${KEY_FILE}
RESTRICT_TO_VERSION=${RESTRICT_TO_VERSION}
EOF

  chmod 600 "${ENV_FILE}"
  ok "ENV criado. Guarde a senha da API HTTP:"
  echo "    HTTP_USER=${HTTP_USER}"
  echo "    HTTP_PASSWORD=${http_password}"
}

write_systemd_unit() {
  local bin="${INSTALL_DIR}/target/release/mumble"
  [[ -x "${bin}" ]] || die "Binário não encontrado: ${bin}"

  log "Criando systemd unit: ${UNIT_FILE}..."
  cat > "${UNIT_FILE}" <<'EOF'
[Unit]
Description=Mumble for FiveM - By GCN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mumble
Group=mumble
WorkingDirectory=/opt/mumble
EnvironmentFile=/etc/mumble.env

# Opções principais:
# --listen (TCP+UDP) e --http-listen defaults: 0.0.0.0:64738 e 0.0.0.0:8080
# (aqui a gente injeta via env)
ExecStart=/opt/mumble/target/release/mumble \
  --listen ${MUMBLE_LISTEN} \
  --http-listen ${HTTP_LISTEN} \
  --http-user ${HTTP_USER} \
  --http-password ${HTTP_PASSWORD} \
  --cert ${CERT_FILE} \
  --key ${KEY_FILE}

# Se quiser travar para só CitizenFX (FiveM), use:
#  --restrict-to-version CitizenFX
# (ou defina RESTRICT_TO_VERSION no env e altere o ExecStart)

Restart=always
RestartSec=2

# Performance/limites
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  # Ajusta usuário/grupo caso você altere RUN_USER no topo
  sed -i "s/User=mumble/User=${RUN_USER}/" "${UNIT_FILE}"
  sed -i "s/Group=mumble/Group=${RUN_GROUP}/" "${UNIT_FILE}"
  sed -i "s|WorkingDirectory=/opt/mumble|WorkingDirectory=${INSTALL_DIR}|g" "${UNIT_FILE}"
  sed -i "s|ExecStart=/opt/mumble|ExecStart=${INSTALL_DIR}|g" "${UNIT_FILE}"
  sed -i "s|EnvironmentFile=/etc/mumble.env|EnvironmentFile=${ENV_FILE}|g" "${UNIT_FILE}"

  ok "Unit criada"
}

systemd_enable_start() {
  log "Recarregando systemd e iniciando serviço..."
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  ok "Serviço habilitado e iniciado: ${SERVICE_NAME}"
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

configure_ufw() {
  log "Configurando firewall (UFW)..."
  
  # Portas do Mumble (voz)
  ufw allow 64738/tcp >/dev/null || true
  ufw allow 64738/udp >/dev/null || true
  
  # API HTTP - liberando para acesso geral
  # ATENÇÃO: Se quiser restringir por IP, modifique esta linha
  ufw allow 8080/tcp >/dev/null || true
  
  if ufw_is_active; then
    ufw reload >/dev/null || true
    ok "UFW ativo e regras aplicadas"
    warn "Porta 8080 (API HTTP) está aberta. Certifique-se de usar senhas fortes!"
  else
    warn "UFW não está ativo. Regras foram adicionadas, mas não estão valendo ainda."
    warn "Se for ativar, confirme que sua porta SSH (22) está liberada antes:"
    warn "  sudo ufw allow OpenSSH && sudo ufw enable"
  fi
}

main() {
  require_root
  install_packages
  create_user
  install_rust_toolchain
  clone_or_update_repo
  build_release
  generate_certs_if_missing
  write_env_file
  write_systemd_unit
  configure_ufw
  systemd_enable_start

  echo
  ok "INSTALAÇÃO CONCLUÍDA"
}

main "$@"
