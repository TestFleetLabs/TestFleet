# Black-box browser e2e suite for the testfleet.io landing page and docs. Build context is this folder:
#   docker build -t testfleet-e2e e2e/testfleet.io
#   docker run --rm --ipc=host -v "$PWD/reports:/TestFleet/artifacts" testfleet-e2e
# BASE_URL (-e BASE_URL=…) is optional and defaults to https://testfleet.io.
# The base image ships the browsers of exactly one Playwright version: its tag has to match
# @playwright/test in package.json, or Playwright can't find its browser at runtime.
FROM mcr.microsoft.com/playwright:v1.64.1-noble

WORKDIR /e2e

# CI=true: test.only fails the run. TestFleet sets TestFleet_ARTIFACTS_DIR itself; the
# default here is for a plain `docker run`.
ENV NODE_ENV=production \
    CI=true \
    TestFleet_ARTIFACTS_DIR=/TestFleet/artifacts

# tini has no apt candidate in this image, so it comes from the GitHub release for the build arch
ARG TINI_VERSION=v0.19.0
ARG TARGETARCH
ADD --chmod=755 https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-${TARGETARCH} /usr/bin/tini
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-${TARGETARCH}.sha256sum /tmp/tini.sha256sum
RUN echo "$(cut -d ' ' -f 1 /tmp/tini.sha256sum)  /usr/bin/tini" | sha256sum -c - \
    && rm /tmp/tini.sha256sum

# pwuser is the image's non-root user; Playwright runs Chromium without its sandbox by default
RUN mkdir -p /TestFleet/artifacts && chown pwuser:pwuser /e2e /TestFleet/artifacts

USER pwuser

COPY --chown=pwuser:pwuser package.json package-lock.json ./
RUN npm ci --audit=false --fund=false --ignore-scripts && npm cache clean --force

COPY --chown=pwuser:pwuser tsconfig.json playwright.config.ts ./
COPY --chown=pwuser:pwuser src ./src

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "node", "src/run.ts"]
