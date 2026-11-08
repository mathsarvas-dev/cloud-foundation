# cloud-foundation

Base de infraestrutura que uso para publicar meus sistemas (Mangr, Integra Teens e Acampamento TeensIBP) na **Oracle Cloud Infrastructure**, dentro do plano **Always Free**.

## Objetivo

Rodar produção com custo próximo de zero, sem prender os projetos a um provedor: a mesma imagem Docker roda em desenvolvimento e em produção.

## Arquitetura

```
 Cloudflare (DNS)  ──►  VM Ampere A1 (ARM, até 4 OCPU / 24 GB)
                          └─ Docker Compose
                              ├─ Caddy  (80/443, HTTPS automático)
                              ├─ app    (imagem do GHCR)
                              └─ Postgres 17 (rede interna, sem porta exposta)

 GitHub Actions ──► build multi-arch (amd64 + arm64) ──► GitHub Container Registry
```

## Componentes

| Peça | Função |
|---|---|
| `oci/create-arm-instance.sh` | Cria a VM A1 via OCI CLI, tentando em todos os domínios até haver capacidade, e cria o grupo de segurança com 80/443 |
| `oci/cloud-init.yaml` | Primeiro boot: Docker, fuso de São Paulo, swap, firewall da máquina |
| `deploy/Caddyfile` | Proxy reverso com HTTPS (Let's Encrypt) e cabeçalhos HSTS, nosniff, X-Frame-Options |
| `deploy/docker-compose.prod.yml` | Caddy, app e Postgres com healthchecks e limites de memória |
| `deploy/backup.sh` | Dump agendado do Postgres |
| `deploy/preparar-maquina.sh` | Docker, firewall e pastas em máquina nova |
| Migração | `pg_dump` e restore entre máquinas, mantendo o mesmo `BETTER_AUTH_SECRET` |

## Decisões

- **Oracle Always Free:** 4 OCPU ARM e 24 GB de RAM gratuitos, bem acima de qualquer opção grátis equivalente.
- **Container em vez de serverless:** sem cold start, sem lock-in e com workers que drenam fila.
- **Postgres em container:** o driver padrão permite migrar para banco gerenciado só trocando a `DATABASE_URL`.
- **Caddy em vez de nginx + certbot:** certificado e renovação automáticos com um arquivo de poucas linhas.
- **Sem Kubernetes:** a escala atual não justifica o custo operacional.
- **Segurança:** banco sem porta exposta, segredos fora do repositório, chaves OCI só na máquina local.

## Autor

Matheus Mosconi Sarvas
