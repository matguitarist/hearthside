# syntax=docker/dockerfile:1
# A third server, tried on the home server: Mists of Pandaria 5.4.8 (build 18414) with playerbots,
# from LoA-Pandaria-Playerbots, built from source (its releases are Windows only). One image serves
# the database install, the data extraction, authserver and worldserver. Pinned to the release the
# database dumps come from.

ARG UBUNTU=ubuntu:24.04

FROM ${UBUNTU} AS build
ARG PANDARIA_REF=9648ddfbb29c633200c02b08a9aaf4d75bf6ac58
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential g++-13 cmake git ca-certificates libmysqlclient-dev libssl-dev zlib1g-dev libbz2-dev \
        libreadline-dev libboost-all-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git init -q /src && cd /src && git remote add origin https://github.com/1LineAtaTime/LoA-Pandaria-Playerbots.git \
    && git fetch -q --depth 1 origin ${PANDARIA_REF} && git checkout -q FETCH_HEAD
# Detour defines its non-virtual dtQueryFilter::passFilter `inline` in the .cpp, which the playerbots'
# navmesh reach check calls from another file: MSVC links that, GCC does not. Made an ordinary one.
RUN sed -i 's/^inline bool dtQueryFilter::passFilter(/bool dtQueryFilter::passFilter(/' \
        /src/dep/recastnavigation/Detour/Source/DetourNavMeshQuery.cpp \
    && grep -q '^bool dtQueryFilter::passFilter(' /src/dep/recastnavigation/Detour/Source/DetourNavMeshQuery.cpp
# The objects stay in a build cache, so a change rebuilds only what it touches. JOBS leaves the
# machine's other servers some cores.
ARG JOBS=6
RUN --mount=type=cache,target=/build,id=pandaria-build \
    cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc-13 -DCMAKE_CXX_COMPILER=g++-13 \
        -DTOOLS=1 -DELUNA=0 -DCMAKE_INSTALL_PREFIX=/opt/pandaria \
    && cmake --build /build -j"${JOBS}" && cmake --install /build

FROM ${UBUNTU}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl unzip mysql-client libmysqlclient21 libssl3t64 zlib1g libbz2-1.0 libreadline8t64 \
        libboost-all-dev \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/pandaria /opt/pandaria
COPY --from=build /src/sql /opt/pandaria/sql
COPY --from=build /src/modules/mod_playerbots/config/playerbots.conf.dist /opt/pandaria/etc/playerbots.conf.dist
COPY pandaria-install /usr/local/bin/

# The configs, from each `.dist`: the databases at `database`, the data at /data, logs at /logs,
# no console (no terminal in a container), SOAP for the launcher's commands, inside the network.
# The playerbots module reads its config from the working directory, bin.
RUN cd /opt/pandaria/etc \
    && db='s#"127\.0\.0\.1;3306;[^;]*;[^;]*;\([a-z_]*\)"#"database;3306;pandaria;pandaria;\1"#' \
    && sed -e "$db" -e 's#^DataDir = .*#DataDir = "/data"#' -e 's#^LogsDir = .*#LogsDir = "/logs"#' \
        -e 's#^Console\.Enable = .*#Console.Enable = 0#' -e 's#^SOAP\.IP = .*#SOAP.IP = "0.0.0.0"#' \
        worldserver.conf.dist > worldserver.conf \
    && sed -e "$db" -e 's#^LogsDir = .*#LogsDir = "/logs"#' authserver.conf.dist > authserver.conf \
    && cp playerbots.conf.dist playerbots.conf && ln -s ../etc/playerbots.conf ../bin/playerbots.conf \
    && grep -q '^DataDir = "/data"' worldserver.conf && grep -q 'database;3306;pandaria;pandaria;world' worldserver.conf \
    && grep -q 'database;3306;pandaria;pandaria;auth' authserver.conf \
    && grep -q 'database;3306;pandaria;pandaria;playerbots' worldserver.conf

WORKDIR /opt/pandaria/bin
