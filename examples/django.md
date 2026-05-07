# saltare with Django (`saltare[django]`)

Local-dev ASGI environment for a Django project — `manage.py runserver`
boots saltare instead of `wsgiref`. Production usage stays the same
(deploy your `<proj>/asgi.py` under `saltare myproject.asgi:application`,
gunicorn, daphne, whatever).

## Install

```bash
pip install 'saltare[django]'
```

The `[django]` extra pulls Django ≥ 4.2 alongside saltare.

## Wire up

Edit `<proj>/settings.py`:

```python
INSTALLED_APPS = [
    # ... your usual entries ...
    "django.contrib.staticfiles",
    # Place AFTER staticfiles so saltare's command override wins.
    "saltare.contrib.django",
]
```

Optional — point the integration at a non-default ASGI callable:

```python
# Standard Django setting — saltare honours it.
ASGI_APPLICATION = "myproject.asgi.application"

# Saltare-specific override (takes precedence over ASGI_APPLICATION
# if both are set). Useful when staticfiles wrapping or middleware
# composition needs a different entry point in dev vs prod.
SALTARE_ASGI_APPLICATION = "myproject.asgi_dev.application"
```

When neither setting is defined, saltare falls back to
`django.core.asgi.get_asgi_application()` — the implicit default.

## Use

```bash
python manage.py runserver
# saltare 1.4.0 (ASGI) — Django 5.1.0
# Listening on http://127.0.0.1:8000/
# Quit the server with CONTROL-C.
```

Autoreload, `--noreload`, and `--ipv6` keep working as in upstream
runserver. Static files (`STATIC_URL`) are served by Django's
`ASGIStaticFilesHandler` when `DEBUG=True` — same dev-time DX.

### Saltare-specific flags

```bash
python manage.py runserver --workers 4    # pre-fork; disables reloader
python manage.py runserver --access-log   # JSON access log to stderr
python manage.py runserver --proxy-headers
```

`--workers > 1` disables Django's autoreload because saltare's
pre-fork supervisor and the file-watch reloader can't share a
listen socket without races.

## Production

The integration is dev-only; in production you should run saltare
directly against your project's ASGI app:

```bash
saltare myproject.asgi:application \
    --host 0.0.0.0 --port 8000 --workers 4 \
    --access-log --proxy-headers
```

There's no Django dependency on the saltare side at runtime when you
use the plain `saltare` CLI — `[django]` is purely for the runserver
integration.
