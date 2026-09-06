# 🎮 FCG - FIAP Cloud Games

Plataforma de games educacionais desenvolvida como **Tech Challenge** da pós-graduação **Arquitetura de Sistemas .NET – FIAP**.

Arquitetura de **microsserviços orientada a eventos**, com comunicação assíncrona via **RabbitMQ**/**Amazon MQ** e **MassTransit**, gateway único via **Kong**, observabilidade via **Prometheus + Grafana**, e persistência poliglota (**DynamoDB** + **Redis**) além do SQLite de cada serviço.

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

---

## 📦 Repositórios

| Microsserviço | Repositório | Tecnologias |
|---|---|---|
| **Users API** | [fgc-users-api](https://github.com/ronnam/fgc-users-api) | .NET 8, EF Core, SQLite, JWT, MassTransit, DynamoDB |
| **Catalog API** | [fgc-catalog-api](https://github.com/ronnam/fgc-catalog-api) | .NET 8, EF Core, SQLite, JWT, MassTransit, DynamoDB, Redis |
| **Payments API** | [fgc-payments-api](https://github.com/ronnam/fgc-payments-api) | .NET 8, MassTransit (scaffold) |
| **Notifications Lambda** | [fgc-notifications-lambda](https://github.com/ronnam/fgc-notifications-lambda) | .NET 8, AWS SAM, Lambda, Amazon MQ, DynamoDB, API Gateway |
| **Message Contracts** | [fgc-message-contracts](https://github.com/ronnam/fgc-message-contracts) | Pacote NuGet local de eventos |
| **Orquestração** | *(este repositório)* | Docker Compose, Kubernetes, Kong, Prometheus, Grafana |

---

## 🐳 Execução com Docker

### Pré-requisitos
- [Docker](https://docs.docker.com/engine/install/) + Docker Compose
- `LOCALSTACK_AUTH_TOKEN` definido em um `.env` neste repositório (gere uma conta gratuita em https://app.localstack.cloud) — sem ele, `docker-compose up` falha ao subir o serviço `localstack` (variável obrigatória no compose)

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
| localstack | 4566 | Emulação AWS (Lambda/DynamoDB/API Gateway) para `fgc-notifications-lambda` |
| notifications-lambda-deploy | — | `samlocal build/deploy` de `fgc-notifications-lambda` contra o LocalStack (roda uma vez e sai, `restart: "no"`) |
| notifications-lambda-logs | — | Acompanha logs das Lambdas no LocalStack (via docker.sock) |
| notifications-lambda-bridge | — | Encaminha mensagens do RabbitMQ local para o `EventProcessor` (LocalStack não emula o event source mapping de Amazon MQ); atrás do profile `tools`, não sobe com `docker-compose up` sozinho — use `docker-compose --profile tools up -d notifications-lambda-bridge` |
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
- RabbitMQ Management: http://localhost:15672 (admin/admin)
- Kong Admin API: http://localhost:8001

---

## ☸️ Kubernetes

### Pré-requisitos
- Cluster Kubernetes local (Kind, Minikube, k3d ou Docker Desktop)
- `kubectl` configurado

### Estrutura dos manifestos
Cada repositório de microsserviço possui sua própria pasta `/k8s` com:
- `deployment.yaml` — Deployment com probes de liveness/readiness
- `service.yaml` — Service do tipo ClusterIP
- `configmap.yaml` — Configurações não sensíveis
- `secret.yaml` — Credenciais e dados sensíveis

### Deploy no cluster
A partir deste repositório de orquestração:
```bash
kubectl apply -f ../fgc-users-api/k8s/
kubectl apply -f ../fgc-catalog-api/k8s/
kubectl apply -f ../fgc-payments-api/k8s/
```
(`fgc-notifications-lambda` não usa Kubernetes — é implantado via `sam deploy`, ver o README do próprio repositório.)

Verificar pods: `kubectl get pods`

### Acessar serviços no cluster
```
http://fgc-users-api:80
http://fgc-catalog-api:80
http://fgc-payments-api:80
```

---

## 🔧 Variáveis de Ambiente

### RabbitMQ / Amazon MQ (Users, Catalog)
| Variável | Descrição | Padrão (docker-compose local) |
|---|---|---|
| `RabbitMq__Host` | Host do broker | `rabbitmq` |
| `RabbitMq__Port` | Porta do broker | `5672` (`5671` se `UseSsl=true`) |
| `RabbitMq__VirtualHost` | Virtual host | `/` |
| `RabbitMq__UseSsl` | Usa AMQPS (produção, Amazon MQ) | `false` |
| `RabbitMq__Username` / `RabbitMq__Password` | Credenciais do broker | `admin` / `admin` |

### DynamoDB (Users, Catalog)
| Variável | Descrição |
|---|---|
| `AWS__DynamoDB__ServiceUrl` | Endpoint local (`http://dynamodb-local:8000`); ausente em produção, usa a AWS real |

### Redis (Catalog)
| Variável | Descrição |
|---|---|
| `Redis__ConnectionString` | `redis:6379` local |

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
- Grafana: http://localhost:3000 (admin/admin) — dashboard "FGC Services" já provisionado

PromQL usado nos 3 painéis do dashboard:
- Latência p50/p95: `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))`
- Requisições por status code: `sum by (code, job) (rate(http_requests_received_total[5m]))`
- Taxa de erro 5xx: `sum(rate(http_requests_received_total{code=~"5.."}[5m])) by (job) / sum(rate(http_requests_received_total[5m])) by (job)`

---

## 🚪 Kong API Gateway

Configuração declarativa (DB-less) em `kong/kong.yml.template`. O container `kong` (imagem própria, `kong/Dockerfile`) gera `kong/kong.yml` em tempo de execução via `envsubst`, substituindo `NOTIFICATIONS_HISTORY_URL` (endpoint da HistoryApi — LocalStack em dev, API Gateway real em produção) e `JWT_SECRET` (mesma chave HS256 de `fgc-users-api`/`fgc-catalog-api`).

Matriz de rotas:

| Rota | Caminho | Auth no Kong | AuthZ |
|---|---|---|---|
| Users (pública) | `/auth/*`, `/setup/*` | nenhuma | — |
| Users (autenticado) | `/users/*` | JWT válido | dentro do serviço |
| Users (admin) | `/admin/users/*` | JWT válido | Admin, dentro do serviço |
| Catalog (leitura) | `GET /games*` | nenhuma | — |
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
7. Após `samlocal deploy` em `fgc-notifications-lambda` (ver o README daquele repositório), defina `NOTIFICATIONS_HISTORY_URL` no `.env` deste repositório com a URL real da HistoryApi no LocalStack e rode `docker compose up -d --build kong`; então `GET http://localhost:8000/notifications` com token Admin → `200`, com token não-Admin → `403` (vindo da própria Lambda).

> **Nota:** o container `localstack` (community edition) exige uma conta gratuita LocalStack para ativar — defina `LOCALSTACK_AUTH_TOKEN` no `.env` (gere em https://app.localstack.cloud) antes de subir esse serviço, senão ele sai com `exit 55 (License activation failed)`. Isso não bloqueia a verificação do `EventProcessorFunction`, que é feita por invocação direta (`sam local invoke`, ver `fgc-notifications-lambda/README.md`) — verificado nesta sessão com sucesso (401/403/200 na HistoryApi, e os 2 itens esperados gravados no DynamoDB a partir dos 3 eventos sintéticos).

---

📄 **Relatório de Entrega**
Grupo: Squad 8 – Turma 12NETT
Participantes: Yan Santos Wendt
Repositórios: links na seção acima
