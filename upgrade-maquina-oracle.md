# Evoluir a máquina dentro do limite gratuito e rodar os dois sistemas juntos

## O que o plano gratuito da Oracle permite
- **Ampere A1 (ARM)**: até **4 OCPU e 24 GB de RAM somados**, em uma ou mais VMs. É o salto de verdade (de 1 GB para 24 GB).
- **AMD micro** (`E2.1.Micro`, a que você tem): até 2 VMs de 1 GB. Continuam gratuitas junto com a A1.
- **Disco**: 200 GB no total (a micro atual usa ~47; a A1 do script usa 100).

**Não dá para "crescer" a micro no lugar**: o formato (shape) dela é fixo. O caminho é criar a A1 ao lado, mover os dois sistemas e desligar a micro.

## Passo 1: criar a VM A1 (script)
A A1 gratuita costuma dar *"Out of host capacity"*, principalmente em Phoenix. O script `deploy/oci-criar-ampere.sh` tenta em loop até pegar vaga.

1. No console da Oracle abra o **Cloud Shell** (ícone `>_` no topo). O OCI CLI já está logado.
2. Reúna os dados:
   - Compartimento: o compartimento raiz (tenancy) → *Identity > Compartments* → copie o OCID.
   - Subnet: *Compute > Instances > (sua máquina) > Primary VNIC > Subnet* → copie o OCID (precisa ser pública).
3. Envie o script (menu do Cloud Shell → *Upload*) e rode, de preferência dentro do `tmux`:
   ```bash
   export OCI_COMPARTMENT_ID=ocid1.tenancy.oc1..xxxx
   export OCI_SUBNET_ID=ocid1.subnet.oc1.phx.xxxx
   export OCI_SSH_PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub    # gere com ssh-keygen -t ed25519 se não tiver
   bash oci-criar-ampere.sh
   ```
   Opcionais: `OCPUS=4 MEM_GB=24 DISCO_GB=100 INTERVALO=90`. Pode levar de minutos a dias para sair vaga.
4. Quando criar, pegue o **IP público** da nova VM no console.

> Se nunca sai vaga: contas só "Free Tier" têm menos prioridade. **Mudar para Pay As You Go** continua gratuito dentro dos limites do Always Free
> e costuma resolver a falta de capacidade. Se fizer isso, crie um alerta de orçamento (*Billing > Budgets*) em R$ 1 por segurança.

## Passo 2: preparar a nova máquina
```bash
scp deploy/preparar-maquina.sh ubuntu@IP-NOVO:~/ && ssh ubuntu@IP-NOVO bash preparar-maquina.sh
```
Instala Docker, libera as portas no firewall do sistema e cria as pastas. Depois, no painel da Oracle, libere **80 e 443** na Security List da subnet.
(Com 24 GB de RAM não é necessário swap; o script só cria se a memória for pequena.)

## Passo 3: mover os dois sistemas
Como a A1 é **ARM (aarch64)**, as imagens precisam ser multi-arquitetura. No workflow do Integra Teens troque
`PLATAFORMA: linux/amd64` por `linux/amd64,linux/arm64` (o build em ARM no CI é mais lento, mas só roda no push). Faça o mesmo no CI do TeensIBP.
Com 24 GB, também dá para construir direto na máquina nova se preferir.

**TeensIBP** (na máquina antiga, copie o banco):
```bash
docker exec -t teensibp-db pg_dump -U teensibp teensibp | gzip > teensibp.sql.gz
scp teensibp.sql.gz ubuntu@IP-NOVO:~/backups/
```
Na nova: suba o compose do TeensIBP (backend e frontend) como já faz hoje e restaure:
```bash
gunzip -c ~/backups/teensibp.sql.gz | docker exec -i teensibp-db psql -U teensibp teensibp
```
**Integra Teens**:
```bash
docker compose -f docker-compose.mesma-maquina.yml exec -T db pg_dump -U integra integra | gzip > integra.sql.gz   # na antiga
# na nova, depois de subir o compose:
gunzip -c integra.sql.gz | docker compose -f docker-compose.mesma-maquina.yml exec -T db psql -U integra integra
```
Mantenha os **mesmos** `BETTER_AUTH_SECRET` dos dois sistemas (senão as senhas/sessões não valem).

## Passo 4: apontar o tráfego
- **Mesmo domínio com `/integra`** (temporário): nada de DNS novo se o domínio apontar por túnel/Cloudflare; basta apontar para a máquina nova. Veja `docs/deploy-temporario-prefixo.md`.
- Teste com `curl --resolve seudominio.com.br:443:IP-NOVO https://seudominio.com.br/integra/entrar` **antes** de trocar o IP.
- Só depois de tudo funcionando, desligue (*Stop*) a micro. Guarde por alguns dias antes de apagar.

## Depois de rodar tudo junto
Com 24 GB os limites do compose (`mem_limit`) podem subir à vontade (app 1 GB, banco 1 GB) e dá para compartilhar um único Postgres,
mas dois bancos separados continuam sendo o mais simples e seguro.
