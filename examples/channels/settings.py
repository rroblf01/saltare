"""Minimum Django settings for the saltare + Channels smoke example.

No DB, no admin, no static-files pipeline — just enough surface for
`channels.auth.AuthMiddlewareStack` to import without ImproperlyConfigured.
Production apps will plug in their real settings module.
"""

SECRET_KEY = "saltare-channels-example-not-a-real-secret"  # noqa: S105
DEBUG = True

# Allow connections from anywhere — this is a localhost smoke test,
# not a production setting. A real app should list the actual host(s)
# (and trim or replace `AllowedHostsOriginValidator(["*"])` in asgi.py
# accordingly).
ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    "django.contrib.sessions",
    "channels",
]

MIDDLEWARE = [
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
]

ROOT_URLCONF = "asgi"  # unused for WS — keeps the http branch valid

# In-memory channel layer — no Redis dependency for the smoke run.
# Real deployments swap in `channels_redis.core.RedisChannelLayer` or
# `channels_postgres` etc.
CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels.layers.InMemoryChannelLayer",
    },
}

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    },
}

USE_TZ = True
