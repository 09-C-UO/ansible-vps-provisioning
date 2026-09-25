"""Checks that an application's compose file respects the hosting model.

The compose file is written by admin, rendered by Ansible and run by root, so
a single careless line (privileged, a published port, a docker.sock mount)
would hand the host to the application. Ansible refuses to deploy an
application while compose_violations() returns anything.
"""

import posixpath

HOST_NAMESPACE_KEYS = ("network_mode", "pid", "ipc", "uts", "userns_mode")
UNSAFE_SECURITY_OPTS = ("unconfined", "no-new-privileges:false", "no-new-privileges=false")
EDGE_NETWORK = "edge"


def _bind_sources(volumes):
    """Yield the host path of every bind mount (short and long syntax)."""
    for volume in volumes or []:
        if isinstance(volume, dict):
            if volume.get("type") == "bind":
                yield str(volume.get("source", ""))
            continue
        source = str(volume).split(":", 1)[0]
        if source.startswith(("/", ".", "~")):
            yield source


def _inside(path, roots):
    normalized = posixpath.normpath(path)
    return any(normalized == root or normalized.startswith(root + "/") for root in roots)


def compose_violations(compose, app):
    """Return the list of rules broken by a parsed compose file (empty = OK)."""
    name = app["name"]
    compose_dir = app["compose_dir"]
    allowed_roots = [posixpath.normpath(root) for root in app["allowed_bind_roots"]]
    allowed_caps = app.get("allowed_cap_add") or {}
    problems = []

    if not isinstance(compose, dict) or not isinstance(compose.get("services"), dict):
        return [f"{name}: no services defined"]
    services = compose["services"]

    web_service = app.get("web", {}).get("service")
    if web_service and web_service not in services:
        problems.append(f"{name}: web service '{web_service}' is not defined")

    for network_name, network in (compose.get("networks") or {}).items():
        if network_name == EDGE_NETWORK or (isinstance(network, dict) and network.get("external")):
            problems.append(f"{name}: network '{network_name}' must not be declared; "
                            "the web service joins the edge network automatically")

    for service_name, service in services.items():
        where = f"{name}/{service_name}"
        service = service or {}
        if service.get("privileged"):
            problems.append(f"{where}: privileged is forbidden")
        for key in HOST_NAMESPACE_KEYS:
            if str(service.get(key, "")) == "host":
                problems.append(f"{where}: {key}: host is forbidden")
        if service.get("ports"):
            problems.append(f"{where}: published ports are forbidden (Traefik is the only entry point)")
        if service.get("devices"):
            problems.append(f"{where}: devices are forbidden")
        if service.get("container_name"):
            problems.append(f"{where}: container_name is forbidden (names must stay per project)")
        if "ALL" not in [str(cap).upper() for cap in service.get("cap_drop") or []]:
            problems.append(f"{where}: cap_drop must contain ALL")
        extra_caps = sorted(set(str(cap).upper() for cap in service.get("cap_add") or [])
                            - set(str(cap).upper() for cap in allowed_caps.get(service_name, [])))
        if extra_caps:
            problems.append(f"{where}: cap_add {extra_caps} not listed in allowed_cap_add")
        for option in service.get("security_opt") or []:
            if any(unsafe in str(option).replace(" ", "") for unsafe in UNSAFE_SECURITY_OPTS):
                problems.append(f"{where}: security_opt '{option}' is forbidden")
        networks = service.get("networks") or []
        if EDGE_NETWORK in (networks if isinstance(networks, (list, dict)) else []):
            problems.append(f"{where}: joining '{EDGE_NETWORK}' is forbidden; "
                            "only the web service is attached, automatically")
        for source in _bind_sources(service.get("volumes")):
            if "docker.sock" in source:
                problems.append(f"{where}: mounting the Docker socket is forbidden")
                continue
            host_path = posixpath.normpath(posixpath.join(compose_dir, source))
            if source.startswith("~") or not _inside(host_path, allowed_roots):
                problems.append(f"{where}: bind mount '{source}' is outside {allowed_roots}")
    return problems


class FilterModule:
    def filters(self):
        return {"compose_violations": compose_violations}
