# syntax=docker/dockerfile:1
# A fourth server: WoW Forever, Blizzard's Classic 1.60 client, with ForeverCore's playerbots
# (Karrz1/TrinityCore, branch forever-bots), built from source. Two images from this file:
#
#   the default target   bnetserver, worldserver and their tools, for the home server
#   --target tools       the map readers alone, built on the Mac, where the client is (`mac-extract`)
#
# Pinned to a commit of forever-bots; `FOREVER_REF` moves it. The world database is the release
# that commit names in `revision_data.h.in.cmake`.

ARG UBUNTU=ubuntu:24.04

FROM ${UBUNTU} AS source
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential clang cmake git ca-certificates libmysqlclient-dev libssl-dev libbz2-dev \
        libreadline-dev libncurses-dev libboost-all-dev \
    && rm -rf /var/lib/apt/lists/*
ARG FOREVER_REF=063c74ab24b4d2f1587526ad43bf7c8dde9650d5
RUN git init -q /src && cd /src && git remote add origin https://github.com/Karrz1/TrinityCore.git \
    && git fetch -q --depth 1 origin ${FOREVER_REF} && git checkout -q FETCH_HEAD
# CascLib opens the client's files read-write, which a read-only mount of the client refuses: the
# readers only read, so a refused open is tried again read-only.
RUN f=/src/dep/CascLib/src/common/FileStream.cpp \
    && sed -i 's#^\( *\)handle = open(szFileName, oflag | O_LARGEFILE);#&\n\1if(handle == -1 \&\& (errno == EROFS || errno == EACCES)) handle = open(szFileName, O_RDONLY | O_LARGEFILE);#' $f \
    && grep -q 'errno == EROFS' $f
# Upstream took the hired bots out (312fdf59), then a cherry-pick (7c70f336, ".bot add brings the class you
# picked") put back a command that hires them, and the module no longer compiles. That command's change is
# undone; drop the patch once upstream fixes it (the build stops here when it no longer applies).
COPY hire-revert.patch /tmp/
RUN cd /src && git apply -R /tmp/hire-revert.patch

# The map readers only: dbc, gt, cameras, maps, vmaps and mmaps from the client.
FROM source AS tools-build
ARG JOBS=8
RUN --mount=type=cache,target=/build,id=forever-tools-build \
    cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DSERVERS=0 -DSCRIPTS=none -DTOOLS=1 -DWITH_WARNINGS=0 \
        -DCMAKE_INSTALL_PREFIX=/opt/forever \
    && cmake --build /build -j"${JOBS}" --target mapextractor vmap4extractor vmap4assembler mmaps_generator \
    && mkdir -p /opt/forever/bin \
    && cd /build/bin/Release/bin && cp mapextractor vmap4extractor vmap4assembler mmaps_generator /opt/forever/bin/

FROM ${UBUNTU} AS tools
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libbz2-1.0 libssl3t64 zlib1g libboost-filesystem1.83.0 libboost-program-options1.83.0 \
        libboost-regex1.83.0 libboost-locale1.83.0 libboost-thread1.83.0 libboost-iostreams1.83.0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=tools-build /opt/forever /opt/forever
COPY forever-extract /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/forever-extract"]

# The servers, with the bots module. The objects stay in a build cache, so a newer FOREVER_REF
# rebuilds only what changed. JOBS leaves the machine's other servers some cores.
FROM source AS build
ARG JOBS=6
RUN --mount=type=cache,target=/build,id=forever-build \
    cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DSERVERS=1 -DSCRIPTS=static -DTOOLS=0 -DWITH_WARNINGS=0 \
        -DBUILD_PLAYERBOT_V2=1 -DCMAKE_INSTALL_PREFIX=/opt/forever \
    && cmake --build /build -j"${JOBS}" && cmake --install /build

# The world and hotfixes databases, as released: the worldserver imports them on its first start
# from its working directory, then applies the `sql/custom` files that came after.
FROM ${UBUNTU} AS database
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl p7zip-full \
    && rm -rf /var/lib/apt/lists/*
COPY --from=source /src/revision_data.h.in.cmake /tmp/
ARG TDB=forever-tdb-2026-10-14/TDB_full_forever_2026_10_14.7z
RUN mkdir /tdb && cd /tdb \
    && curl -fsSL --retry 3 -o tdb.7z "https://github.com/Karrz1/TrinityCore/releases/download/${TDB}" \
    && 7z e -y tdb.7z '*.sql' -r >/dev/null && rm tdb.7z \
    # The dump's views name their definer, an account this database does not have.
    && sed -i -E 's#/\*!50013 DEFINER=`[^`]*`@`[^`]*` SQL SECURITY DEFINER \*/##' *.sql \
    && for f in $(sed -n 's/^#define DATABASE_\(FULL\|HOTFIXES\)_DATABASE *"\(.*\)"/\2/p' /tmp/revision_data.h.in.cmake); do \
           [ -f "$f" ] || { echo "the release has no $f" >&2; exit 1; }; done

# The bots' chat (`--target chat`, the compose file's `chat`): the bots module's own chat program, as the
# pinned commit ships it, talking through the bot bridge's files; and `claude-relay`, which gives it
# Claude in place of a local Ollama. `chat-start` picks one from `.env` (AI_CHAT, see there).
FROM python:3.13-slim AS chat
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir anthropic==2.8.0
# The chat test set comes along (`bot_bridge_eval.py`, run by the forever-bots skill).
COPY --from=source /src/src/modules/PlayerbotV2/tools/bot_bridge_ollama.py \
     /src/src/modules/PlayerbotV2/tools/bot_bridge_eval.py \
     /src/src/modules/PlayerbotV2/tools/bot_bridge_eval_cases.jsonl /opt/chat/
COPY chat/claude-relay chat/chat-start chat/bridge-report /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/chat-start"]

FROM ${UBUNTU}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates openssl tzdata mysql-client libmysqlclient21 libssl3t64 libbz2-1.0 libreadline8t64 \
        libncurses6 libboost-filesystem1.83.0 libboost-program-options1.83.0 libboost-regex1.83.0 \
        libboost-locale1.83.0 libboost-thread1.83.0 libboost-iostreams1.83.0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/forever /opt/forever
# The updater and the bots' migrations read their SQL from the source tree (`SourceDirectory`).
COPY --from=source /src/sql /src/sql
COPY --from=source /src/src/modules/PlayerbotV2/sql /src/src/modules/PlayerbotV2/sql
COPY --from=database /tdb/ /opt/forever/bin/
COPY forever-start forever-install /usr/local/bin/
ENV LD_LIBRARY_PATH=/opt/forever/lib
WORKDIR /opt/forever/bin
