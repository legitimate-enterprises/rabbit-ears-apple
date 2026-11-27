#!/usr/bin/env python3
"""Run a command against a disposable server with original, anonymous demo media.

The child receives RABBIT_EARS_UI_{SERVER,EMAIL,PASSWORD,PROFILE,MOVIE} and
TEST_RUNNER_ equivalents. No production configuration or media is read.
"""
import json
import math
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
EMAIL = "alex@example.invalid"
PASSWORD = "demo-household-password"
MOVIES = (
    ("Aurora", 2024, "A quiet journey beyond the northern lights, where the night sky reveals a world of color.", (14, 36, 61), (77, 191, 171)),
    ("Golden Hour", 2023, "Two travelers follow the last light across the desert and find a new way home.", (75, 33, 56), (239, 166, 83)),
    ("Blue Horizon", 2025, "Along a remote coastline, an oceanographer discovers the stories carried by the tide.", (11, 48, 75), (74, 174, 209)),
    ("Wildflower", 2022, "A small mountain village comes together to restore a garden that connects generations.", (39, 51, 57), (155, 185, 119)),
    ("After the Rain", 2024, "An unexpected friendship begins on a misty morning in the hills.", (28, 42, 67), (170, 151, 201)),
    ("The Long Way Home", 2021, "An old map leads a family on an unforgettable trip through the high country.", (56, 46, 45), (218, 147, 96)),
)


def run(*args, **kwargs):
    """Keep build and encoder output out of the child command's stdout."""
    return subprocess.run(args, check=True, stdout=sys.stderr, **kwargs)


def artwork(path, width, height, dark, light, variant):
    """Draw original landscape artwork; no external media or image library is needed."""
    rows = bytearray()
    mountains = [tuple(max(0, int(c * (0.70 - layer * 0.17))) for c in dark) for layer in range(3)]
    ridges = [[0.50 + layer * 0.16 + 0.09 * math.sin(x / width * (9 + layer * 2) + variant + layer)
               + 0.035 * math.sin(x / width * 31 + layer) for layer in range(3)] for x in range(width)]
    sun_x = [(x / width - 0.67) ** 2 for x in range(width)]
    for y in range(height):
        v = y / height
        mix = min(1, v * 1.25)
        sky = tuple(int(a + (b - a) * mix) for a, b in zip(dark, light))
        sun_y = ((v - 0.31) * height / width) ** 2
        for x in range(width):
            color = (248, 220, 167) if sun_x[x] + sun_y < 0.065 ** 2 else sky
            for layer in range(3):
                if v > ridges[x][layer]:
                    color = mountains[layer]
            rows.extend(color)
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + rows)


def media(folder):
    """Embed metadata and a cover so the normal local scan supplies the catalog."""
    library = folder / "movies"
    for index, (title, year, overview, dark, light) in enumerate(MOVIES):
        dest = library / f"{title} ({year})"
        dest.mkdir(parents=True)
        backdrop, poster = dest / "backdrop.ppm", dest / "poster.ppm"
        artwork(backdrop, 960, 540, dark, light, index)
        artwork(poster, 480, 720, dark, light, index)
        cover = dest / "cover.jpg"
        run("ffmpeg", "-v", "error", "-y", "-i", str(poster), "-frames:v", "1", str(cover))
        # A real H.264/AAC stream, kept within software decoder limits.
        run("ffmpeg", "-v", "error", "-y", "-loop", "1", "-framerate", "24", "-i", str(backdrop),
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-i", str(cover),
            "-map", "0:v", "-map", "1:a", "-map", "2:v", "-t", "90",
            "-c:v:0", "libx264", "-threads:v:0", "2", "-profile:v:0", "high", "-level:v:0", "4.1", "-pix_fmt:v:0", "yuv420p",
            "-preset", "ultrafast", "-crf", "24", "-g", "48", "-c:v:1", "copy", "-disposition:v:1", "attached_pic",
            "-c:a", "aac", "-b:a", "64k", "-metadata", f"title={title}", "-metadata", f"date={year}",
            "-metadata", f"description={overview}", "-metadata", "genre=Adventure",
            "-movflags", "+faststart", str(dest / f"{title} ({year}).mp4"))
    return library


