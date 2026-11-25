"""Contador de visitas — aplicação do desafio DevOps Pleno.

Só biblioteca padrão do Python 3.12. Não precisa alterar este arquivo
(mas pode, se justificar no README).

Variáveis de ambiente:
  APP_MESSAGE   texto exibido na página (padrão: "Olá")
  API_TOKEN     segredo exigido no header X-Api-Token para POST /reset
  DATA_DIR      onde o contador é gravado (padrão: /data)
  PORT          porta HTTP (padrão: 8080)
"""
import json
import os
import signal
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = os.environ.get("DATA_DIR", "/data")
COUNTER = os.path.join(DATA_DIR, "contador.txt")
MESSAGE = os.environ.get("APP_MESSAGE", "Olá")
TOKEN = os.environ.get("API_TOKEN")
PORT = int(os.environ.get("PORT", "8080"))
lock = threading.Lock()


def ler():
    try:
        with open(COUNTER) as fh:
            return int(fh.read().strip() or 0)
    except FileNotFoundError:
        return 0


def gravar(n):
    tmp = COUNTER + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(str(n))
    os.replace(tmp, COUNTER)


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            ok = os.access(DATA_DIR, os.W_OK)
            return self._json(200 if ok else 503, {"ok": ok})
        if self.path == "/":
            with lock:
                n = ler() + 1
                gravar(n)
            return self._json(200, {"mensagem": MESSAGE, "visitas": n, "host": socket.gethostname()})
        self._json(404, {"erro": "não encontrado"})

    def do_POST(self):
        if self.path != "/reset":
            return self._json(404, {"erro": "não encontrado"})
        if not TOKEN or self.headers.get("X-Api-Token") != TOKEN:
            return self._json(401, {"erro": "token inválido"})
        with lock:
            gravar(0)
        self._json(200, {"visitas": 0})


def _encerrar(signum, _frame):
    # Como PID 1 no contêiner, o kernel não aplica a ação padrão do SIGTERM:
    # sem este handler o processo ignora o sinal e só morre no SIGKILL
    # (10 s no Docker, 30 s no Kubernetes). SystemExit interrompe o
    # serve_forever() na thread principal; shutdown() aqui travaria.
    raise SystemExit(0)


if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)
    signal.signal(signal.SIGTERM, _encerrar)
    servidor = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"ouvindo na porta {PORT}, dados em {DATA_DIR}", flush=True)
    try:
        servidor.serve_forever()
    finally:
        servidor.server_close()
        print("encerrado", flush=True)
