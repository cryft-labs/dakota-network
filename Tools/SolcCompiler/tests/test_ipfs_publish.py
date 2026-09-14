"""Real offline Kubo tests; no public swarm, production secrets or remote writes."""
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
import solcx

TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
import ipfs_publish as publishing

spec = importlib.util.spec_from_file_location("ipfs_test_compiler", TOOL_DIR / "compile.py")
compiler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler)
config_spec = importlib.util.spec_from_file_location("backend_ipfs_config", TOOL_DIR / "deploy/backend-ipfs/configure.py")
backend_config = importlib.util.module_from_spec(config_spec)
config_spec.loader.exec_module(backend_config)


@pytest.fixture(autouse=True)
def clean_ipfs_environment(monkeypatch):
    for name in list(os.environ):
        if name.startswith("IPFS_") and name != "IPFS_TEST_BINARY":
            monkeypatch.delenv(name)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest.fixture(scope="module")
def kubo(tmp_path_factory):
    binary = os.getenv("IPFS_TEST_BINARY")
    if not binary:
        pytest.skip("Set IPFS_TEST_BINARY to a verified Kubo binary for offline integration tests")
    directory = tmp_path_factory.mktemp("kubo")
    environment = dict(os.environ, IPFS_PATH=str(directory / "repo"))
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    subprocess.run([binary, "init", "--profile=server"], env=environment, check=True,
                   capture_output=True, creationflags=flags, timeout=30)
    path = directory / "repo/config"
    config = json.loads(path.read_text(encoding="utf-8"))
    config = backend_config.settings(config, nebula_ip="127.0.0.1", overlay_cidr="127.0.0.0/8")
    port = free_port()
    config["Addresses"]["API"] = f"/ip4/127.0.0.1/tcp/{port}"
    config["Addresses"]["Gateway"] = f"/ip4/127.0.0.1/tcp/{free_port()}"
    config["Addresses"]["Swarm"] = []
    config["Bootstrap"] = []
    config["Routing"]["Type"] = "none"
    path.write_text(json.dumps(config), encoding="utf-8")
    with (directory / "daemon.log").open("wb") as log:
        process = subprocess.Popen([binary, "daemon", "--offline", "--migrate=false"], env=environment,
                                   stdout=log, stderr=log, creationflags=flags)
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    pytest.fail("Offline Kubo exited during startup")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        break
                except OSError:
                    time.sleep(0.1)
            else:
                pytest.fail("Offline Kubo did not become ready")
            yield f"http://127.0.0.1:{port}"
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


