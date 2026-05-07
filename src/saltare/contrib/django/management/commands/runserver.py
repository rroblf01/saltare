"""`manage.py runserver` override that swaps Django's wsgiref dev
server for saltare's epoll/Zig core, serving the project's ASGI app.

Autoreload behaviour mirrors the upstream command: Django's
`run_with_reloader` watches files in the parent process and re-execs
this `inner_run` in a child whenever a source file changes. saltare's
`run()` blocks until SIGINT/SIGTERM, which the autoreload child sees
when the parent restarts it — same lifecycle as the wsgiref version.

ASGI app resolution order:
  1. `settings.SALTARE_ASGI_APPLICATION` (saltare-specific override).
  2. `settings.ASGI_APPLICATION` (Django's documented setting).
  3. `django.core.asgi.get_asgi_application()` (the implicit default
     Django builds when no `application = …` lives in `<proj>/asgi.py`).

Static-file handling: when `django.contrib.staticfiles` is installed
*and* `DEBUG=True`, the ASGI app is wrapped with
`ASGIStaticFilesHandler` so `STATIC_URL` keeps serving in dev — the
same DX as the upstream `runserver`.
"""

from __future__ import annotations

import importlib

from django.conf import settings
from django.core.management.commands.runserver import Command as RunserverCommand
from django.utils import autoreload


def _resolve_asgi_application():
    """Pull the user's ASGI app from settings or fall back to Django's
    default. Mirrors `get_default_application` semantics from `daphne`,
    but without taking a daphne dependency."""
    target = getattr(settings, "SALTARE_ASGI_APPLICATION", None) or getattr(
        settings, "ASGI_APPLICATION", None
    )
    if target:
        module_path, _, attr = target.rpartition(".")
        if not module_path:
            raise ImportError(
                f"ASGI_APPLICATION = {target!r} must be a dotted path "
                "to a callable (e.g. 'myproject.asgi.application')"
            )
        module = importlib.import_module(module_path)
        try:
            return getattr(module, attr)
        except AttributeError as exc:
            raise ImportError(
                f"Module {module_path!r} has no attribute {attr!r}"
            ) from exc
    # No explicit setting — use the implicit default Django builds when
    # the project hasn't shipped an `asgi.py`.
    from django.core.asgi import get_asgi_application
    return get_asgi_application()


def _maybe_wrap_static(app):
    """Wrap `app` with `ASGIStaticFilesHandler` when running in DEBUG +
    `staticfiles` is installed — matches the dev-time UX of the
    upstream runserver, which also relies on staticfiles to serve
    `STATIC_URL`."""
    if not settings.DEBUG:
        return app
    if "django.contrib.staticfiles" not in settings.INSTALLED_APPS:
        return app
    try:
        from django.contrib.staticfiles.handlers import ASGIStaticFilesHandler
    except ImportError:
        return app
    return ASGIStaticFilesHandler(app)


class Command(RunserverCommand):
    help = "Run the project under saltare (ASGI) instead of wsgiref."

    # Django's runserver default protocol string lands in the banner;
    # override so users see we're serving ASGI, not WSGI.
    server_cls = None  # not used — saltare doesn't expose a wsgiref-style class
    protocol = "http"

    def add_arguments(self, parser):
        super().add_arguments(parser)
        # Saltare-specific knobs. Names mirror the public `saltare.run`
        # kwargs so users who already know the server can carry over
        # their muscle memory.
        parser.add_argument(
            "--workers", type=int, default=1,
            help="number of saltare workers (default 1; >1 disables autoreload)",
        )
        parser.add_argument(
            "--access-log", action="store_true",
            help="emit one JSON line per request to stderr",
        )
        parser.add_argument(
            "--proxy-headers", action="store_true",
            help="parse X-Forwarded-* / X-Real-IP into scope (only behind a trusted proxy)",
        )

    def get_handler(self, *args, **options):  # type: ignore[override]
        # Upstream's `get_handler` returns a WSGI app for wsgiref.
        # We never call it because we override `inner_run`. Stub in
        # case other code paths reach for it.
        return _resolve_asgi_application()

    def inner_run(self, *args, **options):
        # Upstream `inner_run` prints the Django version banner +
        # boots wsgiref. We do the banner ourselves and call
        # `saltare.run()`.
        from django import get_version
        from saltare import __version__ as saltare_version, run

        # Resolve + wrap.
        app = _resolve_asgi_application()
        app = _maybe_wrap_static(app)

        addr = self.addr
        port = int(self.port)
        # Django formats IPv6 addresses with square brackets in `_raw_ipv6`;
        # saltare auto-detects v6 from the `:` in `host`, so we pass the
        # raw form. Strip brackets so saltare's bind logic sees plain v6.
        if addr.startswith("[") and addr.endswith("]"):
            addr = addr[1:-1]

        quit_command = "CONTROL-C"
        self.stdout.write(
            f"saltare {saltare_version} (ASGI) — Django {get_version()}\n"
            f"Listening on {self.protocol}://{self.addr}:{self.port}/\n"
            f"Quit the server with {quit_command}.\n"
        )

        workers = int(options.get("workers") or 1)
        if workers > 1 and options.get("use_reloader", True):
            self.stdout.write(
                "saltare: --workers > 1 disables Django's autoreload "
                "(reloader and pre-fork supervisor are incompatible).\n"
            )

        run(
            app,
            host=addr,
            port=port,
            workers=workers,
            access_log=bool(options.get("access_log", False)),
            proxy_headers=bool(options.get("proxy_headers", False)),
        )

    def run(self, **options):  # type: ignore[override]
        # Mirrors upstream's `run()`: kicks off the autoreloader if
        # asked, otherwise calls `inner_run` directly. Multi-worker
        # mode bypasses the reloader because saltare forks its own
        # supervisor and the reloader would race with it.
        use_reloader = options.get("use_reloader", True) and int(options.get("workers", 1)) <= 1
        if use_reloader:
            autoreload.run_with_reloader(self.inner_run, **options)
        else:
            self.inner_run(**options)
