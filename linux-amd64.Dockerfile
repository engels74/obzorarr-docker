ARG UPSTREAM_IMAGE
ARG UPSTREAM_DIGEST_AMD64

FROM oven/bun:alpine AS builder
RUN apk add --no-cache curl
ARG VERSION
ENV COMMIT_TAG=${VERSION}
RUN mkdir /build && \
    curl -fsSL "https://github.com/engels74/obzorarr/archive/${VERSION}.tar.gz" | tar xzf - -C "/build" --strip-components=1 && \
    cd /build && \
    bun install --frozen-lockfile && \
    bun run build && \
    rm -rf node_modules && \
    bun install --production --frozen-lockfile


FROM ${UPSTREAM_IMAGE}@${UPSTREAM_DIGEST_AMD64}
EXPOSE 3000
ARG IMAGE_STATS
ENV IMAGE_STATS=${IMAGE_STATS} WEBUI_PORTS="3000/tcp,3000/udp"

RUN apk add --no-cache curl unzip && \
    curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/ && \
    rm -rf /root/.bun

COPY --from=builder /build/build "${APP_DIR}/build"
COPY --from=builder /build/drizzle "${APP_DIR}/drizzle"
COPY --from=builder /build/node_modules "${APP_DIR}/node_modules"
COPY --from=builder /build/package.json "${APP_DIR}/package.json"

RUN mkdir -p "${CONFIG_DIR}/data" && \
    rm -rf "${APP_DIR}/data" && ln -s "${CONFIG_DIR}/data" "${APP_DIR}/data" && \
    chmod -R u=rwX,go=rX "${APP_DIR}"

COPY root/ /
RUN find /etc/s6-overlay/s6-rc.d -name "run*" -execdir chmod +x {} +
