"""Django integration: drops a `runserver` management command override
that boots the project under saltare (ASGI) instead of Django's
wsgiref-based dev server.

Install with `pip install saltare[django]`, then add to your settings:

    INSTALLED_APPS = [
        # ... your apps ...
        "django.contrib.staticfiles",
        "saltare.contrib.django",   # must come AFTER staticfiles
    ]

`manage.py runserver` will then say:

    saltare 1.4.0 (ASGI) listening on 127.0.0.1:8000

… and serve through saltare's epoll/Zig core. Autoreload, `--noreload`,
and Django's StaticFilesHandler all keep working unchanged.
"""

default_app_config = "saltare.contrib.django.apps.SaltareDjangoConfig"
