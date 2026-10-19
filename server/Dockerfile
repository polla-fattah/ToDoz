# Build from the repository root so the shared package is included:
#   docker build -f server/Dockerfile -t taskflow-server .
FROM dart:stable AS build
WORKDIR /src
COPY packages/taskflow_core packages/taskflow_core
COPY server server
WORKDIR /src/server
# `dart build cli` also bundles the SQLite library the server needs.
RUN dart pub get && dart build cli -t bin/taskflow_server.dart -o /out

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 taskflow \
    && mkdir /data && chown taskflow /data
COPY --from=build /out/bundle /opt/taskflow
USER taskflow
ENV TASKFLOW_DB=/data/taskflow.sqlite PATH=/opt/taskflow/bin:$PATH
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["taskflow_server"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8080", "--trust-proxy"]
