"""Django AppConfig for the saltare integration. Placing
`"saltare.contrib.django"` in INSTALLED_APPS *after*
`"django.contrib.staticfiles"` makes Django pick up the
`management/commands/runserver.py` override shipped here in preference
to the staticfiles version (which is itself an override of core's
runserver). Order matters: later entries win in the command-resolution
walk."""

from django.apps import AppConfig


class SaltareDjangoConfig(AppConfig):
    name = "saltare.contrib.django"
    label = "saltare_django"
    verbose_name = "saltare (ASGI) dev server"
