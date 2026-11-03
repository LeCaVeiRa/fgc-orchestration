# 🎮 FCG - FIAP Cloud Games

Plataforma de games educacionais desenvolvida como **Tech Challenge** da pós-graduação **Arquitetura de Sistemas .NET – FIAP**.

Arquitetura de **microsserviços orientada a eventos**, com comunicação assíncrona via **RabbitMQ**/**Amazon MQ** e **MassTransit**, gateway único via **Kong**, observabilidade via **Prometheus + Grafana**, persistência poliglota (**PostgreSQL**, **DynamoDB**, **Redis**) e busca textual com **OpenSearch**.
Em produção roda na **AWS**: EKS, ECR, RDS, ElastiCache, OpenSearch Service, Amazon MQ, Lambda e Secrets Manager, provisionados com **Terraform** ([fgc-infra](../fgc-infra)). O deploy é automatizado com **GitHub Actions**.

---

## 👥 Squad 8 – Turma 12NETT

| Integrante | GitHub |
|---|---|
| Yan Santos Wendt | |

---

## 🏗️ Arquitetura

```text
                         ┌─────────────┐
   cliente ───────────►  │  Kong (8000) │  (único ponto de entrada, valida JWT)
                         └──────┬──────┘
                 ┌──────────────┼──────────────────────┐
                 ▼              ▼                       ▼
         ┌────────────┐ ┌──────────────┐      ┌──────────────────────┐
         │ Users API  │ │ Catalog API  │      │ Notifications History │
         │ (port 5038)│ │ (port 5070)  │      │ Lambda (API Gateway)  │
         └─────┬──────┘ └──────┬───────┘      └───────────▲──────────┘
               │  UserCreatedEvent               │                 │
               │                                 │ PaymentProcessedEvent
               ▼                                 ▼                 │
        ┌─────────────────────────────────────────────┐   ┌────────┴─────────┐
        │        RabbitMQ (local) / Amazon MQ (prod)   │──►│ Notifications     │
        └─────────────────────────────────────────────┘   │ EventProcessor    │
               ▲                                            │ Lambda (welcome/  │
               │ PaymentProcessedEvent                       │ purchase e-mail)  │
        ┌──────┴───────┐                                    └───────────────────┘
        │ Payments API │
        │ (port 5050)  │
        └──────────────┘
```

### Fluxos

**1. Cadastro de Usuário**
- Users API cadastra → publica `UserCreatedEvent` (e grava log do evento no DynamoDB)
- Notifications EventProcessor (Lambda) consome → loga e-mail de boas-vindas, grava no DynamoDB

**2. Compra de Jogo**
- Payments API processa pagamento → publica `PaymentProcessedEvent`
- Catalog API consome → se `Approved`, adiciona jogo à biblioteca (e grava log do evento no DynamoDB)
- Notifications EventProcessor (Lambda) consome → se `Approved`, loga e-mail de confirmação

**3. Consulta de histórico de notificações**
- `GET /notifications` via Kong → Notifications HistoryApi (Lambda, atrás de API Gateway) → lê do DynamoDB
- Autenticação (JWT válido) no Kong; autorização (role Admin) dentro da própria Lambda

### Arquitetura na AWS (us-east-2)

```text
 cliente ──HTTP──► ALB (AWS Load Balancer Controller, Ingress)
                    │
                    ▼  namespace fgc no EKS (2 nós, ClusterIP)
                 Kong ×2 ──► Users API ×2 ──► RDS PostgreSQL (fgc_users)
                    │    ├──► Catalog API ×2 ─► RDS PostgreSQL (fgc_catalog), DynamoDB Orders,
                    │    │                       OpenSearch (busca), ElastiCache Redis (cache)
                    │    └──► Payments API ×2
                    └──► /notifications ──► API Gateway ──► Lambda HistoryApi ──► DynamoDB FgcNotifications

 APIs ◄──AMQPS──► Amazon MQ (RabbitMQ) ──Event Source Mapping──► Lambda EventProcessor
 Pods ──EKS Pod Identity──► DynamoDB FgcEventLog / Secrets Manager (via External Secrets Operator)
```

- **Segredos:** nenhum nos manifestos nem no código. O Terraform gera as senhas e as publica no Secrets Manager (`fgc/*`). O External Secrets Operator sincroniza esses valores como Secrets do Kubernetes. Localmente, os valores vêm do `.env`.
- **Credenciais AWS dos pods:** EKS Pod Identity, sem chaves.
- **Deploy sem indisponibilidade:**
  - Deployments com 2 réplicas, `maxUnavailable: 0` e `maxSurge: 1`.
  - Readiness probe ligada a `/health/ready`.
  - `preStop` nos pods e readiness gate do ALB no Kong.
  - Migrations em um Job executado antes do rollout.
- **Observabilidade:** kube-prometheus-stack (Prometheus e Grafana), com ServiceMonitors das APIs e o dashboard "FGC Services".

---

## 📦 Repositórios

| Microsserviço | Repositório | Tecnologias |
|---|---|---|
| **Users API** | [fgc-users-api](https://github.com/LeCaVeiRa/fgc-users-api) | .NET 8, EF Core + PostgreSQL, JWT (emissor), MassTransit, DynamoDB, Redis |
| **Catalog API** | [fgc-catalog-api](https://github.com/LeCaVeiRa/fgc-catalog-api) | .NET 8, EF Core + PostgreSQL, JWT, MassTransit, DynamoDB, Redis, OpenSearch |
| **Payments API** | [fgc-payments-api](https://github.com/LeCaVeiRa/fgc-payments-api) | .NET 8, MassTransit |
| **Notifications Lambda** | [fgc-notifications-lambda](https://github.com/LeCaVeiRa/fgc-notifications-lambda) | .NET 8, AWS SAM, Lambda, Amazon MQ, DynamoDB, API Gateway |
| **Message Contracts** | [fgc-message-contracts](https://github.com/LeCaVeiRa/fgc-message-contracts) | Pacote NuGet local de eventos |
| **Infraestrutura** | [fgc-infra](../fgc-infra) | Terraform (VPC, EKS, RDS, ElastiCache, OpenSearch, DynamoDB, Amazon MQ, Secrets Manager, ECR) |
| **Orquestração** | *(este repositório)* | Docker Compose, manifestos K8s do Kong e da plataforma, scripts de deploy na AWS, Prometheus, Grafana |

---

## 🐳 Execução com Docker

### Pré-requisitos
- [Docker](https://docs.docker.com/engine/install/) + Docker Compose
- `.env` neste repositório (não versionado): `cp .env.example .env` e preencha os segredos (chave JWT, senhas do Postgres, RabbitMQ e Grafana). Sem eles o `docker-compose up` falha com a mensagem indicando a variável ausente — não há valores default.

### Subir todos os serviços
```bash
docker-compose up -d --build
```

Isso sobe:

| Serviço | Porta | Descrição |
|---|---|---|
| rabbitmq | 5672 (AMQP), 15672 (UI) | Message broker local |
| fgc-users-api | 5038 | Cadastro e autenticação |
| fgc-catalog-api | 5070 | CRUD de jogos e compra |
| fgc-payments-api | 5050 | Processamento de pagamento (scaffold) |
| dynamodb-local | 8500 (host) → 8000 (container) | DynamoDB local (log de eventos, `FgcEventLog`) |
| redis | 6379 | Cache de `GET /games` |
| postgres | 5432 | PostgreSQL (databases `fgc_users` e `fgc_catalog`) |
| opensearch | 9200 | Busca de jogos (`GET /search`) |
| kong | 8000\*/8443/8001 | API Gateway (proxy + Admin API) |
| prometheus | 9090 | Métricas |
| grafana | 3000 | Dashboards |

