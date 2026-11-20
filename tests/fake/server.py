#!/usr/bin/env python3
"""Servidores de mentira para os testes do instalador.

  server.py master    mestre em http://127.0.0.1:8088 (resgate do codigo, backup, pacote de scripts)
  server.py registry  registry em https://127.0.0.1:5050 (so o /v2/)
  server.py api       API em :3000 (docker_setup) e tela em :4200

Os arquivos de /fake/knobs mudam o comportamento (ver cada handler).
"""
import json, os, ssl, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KNOBS = "/fake/knobs"
TOKEN = "tok123456789"
ENV_FILE = "/env/.env.production"


def knob(name):
    try:
        return open(os.path.join(KNOBS, name)).read().strip()
    except OSError:
        return None


def log(line):
    with open("/fake/calls.log", "a") as f:
        f.write(line + "\n")


class Quiet(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))


class Master(Quiet):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        log("master GET " + self.path)
        if self.path == "/":
            return self.send(200, "ok", "text/plain")
        if self.path == "/ncscripts.tar.gz":
            return self.serve_file("/fake/ncscripts.tar.gz")
        if self.path.startswith("/install/") and "/backup" in self.path:
            code = self.path.split("/")[2]
            if code != "GOODCODE":
                return self.send(404, '{"errors":["Codigo invalido"]}')
            if knob("no_backup") is not None or not os.path.exists("/fake/master-backup.zip"):
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            return self.serve_file("/fake/master-backup.zip")
        self.send(404, "{}")

    def serve_file(self, path):
        data = open(path, "rb").read()
        start = 0
        rng = self.headers.get("Range")
        if rng and knob("no_range") is None:
            start = int(rng.split("=")[1].split("-")[0])
            if start >= len(data):
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % len(data))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        else:
            self.send_response(200)
        chunk = data[start:]
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()
        # backup_cut: manda so N bytes e derruba a conexao, uma vez.
        cut = knob("backup_cut")
        if cut:
            os.remove(os.path.join(KNOBS, "backup_cut"))
            self.wfile.write(chunk[: int(cut)])
            self.wfile.flush()
            self.connection.close()
            return
        self.wfile.write(chunk)

    def do_POST(self):
        raw = self.body()
        if self.path == "/install/redeem":
            log("master POST /install/redeem")
            if knob("master_500") is not None:
                return self.send(500, "{}")
            try:
                code = json.loads(raw).get("code")
            except ValueError:
                code = None
            if code != "GOODCODE":
                return self.send(404, '{"errors":["Codigo invalido ou expirado."]}')
            return self.send(200, json.dumps({
                "token": TOKEN, "company": "lojateste", "registry": "127.0.0.1:5050",
                "anydesk_password": "segredo-anydesk"}))
        self.send(404, "{}")


class Registry(Quiet):
    def do_GET(self):
        self.send(401, "{}")


class Api(Quiet):
    def configured(self):
        try:
            return "NCOMMERCE_SERVER_TOKEN=" in open(ENV_FILE).read()
        except OSError:
            return False

    def do_GET(self):
        if knob("api_down") is not None:
            return self.send(503, "{}")
        if self.path.startswith("/api/v1/docker_setup"):
            return self.send(200, json.dumps({"setup_required": not self.configured()}))
        self.send(403, "{}")

    def do_POST(self):
        raw = self.body()
        log("api POST " + self.path)
        if knob("api_post_502") is not None:
            return self.send(502, '{"error":"mestre fora"}')
        if self.configured():
            return self.send(403, '{"error":"Este servidor ja foi configurado."}')
        token = json.loads(raw).get("token", "")
        with open(ENV_FILE, "w") as f:
            f.write("NCOMMERCE_SERVER_TOKEN=%s\nNCOMMERCE_SERVER_URL=http://127.0.0.1:8088\n" % token)
        self.send(200, '{"ok":true}')


class Web(Quiet):
    def do_GET(self):
        if knob("web_down") is not None:
            return self.send(502, "")
        self.send(200, "<html>NCommerce</html>", "text/html")


def serve(handler, port, tls=False):
    srv = ThreadingHTTPServer(("0.0.0.0", port), handler)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain("/fake/cert.pem", "/fake/key.pem")
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


mode = sys.argv[1]
if mode == "master":
    serve(Master, 8088)
elif mode == "registry":
    serve(Registry, 5050, tls=True)
elif mode == "api":
    threading.Thread(target=serve, args=(Web, 4200), daemon=True).start()
    serve(Api, 3000)
