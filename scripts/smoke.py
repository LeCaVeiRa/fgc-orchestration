"""Teste de fumaça ponta a ponta via Kong (local ou AWS). Só biblioteca padrão.

    python scripts/smoke.py http://127.0.0.1:8000                 # local: cria o admin via /setup/first-admin
    SMOKE_ADMIN_EMAIL=... SMOKE_ADMIN_PASSWORD=... python scripts/smoke.py http://<alb>   # AWS (ver smoke-aws.sh)

Roteiro: admin -> cadastro e login de jogador -> jogo novo (Admin) -> GET /games -> busca fuzzy ->
pedido -> pagamento aprovado (pedido Completed) -> notificações da Lambda (welcome + payment).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000").rstrip("/")
CHECK_NOTIFICATIONS = os.environ.get("SMOKE_SKIP_NOTIFICATIONS") != "1"
failures = []


def call(method, path, body=None, token=None, expect=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            code, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read()
    elapsed = (time.monotonic() - started) * 1000
    ok = expect is None or code in (expect if isinstance(expect, tuple) else (expect,))
    print(f"{'OK ' if ok else 'ERR'} {method:6} {path:45} {code}  {elapsed:6.0f} ms")
    if not ok:
        failures.append(f"{method} {path} -> {code}: {raw[:200]!r}")
    data = json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode(errors="replace")
    return code, data


def field(obj, name):
    """Lê campo ignorando caixa (APIs .NET em camelCase, Lambda em PascalCase)."""
    return next((v for k, v in obj.items() if k.lower() == name.lower()), None)


sfx = uuid.uuid4().hex[:8]

# --- Admin ---
admin_email = os.environ.get("SMOKE_ADMIN_EMAIL")
admin_password = os.environ.get("SMOKE_ADMIN_PASSWORD")
if admin_email:
    _, r = call("POST", "/auth/login", {"Email": admin_email, "Password": admin_password}, expect=200)
else:
    _, r = call("POST", "/setup/first-admin",
                {"Name": "Admin", "Email": f"admin{sfx}@fgc.com", "Password": "Admin@12345"}, expect=200)
admin_token = field(r, "token") if isinstance(r, dict) else None
if not admin_token:
    sys.exit("sem token de admin - abortando")

# --- Jogador ---
player_email = f"player{sfx}@fgc.com"
_, u = call("POST", "/auth/register", {"Name": f"Player {sfx}", "Email": player_email, "Password": "Player@12345"}, expect=201)
_, r = call("POST", "/auth/login", {"Email": player_email, "Password": "Player@12345"}, expect=200)
player_token = field(r, "token")
user_id = field(u, "id")

# --- Catálogo, busca e autorização ---
call("POST", "/games", {"Title": f"Blocked {sfx}", "Category": "X", "Price": 1}, expect=401)
call("POST", "/games", {"Title": f"Blocked {sfx}", "Category": "X", "Price": 1}, token=player_token, expect=403)
_, g = call("POST", "/games", {"Title": f"Zelda Smoke {sfx}", "Category": "Adventure", "Price": 99.9}, token=admin_token, expect=201)
game_id = field(g, "id")
call("GET", "/games", expect=200)
call("GET", "/games", expect=200)  # segunda leitura: cache
_, found = call("GET", "/search?q=zeld", expect=200)
if not any(field(x, "id") == game_id for x in found if isinstance(x, dict)):
    failures.append("busca fuzzy 'zeld' não retornou o jogo criado")
call("GET", "/games/search?q=" + urllib.parse.quote(f"smoke {sfx}"), expect=200)

# --- Pedido -> pagamento -> biblioteca ---
_, o = call("POST", "/orders", {"UserId": user_id, "GameId": game_id}, token=player_token, expect=201)
order_id = field(o, "id")
status = None
for _ in range(10):
    _, o = call("GET", f"/orders/{order_id}", token=player_token, expect=200)
    status = field(o, "status")
    if status == "Completed":
        break
    time.sleep(2)
if status != "Completed":
    failures.append(f"pedido não concluído (status={status})")

# --- Notificações (Lambda via Amazon MQ) ---
if CHECK_NOTIFICATIONS:
    call("GET", "/notifications", token=player_token, expect=403)
    seen = []
    for _ in range(12):
        code, n = call("GET", "/notifications", token=admin_token, expect=(200, 404))
        if code == 404:
            failures.append("/notifications não roteado (NOTIFICATIONS_HISTORY_URL vazia?)")
            break
        # Welcome traz o e-mail; PaymentProcessedEvent não tem e-mail e a Lambda grava <userId>@fgc.local.
        mine = [x for x in n if (field(x, "recipientEmail") or "").lower() in (player_email, f"{user_id}@fgc.local".lower())]
        seen = sorted({field(x, "type") for x in mine})
        if len(seen) >= 2:
            break
        time.sleep(5)
    print(f"    notificações do jogador: {seen}")
    if len(seen) < 2:
        failures.append(f"esperados 2 tipos de notificação (welcome + compra), vistos: {seen}")

print()
if failures:
    print("FALHOU:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("SMOKE OK")
