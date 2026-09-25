"""Reading and changing single settings in the config file."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from garage_rag.config import (
    default_config_path,
    get_settings,
    load_config,
    resolve_setting,
    set_settings,
    setting_value,
    update_config,
)


def get_setting(name: str) -> Any:
    """The effective value of SECTION.KEY (after --config and environment overrides)."""
    _section, _key, field = resolve_setting(name)
    return setting_value(get_settings(), field)


def set_setting(name: str, value: str, *, path: Path | None = None) -> tuple[Path, Any]:
    """Change SECTION.KEY in the config file in use (or ``path``); ``(written file, stored value)``.

    The value is validated before anything is written, and the process-wide
    settings are reloaded from the file afterwards. Raises ConfigError.
    """
    target = (path or get_settings().config_path or default_config_path()).expanduser()
    settings, stored = update_config(target, name, value)
    set_settings(load_config(target))
    return Path(settings.config_path or target), stored
