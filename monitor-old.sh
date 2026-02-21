#!/bin/bash
# --------------------------------------------------------------
# Script completo para:
# - Instalação e configuração do Zabbix Agent 2
# - Criação de ambiente Python com venv
# - Configuração dos scripts customizados (pinga.py e packet_loss.py)
#
# Suporta distribuições baseadas em Debian (Ubuntu) e RHEL 
# (AlmaLinux, Rocky Linux, CloudLinux, etc.)
# --------------------------------------------------------------

# 1. DETECTAR O SISTEMA OPERACIONAL
source /etc/os-release

if [[ "$ID" == "ubuntu" ]]; then
    echo "Distribuição Ubuntu detectada."
    OS_FAMILY="debian"
elif [[ "$ID" == "almalinux" || "$ID" == "rocky" || "$ID" == "cloudlinux" || "$ID_LIKE" == *"rhel"* ]]; then
    echo "Distribuição baseada em RHEL detectada: $ID."
    OS_FAMILY="rhel"
else
    echo "Distribuição não suportada: $ID"
    exit 1
fi

echo "Sistema: $PRETTY_NAME"
echo "Versão: $VERSION_ID"

# 2. CONFIGURAR GERENCIADOR DE PACOTES
if [[ "$OS_FAMILY" == "debian" ]]; then
    PKG_UPDATE="apt update -y"
    PKG_INSTALL="apt install -y"
elif [[ "$OS_FAMILY" == "rhel" ]]; then
    if command -v dnf &> /dev/null; then
        PKG_UPDATE="dnf update -y"
        PKG_INSTALL="dnf install -y"
    else
        PKG_UPDATE="yum update -y"
        PKG_INSTALL="yum install -y"
    fi
fi

# 3. ESCOLHER O REPOSITÓRIO ZABBIX
if [[ "$OS_FAMILY" == "debian" ]]; then
    case "$VERSION_ID" in
      "20.04")  ZBX_REPO_PKG="zabbix-release_latest_7.0+ubuntu20.04_all.deb" ;;
      "22.04")  ZBX_REPO_PKG="zabbix-release_latest_7.0+ubuntu22.04_all.deb" ;;
      "24.04")  ZBX_REPO_PKG="zabbix-release_latest_7.0+ubuntu24.04_all.deb" ;; # Exemplo hipotético
      *)
          echo "Versão $VERSION_ID não suportada automaticamente para Ubuntu."
          echo "Verifique manualmente em: https://www.zabbix.com/download"
          exit 1
          ;;
    esac
    ZBX_REPO_URL="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/$ZBX_REPO_PKG"
elif [[ "$OS_FAMILY" == "rhel" ]]; then
    case "$VERSION_ID" in
      8*)
          RHEL_MAJOR="8"
          ZBX_REPO_PKG="zabbix-release-7.0-1.el8.noarch.rpm"
          ;;
      9*)
          RHEL_MAJOR="9"
          ZBX_REPO_PKG="zabbix-release-7.0-1.el9.noarch.rpm"
          ;;
      *)
          echo "Versão $VERSION_ID não suportada automaticamente para distribuições RHEL."
          echo "Verifique manualmente em: https://www.zabbix.com/download"
          exit 1
          ;;
    esac
    ZBX_REPO_URL="https://repo.zabbix.com/zabbix/7.0/rhel/${RHEL_MAJOR}/x86_64/${ZBX_REPO_PKG}"
fi

# 4. PERGUNTAR O IP/HOSTNAME DO SERVIDOR ZABBIX
DEFAULT_ZABBIX_SERVER_IP="0.0.0.0"
read -rp "Digite o IP/hostname do servidor Zabbix [padrão: $DEFAULT_ZABBIX_SERVER_IP]: " USER_INPUT
if [[ -z "$USER_INPUT" ]]; then
  SERVER_IP="$DEFAULT_ZABBIX_SERVER_IP"
else
  SERVER_IP="$USER_INPUT"
fi
echo "Servidor Zabbix configurado para: $SERVER_IP"

# 5. INSTALAR DEPENDÊNCIAS BÁSICAS (wget)
if ! command -v wget &> /dev/null; then
  echo "Instalando wget..."
  $PKG_UPDATE
  $PKG_INSTALL wget
fi

# 6. INSTALAR O REPOSITÓRIO ZABBIX
echo "Baixando o pacote do repositório Zabbix..."
cd /tmp || exit 1
wget -q "$ZBX_REPO_URL" -O "$ZBX_REPO_PKG"
if [[ ! -f "$ZBX_REPO_PKG" ]]; then
  echo "Falha ao baixar o pacote do repositório Zabbix."
  exit 1
fi