class API:
    """Seed through the public API so fixtures exercise normal server wiring."""
    def __init__(self, base):
        self.base, self.token = base, None

    def call(self, path, data=None, method=None):
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.base + "/api/v2" + path,
                                         data=None if data is None else json.dumps(data).encode(),
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{request.method} {path}: {error.code} {error.read().decode()}") from error

    def seed(self, library):
        result = self.call("/setup", dict(serverName="The Living Room", name="Alex", email=EMAIL,
                                         password=PASSWORD, deviceName="Demo setup", platform="web"))
        self.token = result["token"]
        self.call("/settings", dict(serverName="The Living Room", metadataSource="local",
                                    metadataMode="only", gravatar=False), "PUT")
        for name, birthday in (("Sam", "2014-01-01"), ("Jamie", "2017-01-01")):
            self.call("/profiles", dict(name=name, birthday=birthday))
        made = self.call("/libraries", dict(name="Movies", kind="movies"))
        self.call(f"/libraries/{made['id']}/folders", dict(path=str(library)))
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            items = self.call("/items?kind=movie")["items"]
            if len(items) == len(MOVIES) and all(i.get("metadata", {}).get("posterPath")
                                               and i.get("metadata", {}).get("backdropPath")
                                               and i.get("metadata", {}).get("overview") for i in items):
                # Fixed playback history makes the hero and progress row repeatable without
                # advancing Aurora, whose position is the UI playback test's assertion.
                profile = result["me"]["account"]["id"]
                by_title = {item["parsedTitle"]: item["id"] for item in items}
                for title, position, at in (("Golden Hour", 30000, "2024-06-01T12:00:00Z"),
                                            ("Blue Horizon", 45000, "2024-06-02T12:00:00Z")):
                    self.call(f"/profiles/{profile}/watch-state/{by_title[title]}",
                              dict(watched=False, positionMs=position, at=at), "PUT")
                return
            time.sleep(1)
        raise RuntimeError("Demo library scan did not produce six movies with metadata and artwork")

    def fixtures(self, folder):
        """Add libraries over the server's own test media: a show, music and YouTube channels."""
        made = [self.call("/libraries", dict(name=name, kind=kind))["id"]
                for name, kind in (("TV", "tv"), ("Music", "music"), ("YouTube", "youtube"))]
        for library, path in zip(made, ("library/TV", "music", "youtube")):
            self.call(f"/libraries/{library}/folders", dict(path=str(folder / path)))
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            scans = {task["kind"]: task for task in self.call("/tasks?limit=200")["items"]}
            runs = [scans.get(f"scan:{library}", {}).get("lastRun", {}) for library in made]
            failed = [last.get("error", "no error stated") for last in runs if last.get("status") == "failed"]
            if failed:
                raise RuntimeError("A fixture library scan failed: " + "; ".join(failed))
            if all(last.get("finishedAt") for last in runs):
                return
            time.sleep(1)
        raise RuntimeError("The server's fixtures did not scan")


def child_environment(base):
    """Publish only anonymous demo credentials to clients and XCTest runners."""
    env = dict(os.environ)
    values = dict(SERVER=base, EMAIL=EMAIL, PASSWORD=PASSWORD, PROFILE="Alex", MOVIE="Aurora")
    for key, value in values.items():
        env["RABBIT_EARS_UI_" + key] = value
        env["TEST_RUNNER_RABBIT_EARS_UI_" + key] = value
    return env


def main(command):
    # With --fixtures the server's own test media are scanned too, for tests beyond the screenshots' catalog.
    fixtures = command[:1] == ["--fixtures"]
    if fixtures:
        command = command[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit("usage: with-demo-server.py [--fixtures] -- command [args...]")
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    with tempfile.TemporaryDirectory(prefix="rabbit-ears-demo-") as temp:
        folder = Path(temp)
        library = media(folder)
        executable = folder / "rabbit-ears"
        source = subprocess.run([str(ROOT / "scripts/server-source.sh")], check=True,
                                stdout=subprocess.PIPE, text=True).stdout.strip()
        run("go", "build", "-o", str(executable), "./cmd/rabbit-ears", cwd=Path(source) / "server")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        # A clean environment prevents production metadata keys and storage paths leaking in.
        env = {key: value for key, value in os.environ.items() if not key.startswith("RABBIT_EARS_")}
        env.update(RABBIT_EARS_PORT=str(port), RABBIT_EARS_DB=str(folder / "demo.db"), RABBIT_EARS_DATA=str(folder))
        with (folder / "server.log").open("w+") as log:
            server = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
            try:
                api = API(base)
                for _ in range(100):
                    if server.poll() is not None:
                        raise RuntimeError("Demo server exited before becoming ready")
                    try:
                        api.call("/health")
                        break
                    except urllib.error.URLError:
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Demo server did not become ready")
                api.seed(library)
                if fixtures:
                    # fixtures/ is git-ignored in the server's repository, so a clone has none until this makes it.
                    run(str(Path(source) / "scripts/fetch-fixtures.sh"))
                    api.fixtures(Path(source) / "fixtures")
                print("Anonymous demo server ready: six movies, three profiles", file=sys.stderr)
                child = subprocess.Popen(command, env=child_environment(base), start_new_session=True)
                try:
                    code = child.wait()
                    if code:
                        # What the server did is the first question when the command fails.
                        log.seek(0)
                        print(log.read()[-10000:], file=sys.stderr)
                    return code
                except BaseException:
                    # Let the runner's signal trap remove its dedicated simulator before escalating.
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    raise
            except Exception:
                log.seek(0)
                print(log.read()[-10000:], file=sys.stderr)
                raise
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(130)
