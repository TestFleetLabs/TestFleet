---
title: Introduction
description: What TestFleet is, what it is not, and how it fits next to your applications.
---

TestFleet is a self-hosted platform that schedules, executes, and monitors end-to-end test suites. It is built on one principle:

> **Tests belong to the application. Test execution belongs to TestFleet.**

Each application keeps its E2E suite in its own repository, next to the code it tests, and ships it as a Docker/OCI image. TestFleet does not care which framework the suite uses. It runs the image against the environments you configure and takes care of everything around the tests:

- **When:** run on demand, on a cron schedule in any time zone, or from a CI pipeline after a deployment
- **Where:** against each environment (staging, production, a customer's instance) with its own variables and secrets
- **How:** in an isolated, hardened container with a timeout, CPU and memory limits, and a concurrency limit per environment
- **What happened:** live output in the browser, the stored log, per-test results from JUnit XML, and artifacts such as screenshots, videos, traces, and HTML reports
- **Who needs to know:** notifications by email, Slack, Microsoft Teams, or webhook when a suite starts failing or recovers

## What TestFleet is not

TestFleet is **not a test framework**. It never looks inside your tests, has no test DSL, and has no opinion on Playwright versus Cypress. If a suite runs in a container, exits with a meaningful code, and prints to stdout, TestFleet can run it. That is the [container contract](/suites/container-contract/).

TestFleet is **not a CI system** either. Your CI builds and deploys the application, and it can ask TestFleet to test the result ([Run tests from a pipeline](/ci/pipelines/)). TestFleet also keeps testing between deployments, on schedules, which a CI pipeline usually does not.

## Who it is for

- Teams that maintain several applications, each with its own E2E suite, and want one place to see whether they are healthy.
- Operations teams that want synthetic checks of production that exercise real user journeys, on a schedule, with alerts.
- Organizations that need to keep test data and credentials inside their own network: TestFleet is self-hosted and needs nothing from the outside except the images you choose to pull.

## How it runs

TestFleet is a single Docker Compose stack on one host: the TestFleet app, PostgreSQL, and a Docker socket proxy. It starts each test run as a separate container on the same Docker Engine. The host can be any 64-bit Linux machine with Docker, `amd64` or `arm64`, including a [Raspberry Pi](/operate/arm/).

```text
Browser ── TestFleet ──┬── PostgreSQL           runs, logs, results, configuration
                       └── Docker socket proxy
                              └── Docker Engine ── E2E container per run
```

## Next steps

- [Quick start](/start/quick-start/): install TestFleet and run a first suite
- [Concepts](/start/concepts/): projects, test definitions, environments, schedules, and runs
- [The container contract](/suites/container-contract/): what your suite image needs to do
