# Multi-stage Dockerfile for the DrivewayOS Phoenix release.
#
# Stage 1 builds the release; stage 2 ships only the compiled
# release + system runtime (no Erlang/Elixir/Mix), which keeps the
# final image small.
#
# Both stages pin Elixir + OTP versions to match the .tool-versions
# / mix.exs requirement: Elixir 1.18, OTP 27, Debian Trixie.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=trixie-20251020-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --------------------------------------------------------------- #
# Stage 1: Build the release
# --------------------------------------------------------------- #
FROM ${BUILDER_IMAGE} AS builder

# Install build deps
RUN apt-get update -y && \
    apt-get install -y build-essential git curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Hex + Rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Pull deps. Order matters for layer caching: pull deps before
# copying the rest of the source so a code-only change doesn't
# bust the deps layer.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time configs (no runtime config yet)
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Source + assets
COPY priv priv
COPY lib lib
COPY assets assets

# Build assets (esbuild + tailwind) and digest them
RUN mix assets.deploy

# Compile the rest of the app
RUN mix compile

# Runtime config
COPY config/runtime.exs config/

# Release scripts (server, migrate)
COPY rel rel

# Build the release
RUN mix release

# --------------------------------------------------------------- #
# Stage 2: Final runtime image
# --------------------------------------------------------------- #
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates wget && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale (Phoenix/Elixir default to UTF-8)
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Copy the release from the builder stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/driveway_os ./

USER nobody

# Healthcheck hits the /health endpoint that HealthController
# already serves. Interval 30s + 3 retries gives the load balancer
# ~90s to mark a container healthy — long enough for migrations to
# run on first boot but short enough that a wedged container is
# replaced quickly. start-period of 60s gives the BEAM time to come
# up before the first probe counts against retries.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget --quiet --tries=1 --spider "http://localhost:${PORT:-4000}/health" || exit 1

# Run migrations on container start, then boot the server. The
# `bin/server` script comes from rel/overlays/bin/server.
CMD ["/bin/sh", "-c", "/app/bin/migrate && /app/bin/server"]
