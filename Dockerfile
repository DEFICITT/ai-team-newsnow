FROM node:20.12.2-alpine AS builder
WORKDIR /usr/src
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.cloud.tencent.com|g' /etc/apk/repositories && \
    apk add --no-cache python3 build-base
COPY . .
RUN corepack enable
RUN pnpm config set registry https://registry.npmmirror.com && \
    pnpm config set better_sqlite3_binary_host_mirror https://registry.npmmirror.com/-/binary/better-sqlite3
RUN pnpm install
RUN pnpm run build

FROM node:20.12.2-alpine
WORKDIR /usr/app
RUN apk add --no-cache curl
COPY --from=builder /usr/src/dist/output ./output
ENV HOST=0.0.0.0 PORT=4444 NODE_ENV=production
EXPOSE $PORT
CMD ["node", "output/server/index.mjs"]
