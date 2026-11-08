#!/usr/bin/env bash
# Tenta criar uma VM ARM (VM.Standard.A1.Flex, Always Free) na Oracle Cloud até haver capacidade.
#
# Descobre sozinho o que dá para descobrir (compartimento, domínios de disponibilidade, sub-rede,
# imagem Ubuntu para ARM) e repete em todos os domínios até uma tentativa funcionar. Depois
# imprime o IP público. Pensado para rodar por horas ou dias: sem capacidade, espera e tenta de novo.
#
# Requisitos: OCI CLI instalado e configurado (`oci setup config`). Nada de chave ou senha aqui:
# o script só usa o que o OCI CLI já tem em ~/.oci/config.
#
# Uso: ./create-arm-instance.sh --help

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME="mangr-arm"
OCPUS=2
MEMORY=12
BOOT_GB=100
INTERVAL=60
OS_VERSION="24.04"
KEY_FILE=""
SUBNET_ID=""
COMPARTMENT_ID=""
IMAGE_ID=""
ONLY_AD=""
USER_DATA="$HERE/cloud-init.yaml"
USE_NSG=1
MAX_UNKNOWN=5
SHAPE="VM.Standard.A1.Flex"

usage() {
  cat <<EOF
Uso: $(basename "$0") [opções]

  --name NOME           nome da instância (padrão: $NAME)
  --ocpus N             CPUs ARM, de 1 a 4 (padrão: $OCPUS). Menos CPU costuma achar vaga mais rápido
  --memory GB           memória em GB, até 24 e no máximo 6 por CPU (padrão: $MEMORY)
  --boot-gb GB          disco de boot em GB, mínimo 50 (padrão: $BOOT_GB). O plano grátis soma ~200 GB
  --interval SEG        espera entre rodadas de tentativas (padrão: $INTERVAL, mais um sorteio de 0-14)
  --ssh-key ARQUIVO     chave pública SSH (padrão: ~/.ssh/id_ed25519.pub ou id_rsa.pub)
  --os-version V        versão do Ubuntu (padrão: $OS_VERSION)
  --ad NOME             tenta só este domínio de disponibilidade (padrão: todos, em rodízio)
  --compartment OCID    compartimento (padrão: o raiz da tenancy, lido de ~/.oci/config)
  --subnet OCID         sub-rede (padrão: a primeira sub-rede pública)
  --image OCID          imagem (padrão: o Ubuntu ARM mais recente da versão pedida)
  --user-data ARQUIVO   cloud-init (padrão: cloud-init.yaml ao lado do script)
  --no-nsg              não cria nem anexa o grupo de segurança que abre as portas 80 e 443
  -h, --help            esta ajuda

Para deixar rodando em segundo plano:
  nohup ./$(basename "$0") > oci-retry.log 2>&1 &
EOF
}

die() {
  echo "ERRO: $*" >&2
  exit 1
}
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --ocpus) OCPUS="${2:?}"; shift 2 ;;
    --memory) MEMORY="${2:?}"; shift 2 ;;
    --boot-gb) BOOT_GB="${2:?}"; shift 2 ;;
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    --ssh-key) KEY_FILE="${2:?}"; shift 2 ;;
    --os-version) OS_VERSION="${2:?}"; shift 2 ;;
    --ad) ONLY_AD="${2:?}"; shift 2 ;;
    --compartment) COMPARTMENT_ID="${2:?}"; shift 2 ;;
    --subnet) SUBNET_ID="${2:?}"; shift 2 ;;
    --image) IMAGE_ID="${2:?}"; shift 2 ;;
    --user-data) USER_DATA="${2:?}"; shift 2 ;;
    --no-nsg) USE_NSG=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "opção desconhecida: $1" ;;
  esac
done

command -v oci > /dev/null 2>&1 || die "OCI CLI não encontrado. Instale e rode 'oci setup config' (veja README.md)."

is_int() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for v in "$OCPUS" "$MEMORY" "$BOOT_GB" "$INTERVAL"; do is_int "$v" || die "valor numérico inválido: $v"; done
[ "$OCPUS" -ge 1 ] && [ "$OCPUS" -le 4 ] || die "--ocpus deve ficar entre 1 e 4 (limite do plano grátis)"
[ "$MEMORY" -ge 1 ] && [ "$MEMORY" -le 24 ] || die "--memory deve ficar entre 1 e 24 (limite do plano grátis)"
[ "$MEMORY" -le $((OCPUS * 6)) ] || die "--memory acima de 6 GB por CPU: use no máximo $((OCPUS * 6)) para $OCPUS CPU(s)"
[ "$BOOT_GB" -ge 50 ] || die "--boot-gb deve ser pelo menos 50"

