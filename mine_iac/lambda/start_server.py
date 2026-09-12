"""Pagina para encender el servidor de Minecraft bajo demanda.

GET  ?token=...  muestra el estado de la maquina, sin cambiar nada.
POST ?token=...  enciende la maquina si esta apagada.

El encendido va por POST a proposito: WhatsApp, Discord y Telegram abren con GET
todo enlace pegado en un chat para armar la vista previa. Si GET encendiera la
maquina, bastaria con compartir el enlace para prenderla.
"""

import hmac
import html
import os
import socket
import traceback
from urllib.parse import quote

import boto3

INSTANCE_ID = os.environ["INSTANCE_ID"]
START_TOKEN = os.environ["START_TOKEN"]
SERVER_PORT = int(os.environ.get("SERVER_PORT", "25565"))
IDLE_STOP_MINUTES = int(os.environ.get("IDLE_STOP_MINUTES", "0"))

_ec2 = None


def ec2():
    global _ec2
    if _ec2 is None:
        _ec2 = boto3.client("ec2")
    return _ec2


def handler(event, context):
    params = event.get("queryStringParameters") or {}
    token = params.get("token", "")
    if not hmac.compare_digest(token.encode(), START_TOKEN.encode()):
        return respond(404, page("Enlace no válido", "<p>Este enlace no existe o ya no es válido.</p>"))

    method = event.get("requestContext", {}).get("http", {}).get("method", "GET").upper()

    try:
        instance = describe_instance()

        if method == "POST":
            if instance["State"]["Name"] == "stopped":
                ec2().start_instances(InstanceIds=[INSTANCE_ID])
                print(f"Encendido solicitado para {INSTANCE_ID}")
            return {
                "statusCode": 303,
                "headers": {"Location": f"?token={quote(token)}", "Cache-Control": "no-store"},
                "body": "",
            }

        return respond(200, status_page(instance, token))
    except Exception:
        traceback.print_exc()
        return respond(502, page("Error", "<p>No se pudo consultar el servidor. Intenta de nuevo en un minuto.</p>"))


def describe_instance():
    response = ec2().describe_instances(InstanceIds=[INSTANCE_ID])
    return response["Reservations"][0]["Instances"][0]


def port_open(ip):
    try:
        with socket.create_connection((ip, SERVER_PORT), timeout=2):
            return True
    except OSError:
        return False


def status_page(instance, token):
    state = instance["State"]["Name"]
    ip = instance.get("PublicIpAddress")

    if state == "stopped":
        action = html.escape(f"?token={quote(token)}")
        return page(
            "Servidor apagado",
            f'<form method="post" action="{action}">'
            '<button type="submit">Encender servidor</button>'
            "</form>"
            '<p class="hint">Tarda unos 2 o 3 minutos en quedar listo para jugar.</p>',
        )

    if state == "pending":
        return page("Encendiendo", "<p>La máquina está arrancando.</p>", refresh=10)

    if state == "running":
        if ip and port_open(ip):
            body = f'<p>Listo para jugar. Entra a:</p><p class="address">{html.escape(ip)}:{SERVER_PORT}</p>'
            if IDLE_STOP_MINUTES > 0:
                body += f'<p class="hint">Se apaga solo después de {IDLE_STOP_MINUTES} minutos sin jugadores.</p>'
            return page("Servidor encendido", body)
        return page(
            "Cargando Minecraft",
            "<p>La máquina ya está encendida y Minecraft está cargando el mundo.</p>"
            '<p class="hint">Si esto dura más de 5 minutos, avisa a quien administra el servidor.</p>',
            refresh=10,
        )

    if state == "stopping":
        return page(
            "Apagándose",
            "<p>El servidor se está apagando. Cuando termine vas a poder encenderlo de nuevo.</p>",
            refresh=15,
        )

    return page("No disponible", f"<p>Estado de la máquina: {html.escape(state)}.</p>")


def page(title, body, refresh=None):
    refresh_tag = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ""
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
{refresh_tag}
<title>Minecraft - {html.escape(title)}</title>
<style>
  :root {{ color-scheme: light dark; --bg: #f4f1ea; --fg: #1d1d1b; --card: #ffffff; --accent: #2f6b2d; --on-accent: #ffffff; --muted: #66665f; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg: #141412; --fg: #ecebe6; --card: #1f1f1c; --accent: #7ccc75; --on-accent: #10200f; --muted: #a3a39b; }}
  }}
  body {{ margin: 0; min-height: 100vh; box-sizing: border-box; padding: 16px; display: grid; place-items: center;
         background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }}
  main {{ width: 100%; max-width: 420px; box-sizing: border-box; padding: 28px; border-radius: 12px; background: var(--card);
         box-shadow: 0 1px 3px rgba(0, 0, 0, .12); }}
  h1 {{ margin: 0 0 12px; font-size: 1.4rem; }}
  button {{ width: 100%; padding: 12px 20px; border: 0; border-radius: 8px; cursor: pointer;
           font: inherit; font-weight: 600; background: var(--accent); color: var(--on-accent); }}
  .address {{ font: 600 1.25rem ui-monospace, "SF Mono", Menlo, monospace; user-select: all; overflow-wrap: anywhere; }}
  .hint {{ color: var(--muted); font-size: .9rem; }}
</style>
</head>
<body><main><h1>{html.escape(title)}</h1>{body}</main></body>
</html>"""


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "X-Robots-Tag": "noindex",
        },
        "body": body,
    }
