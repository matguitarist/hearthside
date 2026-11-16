# The login's relay while the game runs: `relay.py <host> <executable> <port>...`.
#
# The Forever client won't connect to a private address for the Battle.net login. keyswap sends
# the login name to localhost instead, and this relay forwards each port from 127.0.0.1 to the home
# server. It quits once the game has quit: forever-play starts it in the background beside the game.
import asyncio
import re
import subprocess
import sys

host, executable, ports = sys.argv[1], sys.argv[2], [int(p) for p in sys.argv[3:]]


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except OSError:
        pass
    finally:
        writer.close()


def handler(port):
    async def handle(reader, writer):
        try:
            far_reader, far_writer = await asyncio.open_connection(host, port)
        except OSError as error:
            print(f"relay: {host}:{port} unreachable: {error}", file=sys.stderr, flush=True)
            writer.close()
            return
        await asyncio.gather(pipe(reader, far_writer), pipe(far_reader, writer))
    return handle


def game_running():
    # Anchored: this relay's own command line holds the path too.
    pattern = "^" + re.escape(executable)
    return subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0


async def main():
    servers = [await asyncio.start_server(handler(p), "127.0.0.1", p) for p in ports]
    print("relay: listening", flush=True)
    # Up to a minute for the game to start, then as long as it runs.
    for _ in range(60):
        if game_running():
            break
        await asyncio.sleep(1)
    while game_running():
        await asyncio.sleep(5)
    for server in servers:
        server.close()


asyncio.run(main())
