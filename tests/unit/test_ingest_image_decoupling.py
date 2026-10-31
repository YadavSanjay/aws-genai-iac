"""The ingest runner's image must NOT be reachable from Terraform's user_data.

Why this test exists. The arag-ingest image tag was a Terraform local, rendered
into user_data. The instance carries `user_data_replace_on_change = true`, so the
tag had two defects at once:

  1. Bumping the image REPLACED the instance — a provisioning operation for what
     is really a deploy, losing the host's staged scratch data each time.
  2. The pin drifted. It sat at a commit five ahead of which `bootstrap_db.py`,
     the vendored Arelle DDL and the MV SQL were added, so the documented ingest
     command failed on the box with a bare "No such file or directory" — the
     image simply did not contain the file the runbook told the operator to run.

The fix mirrors the app tier: the tag lives in an S3 pointer object that the host
reads at RUN time. These assertions are what keep it there — the failure mode is
someone "simplifying" the indirection away, which looks like a tidy-up and
silently restores both defects.

Static assertions on the real committed files; nothing is mocked and no AWS call
is made. `bash -n` correctness of the same template is covered by
test_bootstrap_script_syntax.py.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = REPO_ROOT / "infra/modules/compute/ingest-runner/user-data.sh.tftpl"
VARIABLES = REPO_ROOT / "infra/modules/compute/ingest-runner/variables.tf"
COMPONENT = REPO_ROOT / "infra/environments/dev/42-arag/ingest/terragrunt.hcl"
POINTER_TEMPLATE = REPO_ROOT / "infra/environments/dev/42-arag/ingest/deploy.env"

# An image tag as this project writes them: arm64-<short sha>, never :latest.
TAG_PATTERN = re.compile(r":arm64-[0-9a-f]{7,}")


def _code(text: str) -> str:
    """Drop comment-only lines.

    These files carry long rationale comments that quote the very anti-patterns
    being asserted against ("`cp`, never `s3 sync`", "never :latest"). Matching
    raw text would fail on the explanation of the rule rather than a violation of
    it, so the assertions run against executable lines only.
    """
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))


@pytest.fixture(scope="module")
def template() -> str:
    return TEMPLATE.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def component() -> str:
    return COMPONENT.read_text(encoding="utf-8")


def test_files_exist() -> None:
    """Guard against a rename turning every assertion below into a vacuous pass."""
    for path in (TEMPLATE, VARIABLES, COMPONENT, POINTER_TEMPLATE):
        assert path.is_file(), f"missing {path.relative_to(REPO_ROOT)}"


def test_user_data_takes_a_pointer_not_an_image(template: str) -> None:
    assert "${image_pointer_uri}" in template, (
        "user-data no longer receives image_pointer_uri — the run-time indirection is gone"
    )
    assert "${image}" not in template, (
        "user-data takes an ${image} substitution again; a tag in user_data means "
        "every image bump replaces the instance"
    )


def test_no_image_tag_is_baked_into_user_data(template: str) -> None:
    found = TAG_PATTERN.findall(template)
    assert not found, f"an image tag is hardcoded in the bootstrap template: {found}"


def test_component_passes_a_pointer_and_pins_no_tag(component: str) -> None:
    assert "image_pointer_uri" in component, "component stopped passing image_pointer_uri"
    assert not re.search(r"^\s*image_tag\s*=", component, re.MULTILINE), (
        "image_tag is a Terraform local again — bumping it would reprovision the box"
    )
    found = TAG_PATTERN.findall(component)
    assert not found, f"an image tag is pinned in the component config: {found}"


def test_module_validates_the_pointer_is_an_s3_uri() -> None:
    """A non-s3:// value would fail only at first boot, inside `aws s3 cp`."""
    variables = VARIABLES.read_text(encoding="utf-8")
    assert "image_pointer_uri" in variables, "the module dropped image_pointer_uri"
    assert 'startswith(var.image_pointer_uri, "s3://")' in variables, (
        "the s3:// validation on image_pointer_uri is gone"
    )


def test_resolver_fetches_with_cp_not_sync(template: str) -> None:
    """`s3 sync` skips same-size objects, and two git-SHA tags are the same length.

    A bump would then be silently ignored and the host would keep running the old
    image — the same trap ec2-app/user-data.sh.tftpl documents for deploy.env.
    """
    assert 'aws s3 cp "$IMAGE_POINTER_URI"' in template, "the pointer is not fetched with `s3 cp`"
    assert "s3 sync" not in _code(template), (
        "the ingest bootstrap uses `s3 sync`; a same-length tag swap would be skipped"
    )


def test_wrapper_resolves_the_image_per_invocation(template: str) -> None:
    assert 'IMG="$(/usr/local/bin/arag-resolve-image)"' in template, (
        "arag-ingest no longer resolves the image at run time, so a published bump "
        "would not reach an already-booted host"
    )


def test_prepull_failure_cannot_abort_cloud_init(template: str) -> None:
    """The pre-pull is a warm cache, not a correctness requirement.

    Under `set -e` a failed pull aborted cloud-init before the status marker,
    leaving a box that looked provisioned but had no image and no marker saying
    so. The marker must be written unconditionally.
    """
    prepull = template.split("# --- Render once + pre-pull", 1)
    assert len(prepull) == 2, "the pre-pull section was renamed; re-point this assertion"
    body = prepull[1]
    assert "|| true" in body, "the pre-pull can abort cloud-init again"
    marker = "ingest-runner-ready"
    assert marker in body, f"the {marker} status marker left the pre-pull section"
    assert body.index("|| true") < body.index(marker), (
        "the status marker is written before the non-fatal guard — a pre-pull "
        "failure would abort cloud-init before the marker is written"
    )


def test_pointer_template_declares_exactly_one_image(component: str) -> None:
    """The host sources this file and reads one variable; a second line would win silently."""
    text = POINTER_TEMPLATE.read_text(encoding="utf-8")
    image_lines = [ln for ln in text.splitlines() if ln.startswith("ARAG_INGEST_IMAGE=")]
    assert len(image_lines) == 1, f"expected one ARAG_INGEST_IMAGE line, got {image_lines}"
    assert "${REGISTRY}" in image_lines[0], (
        "the pointer template hardcodes a registry — the account id must stay uncommitted"
    )
    assert ":latest" not in _code(text), "tags must be immutable and SHA-based, never :latest"
    # The key the uploader writes must match the key Terraform tells the host to read.
    assert "deploy/ingest.env" in component, "component's image_pointer_key drifted from the script"