@pytest.fixture
def artifacts(tmp_path):
    # Multi-chunk source plus non-ASCII and CRLF exercise actual solc UnixFS CIDs.
    source = ('// SPDX-License-Identifier: MIT\r\npragma solidity ^0.8.19;\r\n'
              '/// @notice Caf\u00e9 verification.\r\ncontract Example { function value() external pure returns(uint) { return 7; } }\r\n'
              'interface IExample { function value() external view returns(uint); }\r\n/*' + "x" * 270000 + '*/\r\n')
    standard = {"language": "Solidity", "sources": {"Example.sol": {"content": source}}, "settings": {
        "evmVersion": "london", "optimizer": {"enabled": True, "runs": 200},
        "outputSelection": {"*": {"*": ["abi", "metadata", "evm.bytecode", "evm.deployedBytecode"]}}}}
    result = solcx.compile_standard(standard, solc_version="0.8.19")
    manifest = []
    for name, data in result["contracts"]["Example.sol"].items():
        metadata = json.loads(data["metadata"])
        settings = dict(metadata["settings"])
        settings.pop("compilationTarget")
        settings["outputSelection"] = standard["settings"]["outputSelection"]
        artifact = {"metadata": data["metadata"], "abi": data["abi"], "runtime_bytecode": "0x" + data["evm"]["deployedBytecode"]["object"] if data["evm"]["deployedBytecode"]["object"] else "",
                    "creation_bytecode": "0x" + data["evm"]["bytecode"]["object"] if data["evm"]["bytecode"]["object"] else "",
                    "standard_json_input": dict(standard, settings=settings), "fully_qualified_name": f"Example.sol:{name}",
                    "compiler_version": "0.8.19", "evm_version": "london"}
        folder = tmp_path / "output" / name
        compiler.save_results({name: artifact}, str(folder), quiet=True)
        manifest.append({"contract": name, "output": str(folder)})
    (tmp_path / "output/manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return tmp_path / "output", manifest


@pytest.mark.parametrize("endpoint", ["http://100.111.67.1:5001", "https://user:secret@example.com", "https://example.com?token=secret"])
def test_reject_unsafe_endpoint(endpoint):
    with pytest.raises(publishing.PublicationError):
        publishing.KuboClient(endpoint)


def test_configuration_requires_target_when_enabled(monkeypatch):
    assert publishing.configured_client() is None
    monkeypatch.setenv("IPFS_AUTO_PUBLISH", "true")
    with pytest.raises(publishing.PublicationError, match="requires IPFS_API_URL"):
        publishing.configured_client()
    assert publishing.configured_client(disabled=True) is None


def test_auto_publish_real_kubo_and_idempotent_retry(kubo, artifacts):
    folder, manifest = artifacts
    client = publishing.KuboClient(kubo)
    first = publishing.publish_manifest(folder, manifest, client)
    second = publishing.publish_manifest(folder, manifest, client)
    assert first == second
    assert first["status"] == "published"
    assert len(first["contracts"]) == 2
    # Two metadata objects, one shared multi-chunk source, and the release bundle.
    assert len(first["objects"]) == 4
    assert all(row["recursive_pin_verified"] and row["read_back_verified"] for row in first["objects"])
    assert not first["public_availability_verified"]


def test_portable_manifest_resolves_paths_from_release_root(kubo, artifacts):
    folder, manifest = artifacts
    for row in manifest:
        row['output'] = Path(row['output']).relative_to(folder).as_posix()
    receipt = publishing.publish_manifest(folder, manifest, publishing.KuboClient(kubo))
    assert receipt['status'] == 'published'
    assert all(row['recursive_pin_verified'] and row['read_back_verified'] for row in receipt['objects'])


def test_metadata_cid_mismatch_fails_before_pins(kubo, artifacts):
    folder, manifest = artifacts
    artifact_path = folder / "Example/Example_artifact.json"
    artifact = json.loads(artifact_path.read_bytes())
    # Keep exported metadata internally consistent, but change its exact bytes.
    artifact["metadata"] += "\n"
    artifact_path.write_text(json.dumps(artifact), encoding="utf-8")
    (folder / "Example/Example_metadata.json").write_bytes(artifact["metadata"].encode())
    with pytest.raises(publishing.PublicationError, match="CID mismatch"):
        publishing.publish_manifest(folder, manifest, publishing.KuboClient(kubo))
    receipt = json.loads((folder / "ipfs-publication.json").read_bytes())
    assert receipt["status"] == "failed" and receipt["objects"] == []


def test_read_back_failure_is_not_reported_as_success_and_retry_recovers(kubo, artifacts, monkeypatch):
    folder, manifest = artifacts
    client = publishing.KuboClient(kubo)
    original = client.confirm
    count = 0
    def fail_second(cid, content):
        nonlocal count
        count += 1
        if count == 2:
            raise publishing.PublicationError("Injected read-back failure")
        return original(cid, content)
    monkeypatch.setattr(client, "confirm", fail_second)
    with pytest.raises(publishing.PublicationError, match="read-back failure"):
        publishing.publish_manifest(folder, manifest, client)
    receipt = json.loads((folder / "ipfs-publication.json").read_bytes())
    assert receipt["status"] == "failed" and len(receipt["objects"]) == 1
    assert receipt["partial_pins_may_exist"]
    monkeypatch.setattr(client, "confirm", original)
    assert publishing.publish_manifest(folder, manifest, client)["status"] == "published"


def test_redirect_does_not_forward_request_or_credentials(tmp_path, monkeypatch):
    calls = []
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            calls.append(self.path)
            self.send_response(302)
            self.send_header("Location", "/must-not-follow")
            self.end_headers()
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        auth = tmp_path / "auth"
        auth.write_text("Bearer test-secret", encoding="utf-8")
        monkeypatch.setenv("IPFS_API_AUTH_FILE", str(auth))
        with pytest.raises(publishing.PublicationError, match="HTTP 302") as error:
            publishing.KuboClient(f"http://127.0.0.1:{server.server_port}").request("add")
        assert "test-secret" not in str(error.value)
        assert calls == ["/api/v0/add"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_cli_automatically_publishes_and_missing_target_clears_receipt(kubo, artifacts):
    folder, _ = artifacts
    environment = dict(os.environ, IPFS_AUTO_PUBLISH="true", IPFS_API_URL=kubo)
    command = [sys.executable, str(TOOL_DIR / "compile.py"), "--publish-only", "--output-dir", str(folder)]
    completed = subprocess.run(command, env=environment, capture_output=True, timeout=60)
    assert completed.returncode == 0, completed.stderr.decode(errors="replace")
    assert json.loads((folder / "ipfs-publication.json").read_bytes())["status"] == "published"
    environment.pop("IPFS_API_URL")
    failed = subprocess.run(command, env=environment, capture_output=True, timeout=15)
    assert failed.returncode != 0
    assert json.loads((folder / "ipfs-publication.json").read_bytes())["status"] == "failed_before_publication"


def test_normal_compile_cli_automatically_publishes(kubo, tmp_path):
    environment = dict(os.environ, IPFS_AUTO_PUBLISH="true", IPFS_API_URL=kubo)
    source = TOOL_DIR.parents[1] / "Contracts/Genesis/validatorContracts/ValidatorSmartContractAllowList.sol"
    command = [sys.executable, str(TOOL_DIR / "compile.py"), "--file", str(source), "--output-dir", str(tmp_path)]
    completed = subprocess.run(command, env=environment, capture_output=True, timeout=90)
    assert completed.returncode == 0, completed.stderr.decode(errors="replace")
    receipt = json.loads((tmp_path / "ipfs-publication.json").read_bytes())
    assert receipt["status"] == "published"
    validator = next(row for row in receipt["contracts"] if row["contract"].endswith(":ValidatorSmartContractAllowList"))
    assert validator["compiler"] == "0.8.19" and validator["evm"] == "london"


def test_complete_review_artifact_set(kubo):
    location = os.getenv("DAKOTA_FULL_ARTIFACTS")
    if not location:
        pytest.skip("Set DAKOTA_FULL_ARTIFACTS to validate the full local review build")
    folder = Path(location)
    manifest = json.loads((folder / "manifest.json").read_bytes())
    receipt = publishing.publish_manifest(folder, manifest, publishing.KuboClient(kubo))
    assert receipt["status"] == "published"
    assert len(receipt["contracts"]) == len({(row["output"], row["contract"]) for row in manifest})


def test_backend_config_preserves_identity_and_enforces_nebula_filters():
    existing = {"Identity": {"PeerID": "existing-id", "PrivKey": "existing-test-key"}}
    result = backend_config.settings(existing)
    assert backend_config.settings(result) == result
    assert result["Identity"] == existing["Identity"]
    assert "Addresses" not in existing
    networks = [ipaddress.ip_network(rule.split("/ipcidr/")[0].split("/", 2)[2] + "/" + rule.split("/ipcidr/")[1])
                for rule in result["Swarm"]["AddrFilters"]]
    for address, blocked in [("1.1.1.1", True), ("206.81.13.59", True), ("100.111.32.101", False),
                             ("127.0.0.1", False), ("2606:4700:4700::1111", True)]:
        ip = ipaddress.ip_address(address)
        assert any(ip in network for network in networks if ip.version == network.version) == blocked
    assert result["Routing"]["Type"] == "none" and not result["Provide"]["Enabled"]
    assert result["Gateway"]["NoFetch"]


@pytest.mark.parametrize("address", ["/ip4/1.1.1.1/tcp/4001", "/dns4/example.com/tcp/4001", "/ip4/100.111.32.101/tcp/70000"])
def test_backend_rejects_peer_outside_nebula_policy(address):
    with pytest.raises(ValueError):
        backend_config.settings({"Identity": {"PeerID": "existing-id", "PrivKey": "test-key"}},
                                peers=[{"ID": "peer-id", "Addrs": [address]}])
