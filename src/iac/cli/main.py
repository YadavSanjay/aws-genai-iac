"""`iac` — primary CLI entrypoint.

Thin command layer over the engine packages. Each subcommand delegates to
`iac.provisioning`, `iac.deployment`, `iac.monitoring`, or `iac.costing`.
"""

from __future__ import annotations

import typer

app = typer.Typer(
    name="iac",
    help="AWS GenAI IaC control plane: provision, deploy, monitor, cost.",
    no_args_is_help=True,
)


@app.command()
def provision(env: str = typer.Option("dev", help="Target environment.")) -> None:
    """Plan/apply infrastructure for an environment (delegates to iac.provisioning)."""
    typer.echo(f"[provision] env={env} — not yet implemented")


@app.command()
def deploy(env: str = typer.Option("dev", help="Target environment.")) -> None:
    """Release/promote workloads (delegates to iac.deployment)."""
    typer.echo(f"[deploy] env={env} — not yet implemented")


@app.command()
def monitor(env: str = typer.Option("dev", help="Target environment.")) -> None:
    """Show infrastructure/pipeline health (delegates to iac.monitoring)."""
    typer.echo(f"[monitor] env={env} — not yet implemented")


@app.command()
def cost(env: str = typer.Option("dev", help="Target environment.")) -> None:
    """Estimate (pre) / report (post) spend (delegates to iac.costing)."""
    typer.echo(f"[cost] env={env} — not yet implemented")


if __name__ == "__main__":
    app()
