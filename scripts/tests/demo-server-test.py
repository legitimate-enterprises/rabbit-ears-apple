"""Exercise demo isolation and the real server's scanned media/artwork contract."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "with-demo-server.py"


class DemoServerTests(unittest.TestCase):
    def test_child_gets_anonymous_scanned_library_and_failure_is_propagated(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Path(folder) / "probe.py"
            probe.write_text('''import json, os, pathlib, urllib.request
base = os.environ["RABBIT_EARS_UI_SERVER"] + "/api/v2"
def api(path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(base + path, data=json.dumps(data).encode() if data else None, headers=headers)
    with urllib.request.urlopen(request) as response: return json.load(response)
signed = api("/auth/sign-in", {"email": os.environ["RABBIT_EARS_UI_EMAIL"], "password": os.environ["RABBIT_EARS_UI_PASSWORD"], "deviceName": "demo-test", "platform": "ios"})
token = signed["token"]
assert sorted(p["name"] for p in signed["me"]["profiles"]) == ["Alex", "Jamie", "Sam"]
assert signed["me"]["profiles"][0]["name"] == "Alex"
items = api("/items?kind=movie", token=token)["items"]
assert len(items) == 6, items
for item in items:
    assert item["metadata"]["overview"]
    for url in (item["posterUrl"], item["backdropUrl"]):
        assert url.startswith("/api/v2/artwork/"), url
        request = urllib.request.Request(os.environ["RABBIT_EARS_UI_SERVER"] + url, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(request) as response:
            assert "immutable" in response.headers["Cache-Control"], response.headers
            assert len(response.read()) > 1000
profile = signed["me"]["account"]["id"]
states = api("/profiles/" + str(profile) + "/watch-state", token=token)["items"]
titles = {item["id"]: item["parsedTitle"] for item in items}
assert [(titles[s["itemId"]], s["positionMs"], s["watched"]) for s in states] == [
    ("Blue Horizon", 45000, False), ("Golden Hour", 30000, False)]
assert all(titles[s["itemId"]] != "Aurora" for s in states)
assert os.environ["TEST_RUNNER_RABBIT_EARS_UI_MOVIE"] == "Aurora"
pathlib.Path(os.environ["DEMO_TEST_RECORD"]).write_text(base)
raise SystemExit(23)
''')
            record = Path(folder) / "record"
            env = dict(os.environ, DEMO_TEST_RECORD=str(record), RABBIT_EARS_TMDB_KEY="must-not-be-used")
            result = subprocess.run([sys.executable, str(SCRIPT), "--", sys.executable, str(probe)], env=env)
            self.assertEqual(result.returncode, 23)
            self.assertTrue(record.exists())
            import urllib.error
            import urllib.request
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(record.read_text() + "/health", timeout=2)


if __name__ == "__main__":
    unittest.main()
