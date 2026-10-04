# Fixture test suite for the Docker integration tests (the spec's "Testing" section).
FROM alpine:3

RUN adduser -D -u 10001 suite \
 && mkdir -p /TestFleet/artifacts \
 && chown -R suite:suite /TestFleet

COPY --chmod=0755 run.sh /usr/local/bin/run.sh

USER suite
ENTRYPOINT ["/usr/local/bin/run.sh"]
