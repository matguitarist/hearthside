"""Which of the bots' talk lines go to the model: called by the bots' chat program (`chat-start` adds the
call to its `talk` branch). A post in General or Trade is asked for only when the bot is in a zone where a
real player is, from /bridge/players.json (`player-zones`); elsewhere nobody would read it, and on Claude
it would cost. A skipped post gets no answer, and the server goes on as it does when none comes.

When the file is missing or stale (player-zones not running), every line goes through, as without
this gate.
"""

import datetime
import json
import os
import time

PLAYERS = "/bridge/players.json"
STALE_S = 120
_cache = {"mtime": None, "zones": set()}


def player_zones():
    """The zones real players are in, or None when that isn't known."""
    try:
        st = os.stat(PLAYERS)
    except OSError:
        return None
    if time.time() - st.st_mtime > STALE_S:
        return None
    if st.st_mtime != _cache["mtime"]:
        try:
            with open(PLAYERS, encoding="utf-8") as f:
                players = json.load(f).get("players", {})
            _cache["zones"] = {p.get("zone") for p in players.values()} - {None, ""}
            _cache["mtime"] = st.st_mtime
        except (OSError, ValueError, AttributeError):
            return None
    return _cache["zones"]


def fresh(event, max_age_s=60):
    """False for a line said over a minute ago. When the chat container restarts, the program reads the hour's
    events from the start and would answer them all again; the server no longer says an answer that late."""
    try:
        said = datetime.datetime.strptime(event.get("t", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return True
    return time.time() - said.timestamp() < max_age_s


def talk_ok(event):
    if not fresh(event):
        return False
    # The /say talks (gatherings at a city gate, street chats) only start where a real player walks, and the
    # gate's bots may stand in the zone next to his: those always go through. Posts in General and Trade come
    # from any awake bot, wherever it is.
    if event.get("channel") not in ("general", "trade"):
        return True
    zones = player_zones()
    return zones is None or event.get("zone") in zones
