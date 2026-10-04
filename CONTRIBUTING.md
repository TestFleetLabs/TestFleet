# Contributing to TestFleet

Thank you for helping. Bug reports, ideas, and pull requests are welcome.

## Before you start

- For anything larger than a small fix, open an issue first, so we can agree on the approach before you invest time.
- The design lives in [.specs/tech-architecture-execution-spec.md](.specs/tech-architecture-execution-spec.md). Follow its names (contexts, tables, fields, statuses, events), and update it in the same pull request when behaviour changes.
- Code conventions are in [.claude/rules/elixir-phoenix.md](.claude/rules/elixir-phoenix.md) and [AGENTS.md](AGENTS.md).

## Development

The [README](README.md#development) explains how to start the local services, run the app, and run the Docker integration tests. Before you open a pull request:

```bash
mix precommit
```

If your change touches execution, also run the Docker tests (`mix test --only docker`). If it changes user-visible behaviour, update the matching page in [docs/](docs/).

## Contributor License Agreement

TestFleet is licensed under the [GNU AGPL v3](LICENSE). To make sure it can also be offered in other forms, such as a hosted service or a commercial edition, every contributor accepts the [Contributor License Agreement](CLA.md) once. You keep the copyright in your work.

When you open your first pull request, a bot asks you to sign by posting a comment. That's all.

## Security

Please do not report security vulnerabilities in public issues. Use GitHub's [private vulnerability reporting](https://github.com/TestFleetLabs/TestFleet/security/advisories/new) instead.