\* Kong usa a porta `8000` para o proxy; ajuste a porta publicada de outro serviço se houver conflito local.

Verificar logs: `docker-compose logs -f`
Parar tudo: `docker-compose down`

### Acessar interfaces
- Todo tráfego de API deve passar pelo Kong: http://localhost:8000
- Swagger Users API (direto, sem gateway): http://localhost:5038/swagger
- Swagger Catalog API (direto, sem gateway): http://localhost:5070/swagger
- RabbitMQ Management: http://localhost:15672 (`RABBITMQ_USER`/`RABBITMQ_PASSWORD` do `.env`)
- Kong Admin API: http://localhost:8001

---

## ☸️ Kubernetes (EKS)

A infraestrutura é criada pelo Terraform em `fgc-infra` (ver o README de lá: camadas, custo e ciclo apply/destroy). Os manifestos são kustomize:

| Onde | Conteúdo |
|---|---|
| `fgc-*-api/k8s/` | ServiceAccount (Pod Identity), ConfigMap (só valores estáticos) e ExternalSecret |
| `fgc-users-api/k8s/migrate/`, `fgc-catalog-api/k8s/migrate/` | Job `--migrate` (migrations e, no Users, o primeiro Admin) |
| `fgc-*-api/k8s/app/` | Deployment, Service ClusterIP e ServiceMonitor |
| `k8s/platform/` (este repo) | ClusterSecretStore do Secrets Manager |
| `k8s/kong/` (este repo) | Kong, ExternalSecret do JWT e Ingress do ALB |

