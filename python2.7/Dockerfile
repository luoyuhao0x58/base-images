ARG DEB_IMAGE=python:2.7-deb
FROM ${DEB_IMAGE} AS builder

FROM debian:13-slim
ARG DEBIAN_FRONTEND=noninteractive
COPY --from=builder /py27.deb /

# debian slim images ship an empty /var/lib/apt/lists, so apt cannot resolve
# the deb's Depends until the index is fetched. Without the update it fails with
# "python2.7 : Depends: libgdbm6t64 but it is not installable".
#
# ca-certificates is named explicitly because the deb only Recommends it and
# --no-install-recommends suppresses that. Without the CA bundle,
# ssl.create_default_context() fails with CERTIFICATE_VERIFY_FAILED.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates /py27.deb \
 && rm -f /py27.deb \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/local/bin/python2"]
