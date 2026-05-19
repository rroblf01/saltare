"""saltare + Django Channels ASGI entry point.

Import order matters:
  1. Set DJANGO_SETTINGS_MODULE.
  2. django.setup() — registers apps, loads middleware classes.
  3. Only AFTER step 2: import channels.routing / channels.auth and
     anything that consults Django apps at import time (consumers
     that touch ORM, etc.).

Get this wrong and the consumer's `connect()` raises during the
first WS upgrade — saltare v1.7.1 surfaces the traceback to stderr
via `--ws-reject-log`, but the fix is always in this file.
"""

import os
import sys

# Make sure Python can find settings.py / consumers.py when running
# `saltare asgi:application` from this directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "settings")

import django  # noqa: E402

django.setup()

from channels.auth import AuthMiddlewareStack  # noqa: E402
from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402
from channels.security.websocket import AllowedHostsOriginValidator  # noqa: E402
from django.core.asgi import get_asgi_application  # noqa: E402
from django.urls import path  # noqa: E402

from consumers import EchoConsumer  # noqa: E402

django_asgi_app = get_asgi_application()

websocket_urlpatterns = [
    path("ws/echo/", EchoConsumer.as_asgi()),
]

application = ProtocolTypeRouter({
    "http": django_asgi_app,
    "websocket": AllowedHostsOriginValidator(
        AuthMiddlewareStack(URLRouter(websocket_urlpatterns)),
    ),
})

# Required so Django's URL machinery doesn't blow up at import time —
# this example has no HTTP routes of its own, but `ROOT_URLCONF` in
# settings.py points back at this module.
urlpatterns: list = []
