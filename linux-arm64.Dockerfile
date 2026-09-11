# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
ARG UPSTREAM_IMAGE
ARG UPSTREAM_TAG_SHA
ARG UPSTREAM_DIGEST_ARM64
ARG BUN_IMAGE=oven/bun:1.4.2-alpine@sha256:d888c0ae6c86d7866ff10c5aafdd9077b36aee6455b33dd270fb93c0dd5cef6f

FROM ${BUN_IMAGE} AS bun

FROM bun AS source
RUN apk add --no-cache curl
ARG VERSION
ARG SOURCE_SHA256
RUN mkdir /source && \
    curl -fsSL "https://github.com/edbfi/obzorarr/archive/${VERSION}.tar.gz" -o /tmp/source.tar.gz && \
    echo "${SOURCE_SHA256}  /tmp/source.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/source.tar.gz -C /source --strip-components=1 && \
    rm /tmp/source.tar.gz

FROM bun AS dependencies
RUN apk add --no-cache build-base python3
WORKDIR /build
COPY --from=source /source/package.json /source/bun.lock /source/bunfig.toml ./
# Defer project preparation until source is present; dependency install scripts stay enabled.
RUN bun -e 'const p = await Bun.file("package.json").json(); delete p.scripts.prepare; delete p.scripts.postinstall; await Bun.write("package.json", JSON.stringify(p));'
RUN bun install --frozen-lockfile

FROM dependencies AS builder
COPY --from=source /source/ ./
ARG VERSION
ENV COMMIT_TAG=${VERSION}
RUN bun run prepare && bun run build

FROM bun AS production-dependencies
WORKDIR /build
COPY --from=dependencies /build/package.json /build/bun.lock /build/bunfig.toml ./
RUN bun install --production --frozen-lockfile

FROM ${UPSTREAM_IMAGE}@${UPSTREAM_DIGEST_ARM64}
ARG IMAGE_STATS
ARG VERSION
ENV IMAGE_STATS=${IMAGE_STATS} PORT=3000 WEBUI_PORTS="3000/tcp,3000/udp" \
    NODE_ENV=production COMMIT_TAG=${VERSION}
EXPOSE ${PORT}

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=builder /build/build "${APP_DIR}/build"
COPY --from=builder /build/drizzle "${APP_DIR}/drizzle"
COPY --from=production-dependencies /build/node_modules "${APP_DIR}/node_modules"
COPY --from=builder /build/package.json "${APP_DIR}/package.json"

RUN mkdir -p "${CONFIG_DIR}/data" && \
    rm -rf "${APP_DIR}/data" && ln -s "${CONFIG_DIR}/data" "${APP_DIR}/data" && \
    chmod -R u=rwX,go=rX "${APP_DIR}"

COPY root/ /
RUN find /etc/s6-overlay/s6-rc.d -name "run*" -execdir chmod +x {} +
