#syntax=docker/dockerfile:1.22
ARG GIT_COMMIT=unknown
ARG GIT_TAG=unknown
ARG GIT_TREE_STATE=unknown

# Optional pull-through registry prefix for the Docker Hub-hosted base
# images (golang:..., node:...). Empty default = pull from Docker Hub
# directly; when set (must end with `/`), prepends to the FROM lines
# so Hub pulls go through the mirror instead. Useful for builds behind
# anonymous-pull rate limits. The distroless stages below pull from
# gcr.io directly and are unaffected.
ARG REGISTRY_MIRROR=

FROM ${REGISTRY_MIRROR}golang:1.26.1-alpine3.23 AS builder

# Proxy build-args — declared so `docker build --build-arg HTTP_PROXY=...`
# reaches the apk / wget / curl / go calls below. Empty by default, no
# effect when unset. ARG (not ENV) so they do NOT persist into the final
# image.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# libc-dev to build openapi-gen
RUN apk update && apk add --no-cache \
    git \
    make \
    ca-certificates \
    wget \
    curl \
    gcc \
    libc-dev \
    bash \
    mailcap

WORKDIR /go/src/github.com/argoproj/argo-workflows
COPY go.mod .
COPY go.sum .
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .

####################################################################################################

FROM ${REGISTRY_MIRROR}node:20-alpine AS argo-ui

# Proxy build-args — see comment in builder stage above. Needed for
# `apk update` and `yarn install` calls behind a network proxy.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

RUN apk update && apk add --no-cache git

COPY ui/package.json ui/yarn.lock ui/

RUN --mount=type=cache,target=/root/.yarn \
  YARN_CACHE_FOLDER=/root/.yarn JOBS=max \
  yarn --cwd ui install --network-timeout 1000000

COPY ui ui
COPY api api

RUN --mount=type=cache,target=/root/.yarn \
  YARN_CACHE_FOLDER=/root/.yarn JOBS=max \
  NODE_OPTIONS="--max-old-space-size=2048" JOBS=max yarn --cwd ui build

####################################################################################################

FROM builder AS argoexec-build

ARG GIT_COMMIT
ARG GIT_TAG
ARG GIT_TREE_STATE

RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build make dist/argoexec GIT_COMMIT=${GIT_COMMIT} GIT_TAG=${GIT_TAG} GIT_TREE_STATE=${GIT_TREE_STATE}

####################################################################################################

FROM builder AS workflow-controller-build

ARG GIT_COMMIT
ARG GIT_TAG
ARG GIT_TREE_STATE

RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build make dist/workflow-controller GIT_COMMIT=${GIT_COMMIT} GIT_TAG=${GIT_TAG} GIT_TREE_STATE=${GIT_TREE_STATE}

####################################################################################################

FROM builder AS argocli-build

ARG GIT_COMMIT
ARG GIT_TAG
ARG GIT_TREE_STATE

RUN mkdir -p ui/dist
COPY --from=argo-ui ui/dist/app ui/dist/app
# update timestamp so that `make` doesn't try to rebuild this -- it was already built in the previous stage
RUN touch ui/dist/app/index.html

RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build STATIC_FILES=true make dist/argo GIT_COMMIT=${GIT_COMMIT} GIT_TAG=${GIT_TAG} GIT_TREE_STATE=${GIT_TREE_STATE}

####################################################################################################

FROM gcr.io/distroless/static-debian13:latest@sha256:28efbe90d0b2f2a3ee465cc5b44f3f2cf5533514cf4d51447a977a5dc8e526d0 AS argoexec-base

COPY --from=argoexec-build /etc/mime.types /etc/mime.types
COPY hack/ssh_known_hosts /etc/ssh/
COPY hack/nsswitch.conf /etc/

####################################################################################################

FROM argoexec-base AS argoexec-nonroot

USER 8737

COPY --chown=8737 --from=argoexec-build /go/src/github.com/argoproj/argo-workflows/dist/argoexec /bin/

ENTRYPOINT [ "argoexec" ]

####################################################################################################
FROM argoexec-base AS argoexec

COPY --from=argoexec-build /go/src/github.com/argoproj/argo-workflows/dist/argoexec /bin/

ENTRYPOINT [ "argoexec" ]

####################################################################################################

FROM gcr.io/distroless/static-debian13:latest@sha256:28efbe90d0b2f2a3ee465cc5b44f3f2cf5533514cf4d51447a977a5dc8e526d0 AS workflow-controller

USER 8737

COPY hack/ssh_known_hosts /etc/ssh/
COPY hack/nsswitch.conf /etc/
COPY --chown=8737 --from=workflow-controller-build /go/src/github.com/argoproj/argo-workflows/dist/workflow-controller /bin/

ENTRYPOINT [ "workflow-controller" ]

####################################################################################################

FROM gcr.io/distroless/static-debian13:latest@sha256:28efbe90d0b2f2a3ee465cc5b44f3f2cf5533514cf4d51447a977a5dc8e526d0 AS argocli

USER 8737

WORKDIR /home/argo

COPY hack/ssh_known_hosts /etc/ssh/
COPY hack/nsswitch.conf /etc/
COPY --from=argocli-build /go/src/github.com/argoproj/argo-workflows/dist/argo /bin/

ENTRYPOINT [ "argo" ]