A tag das imagens no ECR é o SHA do commit. Nos manifestos ela aparece como o placeholder `DEPLOY_TAG`, substituído no deploy.

### Sessão completa na AWS
Com `AWS_PROFILE=fgc`, no Git Bash (Windows) ou bash:

```bash
cd ../fgc-infra/env && terraform plan -out env.tfplan && terraform apply env.tfplan   # ~30 min
cd ../../fgc-orchestration && ./scripts/deploy-aws.sh   # imagens, migrations, apps, Lambda (SAM), Kong, ALB
cd ../fgc-infra/messaging && terraform plan -out m.tfplan && terraform apply m.tfplan # fila + trigger da Lambda
cd ../../fgc-orchestration && ./scripts/smoke-aws.sh    # roteiro ponta a ponta via ALB
```

Encerramento, **nesta ordem**:

```bash
cd ../fgc-infra/messaging && terraform plan -destroy -out d.tfplan && terraform apply d.tfplan
cd ../../fgc-orchestration && ./scripts/teardown-aws.sh # remove o ALB, os ExternalSecrets e o stack SAM
cd ../fgc-infra/env && terraform plan -destroy -out d.tfplan && terraform apply d.tfplan
```

Grafana no cluster: `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80`. O usuário e a senha ficam no secret `fgc/grafana` do Secrets Manager.

---

## 🔧 Variáveis de Ambiente

O mesmo código roda local e na AWS; só muda a configuração. Segredos não têm valor padrão: se faltarem, a API não sobe e informa qual variável está faltando (`Missing configuration '...' (env ...)`).

| Variável | Serviços | Local (compose, `.env`) | AWS (EKS) |
|---|---|---|---|
| `Jwt__Key` | Users, Catalog | `JWT_KEY` do `.env` | Secret `fgc/users`, `fgc/catalog` |
| `ConnectionStrings__UserDb` / `__CatalogDb` | Users / Catalog | Postgres do compose | RDS (`SSL Mode=Require`) |
| `RabbitMq__Host`, `__Username`, `__Password` | Users, Catalog, Payments | `rabbitmq`, `RABBITMQ_USER/PASSWORD` | Amazon MQ (Secret) |
| `RabbitMq__UseSsl` / `__Port` | Users, Catalog, Payments | `false` / `5672` | `true` / `5671` (ConfigMap) |
| `Redis__ConnectionString` | Users, Catalog | `redis:6379,connectTimeout=1000,...` | ElastiCache com `ssl=true,password=...` (Secret) |
| `OpenSearch__Url` (+ `__Username/__Password` opcionais) | Catalog | `http://opensearch:9200` | Domínio em VPC, HTTPS (Secret) |
| `AWS__DynamoDB__ServiceUrl` | Users, Catalog | `http://dynamodb-local:8000` (cria as tabelas) | ausente: AWS real via Pod Identity |
| `AWS_REGION` | Users, Catalog | `us-east-1` | `us-east-2` (ConfigMap) |
| `Database__MigrateOnStartup` | Users, Catalog | `true` (padrão) | `false`: quem migra é o Job `--migrate` |
| `Seed__AdminEmail` / `Seed__AdminPassword` | Users (`--migrate`) | — (`/setup/first-admin` em Development) | Secret `fgc/users` |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | todos | `true` (atrás do Kong) | `true` (atrás do ALB e do Kong) |
| `Https__Redirect` | todos | ausente (TLS termina no proxy) | ausente |

Health checks:
- `/health` e `/health/live`: o processo está vivo.
- `/health/ready`: banco e broker. Falha de Redis ou DynamoDB só marca o serviço como *Degraded*, e a resposta continua 200.

---

## 🚀 CI/CD (GitHub Actions)

`.github/workflows/ci-cd.yml` em `fgc-users-api` e `fgc-catalog-api`:
- **Pull request:** restore, build e testes. Os testes de integração usam fakes em memória, então não precisam de broker, Redis, DynamoDB nem OpenSearch.
- **Push em `main`:**
  1. Testes.
  2. Build da imagem com tag = SHA.
  3. **Trivy**: falha se houver vulnerabilidade CRITICAL com correção disponível.
  4. Push no ECR.
  5. Job de migração.
  6. `kubectl set image` e `rollout status`, com `rollout undo` se falhar.
  Sem cluster ativo (infra destruída), o pipeline publica a imagem e pula o deploy com um aviso.
