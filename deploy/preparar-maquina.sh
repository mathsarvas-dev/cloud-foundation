#!/usr/bin/env bash
# Prepara uma máquina Ubuntu nova (Oracle) para rodar os dois sistemas com Docker.
# Rode UMA vez, logado por SSH na máquina nova:   bash preparar-maquina.sh
# É seguro repetir.
set -euo pipefail

echo "==> Atualizando pacotes"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg ufw iptables-persistent unattended-upgrades

echo "==> Instalando Docker (se ainda não existir)"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$USER"

echo "==> Swap (só se a memória for pequena, < 4 GB)"
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_MB" -lt 4096 ] && ! swapon --show | grep -q swapfile; then
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "    swap de 2 GB criado"
else
  echo "    ${MEM_MB} MB de RAM: swap não necessário (ou já existe)"
fi

echo "==> Firewall do sistema: libera 22, 80 e 443 (o Ubuntu da Oracle bloqueia o resto por padrão)"
for porta in 22 80 443; do
  sudo iptables -C INPUT -p tcp --dport "$porta" -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport "$porta" -j ACCEPT
done
sudo netfilter-persistent save >/dev/null

echo "==> Pastas dos dois sistemas"
mkdir -p ~/teensibp ~/integra-teens ~/backups

echo "==> Atualizações de segurança automáticas"
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

cat <<EOF

Pronto. Falta, no painel da Oracle (Security List / NSG da subnet): permitir entrada TCP nas portas 80 e 443.
Saia e entre de novo no SSH para o grupo "docker" valer (ou rode: newgrp docker).

Arquitetura: $(uname -m) | ${MEM_MB} MB RAM | $(nproc) CPU(s)
Próximo passo: docs/upgrade-maquina-oracle.md (seção "Mover os dois sistemas").
EOF
