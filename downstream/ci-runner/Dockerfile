FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8 AS base

RUN microdnf install -y tar gzip findutils procps-ng python3 && microdnf clean all

# kubectl / oc
COPY --from=registry.redhat.io/openshift4/ose-cli:latest /usr/bin/oc /usr/local/bin/oc
RUN ln -s /usr/local/bin/oc /usr/local/bin/kubectl

# bats-core
ADD https://github.com/bats-core/bats-core/archive/refs/tags/v1.12.0.tar.gz /tmp/bats.tar.gz
RUN tar xzf /tmp/bats.tar.gz -C /opt && /opt/bats-core-1.12.0/install.sh /usr/local && rm -rf /tmp/bats.tar.gz /opt/bats-core-1.12.0

# openshell CLI (linux/amd64, from build context)
COPY openshell /usr/local/bin/openshell
RUN chmod +x /usr/local/bin/openshell

# Pre-compiled Rust e2e test binary (optional — image works without it)
COPY openshell-e2e /usr/local/bin/openshell-e2e
RUN chmod +x /usr/local/bin/openshell-e2e 2>/dev/null || true

# Test scripts and helpers
COPY downstream/ /opt/ci/downstream/
RUN chmod +x /opt/ci/downstream/scripts/*.sh

WORKDIR /opt/ci
ENTRYPOINT ["/opt/ci/downstream/scripts/run-nightly.sh"]
CMD ["regression"]
