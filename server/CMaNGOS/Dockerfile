# The launcher's second local server: CMaNGOS Classic with the playerbots module, built on this
# Mac at setup (nobody publishes arm64 images, and the playerbots module carries no license, so the
# app ships this recipe rather than a binary). One image serves the database install, the movement
# maps, realmd and mangosd. Each source is pinned to the commit the app was tested with.

ARG UBUNTU=ubuntu:24.04

FROM ${UBUNTU} AS build
ARG CMANGOS_REF=5731249195520323cb5fb9aa29761d4f033272ce
ARG PLAYERBOTS_REF=6823423e07789c875f55a0fee9beeae0d3b69561
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates libmysqlclient-dev libssl-dev zlib1g-dev libbz2-dev \
        libboost-system-dev libboost-program-options-dev libboost-thread-dev libboost-regex-dev \
        libboost-filesystem-dev libboost-serialization-dev \
    && rm -rf /var/lib/apt/lists/*
# `fetch` clones one commit of a repository into a folder.
RUN printf '#!/bin/sh\nset -eu\ngit init -q "$3" && cd "$3" && git remote add origin "$1" && git fetch -q --depth 1 origin "$2" && git checkout -q FETCH_HEAD\n' \
        > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch
RUN fetch https://github.com/cmangos/mangos-classic.git ${CMANGOS_REF} /src \
    && fetch https://github.com/cmangos/playerbots.git ${PLAYERBOTS_REF} /src/src/modules/PlayerBots
# Two guards for a map without movement maps (the generator skips none, but a failed tile would
# otherwise take the server down): a grid load asks for its navmesh tile and asserts; skip it.
RUN sed -i 's|^\( *\)MANGOS_ASSERT(itr != loadedMMaps.end()); // must not occur here|\1if (itr == loadedMMaps.end()) return false; // Azeroth Survivors: no mmap files. Was: must not occur here|' \
        /src/src/game/MotionGenerators/MoveMap.cpp \
    && grep -q 'Azeroth Survivors: no mmap files' /src/src/game/MotionGenerators/MoveMap.cpp
# And the bots' nearest-walkable-point lookup asserts a navmesh; without one it finds no point, as
# when the lookup misses.
RUN sed -i 's|^\( *\)MANGOS_ASSERT(query \&\& query->getAttachedNavMesh());|\1if (!query \|\| !query->getAttachedNavMesh()) return false; // Azeroth Survivors: no mmap files|' \
        /src/src/modules/PlayerBots/playerbot/WorldPosition.cpp \
    && grep -q 'Azeroth Survivors: no mmap files' /src/src/modules/PlayerBots/playerbot/WorldPosition.cpp
RUN cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DPCH=1 -DCMAKE_INSTALL_PREFIX=/opt/cmangos \
        -DBUILD_PLAYERBOTS=ON -DBUILD_EXTRACTORS=ON -DFETCHCONTENT_SOURCE_DIR_PLAYERBOTS=/src/src/modules/PlayerBots \
    && cmake --build /build -j"$(nproc)" && cmake --install /build

FROM ${UBUNTU}
ARG CLASSICDB_REF=603ece109099ce44a5447a1b1cffd65c7272d71c
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git mariadb-client libmysqlclient21 libssl3t64 zlib1g libbz2-1.0 \
        libboost-system1.83.0 libboost-program-options1.83.0 libboost-thread1.83.0 libboost-regex1.83.0 \
        libboost-filesystem1.83.0 libboost-serialization1.83.0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/fetch /usr/local/bin/fetch
COPY --from=build /opt/cmangos /opt/cmangos
# The installer reads the core's base SQL and the playerbots SQL under CORE_PATH.
COPY --from=build /src/sql /opt/cmangos/core/sql
COPY --from=build /src/src/modules/PlayerBots/sql /opt/cmangos/core/src/modules/PlayerBots/sql
RUN fetch https://github.com/cmangos/classic-db.git ${CLASSICDB_REF} /opt/cmangos/classic-db \
    && rm -rf /opt/cmangos/classic-db/.git
COPY InstallFullDB.config /opt/cmangos/classic-db/InstallFullDB.config
COPY cmangos-install /usr/local/bin/

# The configs, from each `.dist` with this server's changes: the database at `database`, the data at
# /data, no anticheat (it arms Warden for every session, and the client has none), a player who
# logs in as a player, and 100 random bots. Line of sight and pathing stay on (`build-mmaps`).
RUN cd /opt/cmangos/etc \
    && sed -E -e 's#127\.0\.0\.1;3306#database;3306#' -e 's#^DataDir = .*#DataDir = "/data"#' -e 's#^LogsDir = .*#LogsDir = "/logs"#' \
        -e 's#^Console\.Enable = .*#Console.Enable = 0#' -e 's#^GameType = .*#GameType = 0#' \
        -e 's#^GM\.LoginState( *)= .*#GM.LoginState\1= 0#' -e 's#^GM\.Visible( *)= .*#GM.Visible\1= 1#' \
        mangosd.conf.dist > mangosd.conf \
    && sed -E -e 's#127\.0\.0\.1;3306#database;3306#' -e 's#^LogsDir = .*#LogsDir = "/logs"#' realmd.conf.dist > realmd.conf \
    && sed -E -e 's#^Enable = .*#Enable = 0#' -e 's#^Warden\.Enable = .*#Warden.Enable = 0#' anticheat.conf.dist > anticheat.conf \
    && sed -E -e 's#^AiPlayerbot\.MinRandomBots = .*#AiPlayerbot.MinRandomBots = 100#' \
        -e 's#^AiPlayerbot\.MaxRandomBots = .*#AiPlayerbot.MaxRandomBots = 100#' \
        -e 's#^AiPlayerbot\.RandomBotAccountCount = .*#AiPlayerbot.RandomBotAccountCount = 20#' \
        aiplayerbot.conf.dist > aiplayerbot.conf \
    && sed -E -e 's#^AuctionHouseBot\.Seller\.Enabled = .*#AuctionHouseBot.Seller.Enabled = 1#' \
        -e 's#^AuctionHouseBot\.Buyer\.Enabled = .*#AuctionHouseBot.Buyer.Enabled = 1#' ahbot.conf.dist > ahbot.conf \
    && grep -q '^Enable = 0' anticheat.conf && grep -q '^mmap.enabled = 1' mangosd.conf \
    && grep -q '^AiPlayerbot.MaxRandomBots = 100' aiplayerbot.conf

# The servers read `../etc/` from their working directory.
WORKDIR /opt/cmangos/bin
