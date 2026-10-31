"""Each deploy script defaults to the sibling checkout's current folder name.

The XbrlRag default kept the app's old name after the rename, so the script failed
on its default path until --source was passed by hand.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


@pytest.mark.parametrize(
    ("script", "folder"),
    [
        ("deploy_arag_bundle.py", "XbrlRag"),
        ("deploy_macrorag_bundle.py", "MacroRAG"),
        ("deploy_qlp_bundle.py", "faultline-dev"),
    ],
)
def test_default_source_names_the_sibling_checkout(script: str, folder: str) -> None:
    spec = importlib.util.spec_from_file_location(script.removesuffix(".py"), SCRIPTS / script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module._default_source().name == folder