- **Credenciais:** usuário IAM `fgc-ci`, com permissão mínima (push no ECR, `eks:DescribeCluster` e Edit só no namespace `fgc`). A chave fica nos GitHub Secrets `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`. O SCP da conta (Free plan) nega OIDC provider, por isso não é usado OIDC.

---

## ✅ Testes

```bash
# Users API
cd fgc-users-api && dotnet test

# Catalog API
cd fgc-catalog-api && dotnet test

# Payments API
cd fgc-payments-api && dotnet test

# Notifications Lambda
cd fgc-notifications-lambda && dotnet test tests/Fgc.Notifications.Lambda.Tests
```

---

## 📈 Observabilidade

`fgc-users-api` e `fgc-catalog-api` expõem métricas Prometheus em `GET /metrics` (via `prometheus-net.AspNetCore`, sem instrumentação manual). `docker-compose up -d --build` já sobe `prometheus` e `grafana` junto com o resto do stack.

- Prometheus: http://localhost:9090 — alvos em http://localhost:9090/targets
- Grafana: http://localhost:3000 (`GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD` do `.env`) — dashboard "FGC Services" já provisionado

No EKS o mesmo dashboard é carregado no Grafana do kube-prometheus-stack (ConfigMap com label `grafana_dashboard`), e as APIs são coletadas por ServiceMonitor.

PromQL usado nos 3 painéis do dashboard:
- Latência p50/p95: `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))`
- Requisições por status code: `sum by (code, job) (rate(http_requests_received_total[5m]))`
- Taxa de erro 5xx: `sum(rate(http_requests_received_total{code=~"5.."}[5m])) by (job) / sum(rate(http_requests_received_total[5m])) by (job)`

---

## 🚪 Kong API Gateway

Configuração declarativa (DB-less) em `kong/kong.yml.template`. O container `kong` (imagem própria, `kong/Dockerfile`) gera `kong/kong.yml` em tempo de execução via `envsubst`, substituindo `NOTIFICATIONS_HISTORY_URL` (endpoint da HistoryApi no API Gateway da AWS; opcional — vazia, a rota `/notifications` é removida) e `JWT_SECRET` (`JWT_KEY` do `.env`, mesma chave HS256 de `fgc-users-api`/`fgc-catalog-api`).

Matriz de rotas:

| Rota | Caminho | Auth no Kong | AuthZ |
|---|---|---|---|
| Users (pública) | `/auth/*`, `/setup/*` | nenhuma | — |
| Users (autenticado) | `/users/*` | JWT válido | dentro do serviço |
| Users (admin) | `/admin/users/*` | JWT válido | Admin, dentro do serviço |
| Catalog (leitura) | `GET /games*` | nenhuma | — |
| Catalog (busca) | `GET /search?q=`, `GET /games/search?q=` | nenhuma | — |
| Catalog (escrita) | `POST/PUT/DELETE /games*` | JWT válido | Admin, dentro do serviço |
| Catalog (pedidos) | `/orders*` | JWT válido | dentro do serviço |
| Notifications history | `GET /notifications` | JWT válido | Admin, dentro da Lambda |

`GET /health` de cada serviço não é exposto pelo Kong (uso interno/direto no container).

### Verificação manual (checklist)
1. `POST http://localhost:8000/auth/login` sem token → `200` com `{ token }`.
2. `GET http://localhost:8000/games` sem token → `200` (rota pública).
3. `POST http://localhost:8000/games` sem token → `401` do Kong (confira o log do `fgc-catalog-api`: a requisição não deve chegar lá).
4. `POST http://localhost:8000/games` com token válido não-Admin → `200` do Kong, `403` do catalog-api.
5. `POST http://localhost:8000/games` com token Admin → `201`.
6. Repita 3-5 para `/admin/users`.
7. Após o deploy de `fgc-notifications-lambda` na AWS (ver o README daquele repositório), defina `NOTIFICATIONS_HISTORY_URL` no `.env` deste repositório com a URL da HistoryApi (output `HistoryApiUrl`) e rode `docker compose up -d --build kong`; então `GET http://localhost:8000/notifications` com token Admin → `200`, com token não-Admin → `403` (vindo da própria Lambda).

> **Nota:** o `EventProcessorFunction` é verificado localmente por invocação direta (`sam local invoke`, ver `fgc-notifications-lambda/README.md`); o trigger Amazon MQ → Lambda só existe na AWS.

---

📄 **Relatório de Entrega**
Grupo: Squad 8 – Turma 12NETT
Participantes: Yan Santos Wendt
Repositórios: links na seção acima
