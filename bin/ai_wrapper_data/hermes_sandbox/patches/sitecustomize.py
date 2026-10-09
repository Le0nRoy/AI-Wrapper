"""Keep known Hermes child entry points on the protected sandbox policy."""

import os


if os.environ.get("HERMES_SANDBOX_RUNTIME"):
    try:
        import adapter
        adapter.bootstrap_child()
    except BaseException as error:
        raise SystemExit("Hermes sandbox policy initialization refused") from error
