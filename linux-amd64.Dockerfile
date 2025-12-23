ARG UPSTREAM_IMAGE
ARG UPSTREAM_DIGEST_AMD64

FROM oven/bun:1-alpine AS builder
RUN apk add --no-cache curl
ARG VERSION
ENV COMMIT_TAG=${VERSION}
RUN mkdir /build && \
    curl -fsSL "https://github.com/engels74/obzorarr/archive/${VERSION}.tar.gz" | tar xzf - -C "/build" --strip-components=1 && \
    cd /build && \
    bun install --frozen-lockfile && \
    bun run build


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

ARG VERSION
RUN curl -fsSL "https://github.com/engels74/obzorarr/archive/${VERSION}.tar.gz" | tar xzf - -C "${APP_DIR}" --strip-components=1 && \
    echo '{"commitTag": "'"${VERSION}"'"}' > "${APP_DIR}/committag.json" && \
    mkdir -p "${CONFIG_DIR}/data" && \
    rm -rf "${APP_DIR}/data" && ln -s "${CONFIG_DIR}/data" "${APP_DIR}/data" && \
    chmod -R u=rwX,go=rX "${APP_DIR}"

COPY root/ /
