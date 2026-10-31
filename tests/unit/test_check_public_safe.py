"""The public-safety check rejects real shapes and values, and passes placeholders.

Fixtures are assembled at runtime so this file does not trip the check itself.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "check_public_safe.py"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("check_public_safe", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = _load()


@pytest.mark.parametrize(
    ("line", "kind"),
    [
        ("cd " + "D:" + "\\Tools\\AI\\repo", "machine path"),
        ("path " + "C:" + "/Users/someone", "machine path"),
        ("/" + "home/someone/work", "home directory"),
        ("key " + "AKIA" + "ABCDEFGHIJKLMNOP", "access key"),
        ("-----BEGIN RSA " + "PRIVATE KEY-----", "private key"),
        ("instance i-" + "0123456789abcdef0", "AWS resource id"),
        ("account " + "1234" + "56789012", "account id"),
    ],
)
def test_real_shapes_are_rejected(line: str, kind: str) -> None:
    assert check.scan_line(line, []) == [kind]


@pytest.mark.parametrize(
    "line",
    [
        'account_id = "' + "0" * 12 + '"',
        "arn:aws:iam::" + "1111" + "22223333:role/x",
        "instance_id = i-" + "0" * 17,
        "subnet_id = subnet-" + "0" * 16 + "1",
        "subnet_id = subnet-" + "1" * 17,
        "`<acct>.dkr.ecr.us-east-1.amazonaws.com` and AKIA...",
    ],
)
def test_placeholders_pass(line: str) -> None:
    assert check.scan_line(line, []) == []


def test_literals_match_case_insensitively() -> None:
    assert check.scan_line("Owner: Some.Person", ["some.person"]) == ["denylisted value"]


def test_literals_load_from_the_local_files(tmp_path: Path) -> None:
    (tmp_path / "infra").mkdir()
    (tmp_path / "infra" / "account.local.hcl").write_text(
        '# comment "ignored"\n'
        'locals {\n  region = "us-east-1"\n  owner = "Real-Value"\n'
        '  emails = ["one@example.test"]\n}\n',
        encoding="utf-8",
    )
    (tmp_path / ".public-denylist").write_text("Extra\n\n", encoding="utf-8")
    assert sorted(check.load_literals(tmp_path)) == ["extra", "one@example.test", "real-value"]


def test_no_local_files_means_no_literals(tmp_path: Path) -> None:
    assert check.load_literals(tmp_path) == []


def test_findings_never_contain_the_value(tmp_path: Path) -> None:
    target = tmp_path / "doc.md"
    target.write_text("fine\nhas secret-value here\n", encoding="utf-8")
    findings = check.scan_file(target, "doc.md", ["secret-value"])
    assert findings == ["doc.md:2: denylisted value"]


def test_license_is_exempt_from_literals_only(tmp_path: Path) -> None:
    target = tmp_path / "LICENSE"
    target.write_text("Copyright Some Person\n", encoding="utf-8")
    assert check.scan_file(target, "LICENSE", ["some person"]) == []
