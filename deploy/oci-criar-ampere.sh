#!/usr/bin/env bash
# Tenta criar uma VM Ampere A1 (Always Free) na Oracle Cloud, repetindo até conseguir.
#
# Por quê: a A1 gratuita (até 4 OCPU e 24 GB no total) costuma dar "Out of host capacity".
# O jeito de pegar uma vaga é tentar de tempos em tempos. Este script faz isso por você.
#
# Onde rodar: no Oracle Cloud Shell (já tem o OCI CLI logado) ou na sua máquina com `oci setup config`.
# Use `tmux`/`nohup` se for deixar horas rodando (o Cloud Shell fecha a sessão por inatividade).
#
# Uso:
#   export OCI_COMPARTMENT_ID=ocid1.compartment...   # no seu caso, o compartimento raiz (tenancy)
#   export OCI_SUBNET_ID=ocid1.subnet...             # subnet PÚBLICA da VCN onde está a máquina atual
#   export OCI_SSH_PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub
#   bash oci-criar-ampere.sh
#
# Opcionais: OCPUS=4  MEM_GB=24  DISCO_GB=100  NOME=integra-a1  INTERVALO=90
set -u

: "${OCI_COMPARTMENT_ID:?defina OCI_COMPARTMENT_ID}"
: "${OCI_SUBNET_ID:?defina OCI_SUBNET_ID}"
CHAVE="${OCI_SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
OCPUS="${OCPUS:-4}"
MEM_GB="${MEM_GB:-24}"
DISCO_GB="${DISCO_GB:-100}"      # limite gratuito: 200 GB somando todos os discos de boot (a micro atual usa ~47)
NOME="${NOME:-integra-a1}"
INTERVALO="${INTERVALO:-90}"
SHAPE="VM.Standard.A1.Flex"

command -v oci >/dev/null || { echo "OCI CLI não encontrado. Use o Cloud Shell ou instale: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm"; exit 1; }
[ -f "$CHAVE" ] || { echo "Chave pública não encontrada em $CHAVE (gere com: ssh-keygen -t ed25519)"; exit 1; }

echo "==> Conferindo o limite gratuito (A1: no máximo 4 OCPU e 24 GB somados)"
if [ "$OCPUS" -gt 4 ] || [ "$MEM_GB" -gt 24 ]; then echo "Pedido acima do limite gratuito (4 OCPU / 24 GB)."; exit 1; fi

echo "==> Procurando a imagem Ubuntu 22.04 para ARM (aarch64)"
IMAGEM=$(oci compute image list --compartment-id "$OCI_COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" --shape "$SHAPE" \
  --sort-by TIMECREATED --sort-order DESC --limit 1 --query 'data[0].id' --raw-output) || exit 1
[ -n "$IMAGEM" ] && [ "$IMAGEM" != "null" ] || { echo "Imagem não encontrada."; exit 1; }
echo "    $IMAGEM"

ADS=$(oci iam availability-domain list --compartment-id "$OCI_COMPARTMENT_ID" --query 'data[].name' --raw-output | tr -d '[]," ' | tr '\n' ' ')
echo "==> Domínios de disponibilidade: $ADS"

tentativa=0
while true; do
  for AD in $ADS; do
    tentativa=$((tentativa + 1))
    echo "[$(date '+%F %T')] tentativa $tentativa em $AD ($OCPUS OCPU / ${MEM_GB} GB / ${DISCO_GB} GB)"
    SAIDA=$(oci compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$OCI_COMPARTMENT_ID" \
      --shape "$SHAPE" \
      --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEM_GB}" \
      --image-id "$IMAGEM" \
      --subnet-id "$OCI_SUBNET_ID" \
      --assign-public-ip true \
      --display-name "$NOME" \
      --boot-volume-size-in-gbs "$DISCO_GB" \
      --ssh-authorized-keys-file "$CHAVE" 2>&1)
    if echo "$SAIDA" | grep -q '"lifecycle-state"'; then
      echo "==> CRIADA! Aguarde ~2 min e veja o IP público no console (Compute > Instances)."
      echo "$SAIDA" | grep -E '"display-name"|"id"|"lifecycle-state"'
      exit 0
    fi
    if echo "$SAIDA" | grep -qiE 'Out of host capacity|OutOfHostCapacity|capacity'; then
      echo "    sem capacidade agora"
    elif echo "$SAIDA" | grep -qiE 'LimitExceeded|QuotaExceeded'; then
      echo "    LIMITE/COTA recusou o pedido. Mensagem completa da Oracle:"; echo "$SAIDA"
      echo "    Veja a cota de A1 com:"
      echo "      oci limits resource-availability get --service-name compute --limit-name standard-a1-core-count --compartment-id \"$OCI_COMPARTMENT_ID\" --availability-domain \"$AD\""
      echo "    (disponivel 0 = conta sem cota de A1; Pay As You Go costuma liberar, sem custo dentro do Always Free)"; exit 1
    elif echo "$SAIDA" | grep -qiE 'NotAuthorized|NotAuthenticated|InvalidParameter'; then
      echo "    ERRO de permissão/parâmetro:"; echo "$SAIDA" | tail -8; exit 1
    else
      echo "    resposta inesperada (vou tentar de novo):"; echo "$SAIDA" | tail -3
    fi
  done
  sleep "$INTERVALO"
done
