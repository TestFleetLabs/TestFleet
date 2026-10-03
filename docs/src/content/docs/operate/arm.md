---
title: Raspberry Pi and ARM
description: Run TestFleet on a Raspberry Pi or another arm64 host, and build suite images for it.
---

Every TestFleet image is published for `linux/amd64` and `linux/arm64`; Docker pulls the one that fits the host. The installation is the same as on any other host: follow [Install](/operate/install/).

## Raspberry Pi

TestFleet runs on a **Raspberry Pi 4 or 5 with a 64-bit OS**. Check with:

```sh
uname -m    # aarch64
```

32-bit Raspberry Pi OS (`armv7l`) is not supported.

The stack itself needs about 1 GB of memory. The suites need what they always need: a browser suite takes 2–4 GB while it runs. A Pi with 8 GB is a comfortable minimum for browser suites; keep the [global concurrency limit](/operate/configuration/#execution) low, such as `MAX_CONCURRENT_RUNS=2`, so parallel suites do not exhaust it.

Use an SSD rather than an SD card if you can. The database writes every log line, and SD cards wear out and slow down under that load.

## Suite images must be arm64 too

The suites run on the same host as TestFleet, so **their images must exist for `linux/arm64`**. An `amd64`-only image fails the run with an error like:

```text
no matching manifest for linux/arm64/v8 in the manifest list entries
```

Build suite images for both platforms, so they run on any TestFleet host and on developers' machines:

```sh
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/acme/portal-e2e:1.4.2 --push .
```

In GitHub Actions, `docker/setup-qemu-action` and `docker/setup-buildx-action` before `docker/build-push-action` with `platforms: linux/amd64,linux/arm64` do the same. For faster builds, build each platform on a native runner (`ubuntu-24.04-arm` for arm64) and merge them, as TestFleet's own CI does.

### Base images

The Playwright images (`mcr.microsoft.com/playwright`) exist for both platforms, as do the official `node`, `python`, and `alpine` images. For other browser images, check the platforms of the tag you use (`docker buildx imagetools inspect <image>`).

Google Chrome itself is not built for Linux on ARM, so ARM images of browser frameworks ship Chromium or Firefox instead. Suites that need branded Chrome, rather than Chromium, need an `amd64` host.