echo "Instalando o pacote de repositório do Zabbix..."
if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -i "$ZBX_REPO_PKG" || exit 1
elif [[ "$OS_FAMILY" == "rhel" ]]; then
    rpm -Uvh "$ZBX_REPO_PKG" || exit 1
fi

# 7. ATUALIZAR OS PACOTES DO SISTEMA
echo "Atualizando os pacotes do sistema..."
$PKG_UPDATE

# 8. INSTALAR O ZABBIX AGENT 2 E PLUGINS
echo "Instalando o Zabbix Agent 2 e plugins..."
$PKG_INSTALL zabbix-agent2 zabbix-agent2-plugin-*

# 9. CONFIGURAR O ZABBIX AGENT 2
CONFIG_FILE="/etc/zabbix/zabbix_agent2.conf"
echo "Configurando o arquivo: $CONFIG_FILE"
if grep -q "^Server=" "$CONFIG_FILE"; then
    sed -i "s/^Server=.*/Server=$SERVER_IP/" "$CONFIG_FILE"
else
    echo "Server=$SERVER_IP" >> "$CONFIG_FILE"
fi

# 10. REINICIAR E HABILITAR O SERVIÇO DO ZABBIX AGENT 2
echo "Reiniciando o serviço do Zabbix Agent 2..."
systemctl restart zabbix-agent2
echo "Habilitando o Zabbix Agent 2 no boot..."
systemctl enable zabbix-agent2

# ------------------------------------------------------------
# Seção adicional: Instalação do Python 3, criação do venv
# e configuração dos scripts de medição de ping.
# ------------------------------------------------------------

echo "------------------------------------------------------------"
echo "Instalando Python 3 e venv..."
$PKG_UPDATE && $PKG_INSTALL python3-venv

echo "Criando o ambiente virtual em /usr/local/bin/ping_venv..."
python3 -m venv /usr/local/bin/ping_venv

echo "Criando o arquivo /usr/local/bin/pinga.py para medir latência..."
cat <<'EOF' > /usr/local/bin/pinga.py
#!/usr/local/bin/ping_venv/bin/python3
import subprocess
import sys
import re

def ping(host):
    try:
        output = subprocess.run(['ping', '-c', '1', host],
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                text=True)

        if output.returncode == 0:
            match = re.search(r"time=(\d+\.?\d*) ms", output.stdout)
            if match:
                ping_time = match.group(1)
                print(f"{ping_time}")
            else:
                print("Tempo não encontrado na saída do ping.")
        else:
            print(f"Falha ao pingar {host}.")
            print(output.stderr)

    except Exception as e:
        print(f"Erro ao executar o ping: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Uso: python pinga.py <endereço_ip_ou_domínio>")
    else:
        ping(sys.argv[1])
EOF

echo "Criando o arquivo /usr/local/bin/packet_loss.py para medir perda de pacotes..."
cat <<'EOF' > /usr/local/bin/packet_loss.py
#!/usr/local/bin/ping_venv/bin/python3
import subprocess
import sys
import re

def packet_loss(host):
    try:
        output = subprocess.run(['ping', '-c', '10', host],
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                text=True)

        if output.returncode == 0:
            match = re.search(r"(\d+\.?\d*)% packet loss", output.stdout)
            if match:
                loss = match.group(1)
                print(loss)
            else:
                print("Erro ao analisar perda de pacotes.")
        else:
            print("100.0")

    except Exception as e:
        print("100.0")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Uso: python packet_loss.py <endereço_ip_ou_domínio>")
    else:
        packet_loss(sys.argv[1])
EOF

echo "Dando permissão de execução aos scripts..."
chmod +x /usr/local/bin/pinga.py
chmod +x /usr/local/bin/packet_loss.py

echo "Criando diretório de configuração do Zabbix Agent para plugins, se não existir..."
mkdir -p /etc/zabbix/zabbix_agent2.d/plugins.d/

echo "Criando o arquivo de configuração do Zabbix Agent para os scripts customizados..."
cat <<'EOF' > /etc/zabbix/zabbix_agent2.d/plugins.d/pinga.conf
UserParameter=pinga.custom[*],/usr/bin/python3 /usr/local/bin/pinga.py \$1
UserParameter=packet.loss[*],/usr/bin/python3 /usr/local/bin/packet_loss.py \$1
EOF

echo "Reiniciando o serviço do Zabbix Agent para aplicar as mudanças..."
systemctl restart zabbix-agent2

echo "------------------------------------------------------------"
echo "Instalação e configuração completa concluídas com sucesso!"
echo " -> Servidor Zabbix configurado em: $SERVER_IP"
echo " -> Sistema detectado: $PRETTY_NAME"
echo " -> Scripts pinga.py e packet_loss.py configurados e prontos para uso."
echo "------------------------------------------------------------"