# Build Docker. ONE image, TWO entrypoints.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/lux
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/lux-ai-nimcache \
  --out:lux-ai \
  src/lux_ai.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/lux-ai-player-nimcache \
  --out:lux-ai-player \
  src/lux_ai_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/lux
COPY --from=build /workspace/lux/lux-ai /bin/lux-ai
COPY --from=build /workspace/lux/lux-ai-player /bin/lux-ai-player
COPY --from=build /workspace/lux/*.json ./
COPY --from=build /workspace/lux/data ./data
COPY --from=build /workspace/lux/client ./client

CMD ["/bin/lux-ai"]
