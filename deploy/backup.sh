#!/usr/bin/env bash
# Backup dos bancos do Integra Teens e do TeensIBP (pg_dump compactado), com rodízio.
#
# Uso manual:   bash backup.sh
# Agendado (todo dia às 03:30), com `crontab -e`:
#   30 3 * * * bash $HOME/integra-teens/backup.sh >> $HOME/backups/backup.log 2>&1
#
# Variáveis (opcionais):
#   DESTINO=~/backups          pasta dos arquivos
#   MANTER=14                  quantos dias guardar
#   COMPOSE_INTEGRA=~/integra-teens/docker-compose.mesma-maquina.yml   (ou docker-compose.prod.yml)
#   CONTAINER_TEENSIBP=teensibp-db   USUARIO_TEENSIBP=teensibp   BANCO_TEENSIBP=teensibp
set -u

DESTINO="${DESTINO:-$HOME/backups}"
MANTER="${MANTER:-14}"
COMPOSE_INTEGRA="${COMPOSE_INTEGRA:-$HOME/integra-teens/docker-compose.mesma-maquina.yml}"
[ -f "$COMPOSE_INTEGRA" ] || COMPOSE_INTEGRA="$HOME/integra-teens/docker-compose.prod.yml"
CONTAINER_TEENSIBP="${CONTAINER_TEENSIBP:-teensibp-db}"
USUARIO_TEENSIBP="${USUARIO_TEENSIBP:-teensibp}"
BANCO_TEENSIBP="${BANCO_TEENSIBP:-teensibp}"
DATA=$(date +%F_%H%M)
mkdir -p "$DESTINO"
erros=0

echo "[$(date '+%F %T')] backup iniciado"

# --- Integra Teens
if [ -f "$COMPOSE_INTEGRA" ]; then
  ARQ="$DESTINO/integra-$DATA.sql.gz"
  if docker compose -f "$COMPOSE_INTEGRA" exec -T db pg_dump -U integra integra | gzip > "$ARQ" && [ -s "$ARQ" ]; then
    echo "  integra:   $(du -h "$ARQ" | cut -f1)  $ARQ"
  else
    echo "  ERRO no backup do Integra Teens"; rm -f "$ARQ"; erros=$((erros + 1))
  fi
else
  echo "  (Integra Teens: compose não encontrado, pulei)"
fi

# --- TeensIBP
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_TEENSIBP"; then
  ARQ="$DESTINO/teensibp-$DATA.sql.gz"
  if docker exec -t "$CONTAINER_TEENSIBP" pg_dump -U "$USUARIO_TEENSIBP" "$BANCO_TEENSIBP" | gzip > "$ARQ" && [ -s "$ARQ" ]; then
    echo "  teensibp:  $(du -h "$ARQ" | cut -f1)  $ARQ"
  else
    echo "  ERRO no backup do TeensIBP"; rm -f "$ARQ"; erros=$((erros + 1))
  fi
else
  echo "  (TeensIBP: container $CONTAINER_TEENSIBP não está rodando, pulei)"
fi

# --- Rodízio
find "$DESTINO" -name '*.sql.gz' -mtime +"$MANTER" -delete
echo "[$(date '+%F %T')] fim (erros: $erros). Guardando $MANTER dias em $DESTINO"
echo "LEMBRETE: uma cópia só na mesma máquina não é backup completo. Leve os arquivos para fora (scp/rsync ou Object Storage)."
exit "$erros"
