"""TLS context that trusts the system store plus the OpenShift service CA when present."""

import ssl
from pathlib import Path

from .config import settings


def tls_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if settings.service_ca_file and Path(settings.service_ca_file).is_file():
        ctx.load_verify_locations(settings.service_ca_file)
    return ctx