if [ -z "$KEY_FILE" ]; then
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && KEY_FILE="$k" && break
  done
fi
[ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] || die "chave pública SSH não encontrada. Crie uma com: ssh-keygen -t ed25519"
[ -f "$USER_DATA" ] || die "cloud-init não encontrado: $USER_DATA"

if [ -z "$COMPARTMENT_ID" ]; then
  CFG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  [ -f "$CFG" ] || die "config do OCI CLI não encontrada em $CFG (rode 'oci setup config')"
  COMPARTMENT_ID="$(sed -n 's/^tenancy *= *//p' "$CFG" | head -1 | tr -d '\r')"
  [ -n "$COMPARTMENT_ID" ] || die "não achei 'tenancy' em $CFG; passe --compartment"
fi

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"; echo; log "interrompido."; exit 130' INT TERM
trap 'rm -f "$ERR_FILE"' EXIT

# --- 1. Não criar duas vezes ------------------------------------------------------------------
existing="$(oci compute instance list --compartment-id "$COMPARTMENT_ID" --display-name "$NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`] | length(@)' --raw-output 2> "$ERR_FILE")" \
  || die "falha ao listar instâncias: $(cat "$ERR_FILE")"
if [ "${existing:-0}" != "0" ]; then
  die "já existe uma instância chamada '$NAME' (ou ela está em criação). Nada a fazer."
fi

# --- 2. Descobrir o que falta ------------------------------------------------------------------
if [ -n "$ONLY_AD" ]; then
  ADS=("$ONLY_AD")
else
  ads_json="$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query 'data[].name' 2> "$ERR_FILE")" \
    || die "falha ao listar domínios de disponibilidade: $(cat "$ERR_FILE")"
  ADS=()
  while IFS= read -r line; do ADS+=("$line"); done < <(echo "$ads_json" | grep -o '"[^"]*"' | tr -d '"')
fi
[ "${#ADS[@]}" -gt 0 ] || die "nenhum domínio de disponibilidade encontrado"

if [ -z "$SUBNET_ID" ]; then
  SUBNET_ID="$(oci network subnet list --compartment-id "$COMPARTMENT_ID" \
    --query 'data[?"prohibit-public-ip-on-vnic"==`false`] | [0].id' --raw-output 2> "$ERR_FILE")" \
    || die "falha ao listar sub-redes: $(cat "$ERR_FILE")"
  { [ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "null" ]; } || die "nenhuma sub-rede pública encontrada; passe --subnet"
fi

if [ -z "$IMAGE_ID" ]; then
  IMAGE_ID="$(oci compute image list --compartment-id "$COMPARTMENT_ID" \
    --operating-system "Canonical Ubuntu" --operating-system-version "$OS_VERSION" --shape "$SHAPE" \
    --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output 2> "$ERR_FILE")" \
    || die "falha ao procurar a imagem: $(cat "$ERR_FILE")"
  { [ -n "$IMAGE_ID" ] && [ "$IMAGE_ID" != "null" ]; } || die "nenhuma imagem Ubuntu $OS_VERSION para ARM; passe --image ou --os-version"
fi

NSG_ARGS=()
if [ "$USE_NSG" -eq 1 ]; then
  vcn_id="$(oci network subnet get --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output 2> "$ERR_FILE")" \
    || die "falha ao ler a sub-rede: $(cat "$ERR_FILE")"
  nsg_name="$NAME-web"
  nsg_id="$(oci network nsg list --compartment-id "$COMPARTMENT_ID" --vcn-id "$vcn_id" --display-name "$nsg_name" \
    --query 'data[0].id' --raw-output 2> "$ERR_FILE")" || die "falha ao listar grupos de segurança: $(cat "$ERR_FILE")"
  if [ -z "$nsg_id" ] || [ "$nsg_id" = "null" ]; then
    log "criando o grupo de segurança '$nsg_name' (portas 80 e 443 abertas para a internet)"
    nsg_id="$(oci network nsg create --compartment-id "$COMPARTMENT_ID" --vcn-id "$vcn_id" --display-name "$nsg_name" \
      --query 'data.id' --raw-output 2> "$ERR_FILE")" || die "falha ao criar o grupo de segurança: $(cat "$ERR_FILE")"
    oci network nsg rules add --nsg-id "$nsg_id" --security-rules '[
      {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","description":"http",
       "tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
      {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","description":"https",
       "tcpOptions":{"destinationPortRange":{"min":443,"max":443}}}]' > /dev/null 2> "$ERR_FILE" \
      || die "falha ao abrir as portas: $(cat "$ERR_FILE")"
  fi
  NSG_ARGS=(--nsg-ids "[\"$nsg_id\"]")
fi

log "alvo: $NAME | $OCPUS CPU ARM, ${MEMORY} GB de RAM, disco ${BOOT_GB} GB | Ubuntu $OS_VERSION"
log "domínios: ${ADS[*]}"
log "tentando a cada ~${INTERVAL}s até conseguir (Ctrl+C para parar)"

# --- 3. Tentar até conseguir -------------------------------------------------------------------
attempt=0
unknown=0
while true; do
  attempt=$((attempt + 1))
  for ad in "${ADS[@]}"; do
    out="$(oci compute instance launch \
      --availability-domain "$ad" \
      --compartment-id "$COMPARTMENT_ID" \
      --shape "$SHAPE" \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --display-name "$NAME" \
      --boot-volume-size-in-gbs "$BOOT_GB" \
      --ssh-authorized-keys-file "$KEY_FILE" \
      --user-data-file "$USER_DATA" \
      "${NSG_ARGS[@]}" \
      --query 'data.id' --raw-output 2> "$ERR_FILE")"
    rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then
      instance_id="$out"
      log "CRIADA em $ad: $instance_id"
      break 2
    fi

    err="$(cat "$ERR_FILE")"
    case "$err" in
      *"Out of host capacity"* | *OutOfHostCapacity* | *"Out of capacity"*)
        log "tentativa $attempt: sem capacidade em $ad"
        unknown=0
        ;;
      *TooManyRequests* | *'"status": 429'*)
        log "tentativa $attempt: limite de requisições da Oracle, esperando mais"
        sleep $((INTERVAL * 3))
        ;;
      *LimitExceeded*)
        die "limite do plano gratuito atingido (você já usa as CPUs/memória ARM grátis?):
$err"
        ;;
      *NotAuthenticated* | *'"status": 401'* | *NotAuthorizedOrNotFound* | *'"status": 404'* | *NotAuthorized*)
        die "a Oracle recusou as credenciais ou algum OCID não existe. Confira 'oci setup config' e os OCIDs:
$err"
        ;;
      *InternalError* | *'"status": 500'* | *'"status": 502'* | *'"status": 503'*)
        log "tentativa $attempt: erro interno da Oracle em $ad (costuma ser falta de capacidade)"
        ;;
      *)
        unknown=$((unknown + 1))
        log "tentativa $attempt: erro inesperado em $ad ($unknown/$MAX_UNKNOWN): $(echo "$err" | tr '\n' ' ' | cut -c1-300)"
        [ "$unknown" -ge "$MAX_UNKNOWN" ] && die "erros inesperados demais; parando."
        ;;
    esac
  done
  sleep $((INTERVAL + RANDOM % 15))
done

# --- 4. Esperar subir e mostrar o IP ----------------------------------------------------------
log "aguardando a instância ficar RUNNING..."
for _ in $(seq 1 60); do
  state="$(oci compute instance get --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output 2> /dev/null)"
  [ "$state" = "RUNNING" ] && break
  sleep 10
done
ip="$(oci compute instance list-vnics --instance-id "$instance_id" --query 'data[0]."public-ip"' --raw-output 2> /dev/null)"
log "estado: ${state:-desconhecido} | IP público: ${ip:-ainda sem IP}"
echo
echo "Pronto. Entre com:  ssh ubuntu@${ip:-<IP>}"
echo "O cloud-init instala Docker e abre as portas; leva uns 2-3 minutos. Acompanhe com:"
echo "  ssh ubuntu@${ip:-<IP>} 'sudo cloud-init status --wait'"
exit 0
