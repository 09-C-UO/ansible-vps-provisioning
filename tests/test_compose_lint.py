"""Unit tests for filter_plugins/app_compose.py. Run: python3 tests/test_compose_lint.py"""
import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "filter_plugins"))
from app_compose import compose_violations  # noqa: E402

APP = {
    "name": "demo",
    "compose_dir": "/opt/apps/demo",
    "allowed_bind_roots": ["/opt/apps/demo", "/srv/apps/demo"],
    "allowed_cap_add": {"db": ["CHOWN", "SETUID"]},
    "web": {"service": "web"},
}
GOOD = {
    "services": {
        "web": {"image": "x", "cap_drop": ["ALL"], "read_only": True,
                "volumes": ["/srv/apps/demo/public:/usr/share/nginx/html:ro"]},
        "db": {"image": "postgres", "cap_drop": ["ALL"], "cap_add": ["CHOWN", "SETUID"],
               "volumes": ["pgdata:/var/lib/postgresql/data", "./init.sql:/init.sql:ro"]},
    },
    "volumes": {"pgdata": {}},
}


def with_change(service, **changes):
    compose = copy.deepcopy(GOOD)
    compose["services"][service].update(changes)
    return compose_violations(compose, APP)


class ComposeLintTest(unittest.TestCase):
    def test_good_compose_passes(self):
        self.assertEqual(compose_violations(GOOD, APP), [])

    def test_forbidden_settings(self):
        cases = {
            "privileged": {"privileged": True},
            "network_mode": {"network_mode": "host"},
            "pid": {"pid": "host"},
            "published ports": {"ports": ["8080:8080"]},
            "devices": {"devices": ["/dev/sda"]},
            "container_name": {"container_name": "web"},
            "cap_drop": {"cap_drop": []},
            "cap_add": {"cap_add": ["SYS_ADMIN"]},
            "security_opt": {"security_opt": ["seccomp=unconfined"]},
            "Docker socket": {"volumes": ["/var/run/docker.sock:/var/run/docker.sock"]},
            "outside": {"volumes": ["/etc:/host-etc:ro"]},
            "edge": {"networks": ["edge"]},
        }
        for expected, change in cases.items():
            with self.subTest(expected):
                problems = with_change("web", **change)
                self.assertTrue(any(expected in problem for problem in problems), problems)

    def test_relative_escape_is_refused(self):
        problems = with_change("web", volumes=["../../../etc:/x"])
        self.assertTrue(any("outside" in problem for problem in problems), problems)

    def test_long_syntax_bind_is_checked(self):
        problems = with_change("web", volumes=[{"type": "bind", "source": "/root", "target": "/r"}])
        self.assertTrue(any("outside" in problem for problem in problems), problems)

    def test_missing_web_service(self):
        app = dict(APP, web={"service": "api"})
        self.assertTrue(any("web service" in p for p in compose_violations(GOOD, app)))

    def test_external_network_is_refused(self):
        compose = copy.deepcopy(GOOD)
        compose["networks"] = {"other_app": {"external": True}}
        self.assertTrue(compose_violations(compose, APP))


if __name__ == "__main__":
    unittest.main(verbosity=1)
