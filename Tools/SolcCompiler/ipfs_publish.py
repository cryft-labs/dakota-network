"""Publish only this compiler invocation's artifacts to an authenticated Kubo API."""
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile


class PublicationError(RuntimeError):
    pass


def metadata_cid(runtime):
    """Decode Solidity's length-delimited CBOR trailer, never an opcode search."""
    if not runtime:
        return None
    try:
        import cbor2
    except ImportError:
        raise PublicationError("Install Tools/SolcCompiler/requirements.txt before publishing") from None
    try:
        bytecode = bytes.fromhex(runtime.removeprefix("0x"))
        size = int.from_bytes(bytecode[-2:], "big")
        if len(bytecode) < 3 or not 0 < size <= len(bytecode) - 2:
            raise ValueError()
        stream = io.BytesIO(bytecode[-size - 2:-2])
        decoded = cbor2.CBORDecoder(stream).decode()
        if stream.read() or not isinstance(decoded, dict):
            raise ValueError()
        multihash = decoded["ipfs"]
        if not isinstance(multihash, bytes) or len(multihash) != 34 or multihash[:2] != b"\x12\x20":
            raise ValueError()
    except Exception:
        raise PublicationError("Runtime has no valid Solidity IPFS metadata trailer") from None
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    number, encoded = int.from_bytes(multihash, "big"), ""
    while number:
        number, remainder = divmod(number, 58)
        encoded = alphabet[remainder] + encoded
    return encoded


def write_receipt(directory, receipt):
    target = Path(directory) / "ipfs-publication.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".tmp")
    temporary.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n")
    os.replace(temporary, target)


def configured_client(api_url=None, disabled=False):
    """Auto-publish when configured; explicit true requires a destination."""
    if disabled:
        return None
    mode = os.getenv("IPFS_AUTO_PUBLISH", "auto").lower().strip()
    if mode not in {"auto", "true", "false"}:
        raise PublicationError("IPFS_AUTO_PUBLISH must be auto, true or false")
    if mode == "false":
        return None
    endpoint = api_url if api_url is not None else os.getenv("IPFS_API_URL", "")
    if not endpoint.strip():
        if mode == "true":
            raise PublicationError("IPFS_AUTO_PUBLISH=true requires IPFS_API_URL")
        return None
    return KuboClient(endpoint.strip())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class KuboClient:
    def __init__(self, endpoint):
        parsed = urllib.parse.urlsplit(endpoint)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname
                or parsed.username or parsed.password or parsed.query or parsed.fragment):
            raise PublicationError("IPFS_API_URL must be an HTTP(S) base URL without credentials, query or fragment")
        try:
            loopback = ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            loopback = parsed.hostname == "localhost"
        if parsed.scheme == "http" and not loopback:
            raise PublicationError("Non-local IPFS APIs require verified HTTPS")
        self.endpoint = endpoint.rstrip("/")
        if self.endpoint.endswith("/api/v0"):
            self.endpoint = self.endpoint[:-7]
        try:
            self.timeout = float(os.getenv("IPFS_TIMEOUT_SECONDS", "60"))
            self.max_bytes = int(os.getenv("IPFS_MAX_FILE_BYTES", str(64 * 1024 * 1024)))
            if not 1 <= self.timeout <= 300 or not 1 <= self.max_bytes <= 256 * 1024 * 1024:
                raise ValueError()
        except ValueError:
            raise PublicationError("Invalid IPFS timeout or file-size limit") from None
        self.headers = {}
        auth_file = os.getenv("IPFS_API_AUTH_FILE", "")
        try:
            if auth_file:
                auth = Path(auth_file).read_text(encoding="utf-8").strip()
                if not re.fullmatch(r"(?:Bearer|Basic) [^\s]{1,8192}", auth):
                    raise PublicationError("IPFS_API_AUTH_FILE must contain one Basic or Bearer Authorization value")
                self.headers["Authorization"] = auth
            context = ssl.create_default_context(cafile=os.getenv("IPFS_TLS_CA_FILE") or None)
            cert, key = os.getenv("IPFS_TLS_CLIENT_CERT_FILE"), os.getenv("IPFS_TLS_CLIENT_KEY_FILE")
            if bool(cert) != bool(key):
                raise PublicationError("IPFS client certificate and key must be configured together")
            if cert:
                context.load_cert_chain(cert, key)
        except (OSError, ssl.SSLError):
            raise PublicationError("Cannot load IPFS authentication or TLS files") from None
        # Never forward source bytes or credentials through an inherited HTTP proxy.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))

    def request(self, operation, params=None, data=b"", content_type=None, response_limit=1024 * 1024):
        url = self.endpoint + "/api/v0/" + operation
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = dict(self.headers)
        if content_type:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(url, data=data, headers=headers, method="POST")
        for attempt in range(3):
            try:
                with self.opener.open(request, timeout=self.timeout) as response:
                    body = response.read(response_limit + 1)
                if len(body) > response_limit:
                    raise PublicationError("IPFS response exceeds the expected size")
                return body
            except urllib.error.HTTPError as error:
                status = error.code
                error.close()
                if attempt < 2 and (status == 429 or status >= 500):
                    time.sleep(0.5 * (attempt + 1))
                    continue
                raise PublicationError(f"IPFS {operation} failed (HTTP {status})") from None
            except (urllib.error.URLError, TimeoutError, OSError):
                if attempt < 2:
                    time.sleep(0.5 * (attempt + 1))
                    continue
                raise PublicationError(f"IPFS {operation} failed (connection or TLS error)") from None

    def add(self, content, only_hash=False):
        if len(content) > self.max_bytes:
            raise PublicationError("IPFS file exceeds IPFS_MAX_FILE_BYTES")
        boundary = "dakota-" + uuid.uuid4().hex
        body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="artifact"\r\n'
                'Content-Type: application/octet-stream\r\n\r\n').encode() + content + f"\r\n--{boundary}--\r\n".encode()
        response = self.request("add", {
            "cid-version": "0", "raw-leaves": "false", "chunker": "size-262144",
            "hash": "sha2-256", "trickle": "false", "wrap-with-directory": "false",
            "pin": "false" if only_hash else "true", "only-hash": str(only_hash).lower(),
            "progress": "false",
        }, body, f"multipart/form-data; boundary={boundary}")
        try:
            lines = response.decode("utf-8").splitlines()
            if len(lines) != 1:
                raise ValueError()
            cid = json.loads(lines[0])["Hash"]
            if not re.fullmatch(r"Qm[1-9A-HJ-NP-Za-km-z]{44}", cid):
                raise ValueError()
            return cid
        except (ValueError, KeyError, TypeError):
            raise PublicationError("IPFS add returned an invalid CID response") from None

    def confirm(self, cid, content):
        actual = self.request("cat", {"arg": cid}, response_limit=len(content))
        if actual != content:
            raise PublicationError("IPFS read-back bytes do not match the compiled artifact")
        try:
            pins = json.loads(self.request("pin/ls", {"arg": cid, "type": "recursive"}))
            if pins["Keys"][cid]["Type"] != "recursive":
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise PublicationError("IPFS recursive pin was not confirmed") from None


def publish_manifest(output_dir, manifest, client):
    """No directory crawl: only artifacts named by this successful invocation."""
    directory = Path(output_dir).resolve()
    if os.name == "nt":
        absolute = str(directory)
        if not absolute.startswith("\\\\?\\"):
            absolute = "\\\\?\\UNC\\" + absolute[2:] if absolute.startswith("\\\\") else "\\\\?\\" + absolute
        directory = Path(absolute)
    receipt = {"version": 1, "status": "preflight", "objects": [], "contracts": [],
               "release_bundle_cid": None, "public_availability_verified": False,
               "secondary_pin_status": "not_implemented", "deployment_approved": False}
    write_receipt(directory, receipt)
    objects, exports, seen = {}, {}, set()

    def add_object(content, expected, role):
        digest = hashlib.sha256(content).hexdigest()
        if len(content) > client.max_bytes:
            raise PublicationError("Artifact exceeds IPFS_MAX_FILE_BYTES")
        if digest in objects:
            item = objects[digest]
            if item["expected"] and expected and item["expected"] != expected:
                raise PublicationError("Conflicting IPFS references for identical bytes")
            item["expected"] = item["expected"] or expected
            item["roles"].add(role)
        else:
            objects[digest] = {"content": content, "expected": expected, "roles": {role}}
        return digest

    try:
        if not manifest or any(row.get("error") for row in manifest):
            raise PublicationError("A complete successful compilation manifest is required")
        for row in manifest:
            folder = Path(row["output"])
            folder = (folder if folder.is_absolute() else directory / folder).resolve()
            if os.name == "nt" and not str(folder).startswith("\\\\?\\"):
                absolute = str(folder)
                folder = Path("\\\\?\\UNC\\" + absolute[2:] if absolute.startswith("\\\\") else "\\\\?\\" + absolute)
            name = row["contract"]
            if not folder.is_relative_to(directory) or not re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", name):
                raise PublicationError("Invalid artifact path in compilation manifest")
            artifact_path = folder / f"{name}_artifact.json"
            if artifact_path in seen:
                continue
            seen.add(artifact_path)
            paths = {suffix: folder / f"{name}_{suffix}" for suffix in [
                "artifact.json", "metadata.json", "standard_input.json", "abi.json", "runtime.bin", "creation.bin"]}
            if any(not path.resolve().is_relative_to(directory) for path in paths.values()):
                raise PublicationError("Artifact symlink escapes output directory")
            blobs = {suffix: path.read_bytes() for suffix, path in paths.items()}
            artifact = json.loads(blobs.pop("artifact.json"))
            metadata_bytes = artifact["metadata"].encode("utf-8")
            if blobs["metadata.json"] != metadata_bytes:
                raise PublicationError("Metadata export differs from compiler metadata bytes")
            standard = json.loads(blobs["standard_input.json"])
            if (standard != artifact["standard_json_input"] or
                    hashlib.sha256(blobs["standard_input.json"]).hexdigest() != artifact["standard_input_sha256"]):
                raise PublicationError("Standard JSON export does not match its artifact")
            for kind in ["runtime", "creation"]:
                if blobs[kind + ".bin"].decode("utf-8") != artifact[kind + "_bytecode"]:
                    raise PublicationError("Bytecode export differs from compiler artifact")
            if json.loads(blobs["abi.json"]) != artifact["abi"]:
                raise PublicationError("ABI export differs from compiler artifact")
            metadata = json.loads(metadata_bytes)
            if set(metadata["sources"]) != set(standard["sources"]):
                raise PublicationError("Metadata and standard JSON source inventories differ")
            target = artifact["fully_qualified_name"]
            source_name, target_name = target.rsplit(":", 1)
            if metadata["settings"]["compilationTarget"] != {source_name: target_name}:
                raise PublicationError("Metadata compilation target mismatch")
            entry = {"contract": target, "compiler": artifact["compiler_version"], "evm": artifact["evm_version"],
                     "standard_input_sha256": artifact["standard_input_sha256"], "sources": {}}
            entry["metadata_object"] = add_object(metadata_bytes, metadata_cid(artifact["runtime_bytecode"]), "metadata")
            for source, info in sorted(metadata["sources"].items()):
                content = standard["sources"][source]["content"].encode("utf-8")
                cids = [url[len("dweb:/ipfs/"):] for url in info.get("urls", []) if url.startswith("dweb:/ipfs/")]
                if len(cids) != 1:
                    if info.get("content") != standard["sources"][source]["content"]:
                        raise PublicationError("Source lacks one IPFS reference or matching literal content")
                    expected = None
                else:
                    expected = cids[0]
                entry["sources"][source] = add_object(content, expected, "source")
            receipt["contracts"].append(entry)
            for suffix, content in blobs.items():
                exports["artifacts/" + paths[suffix].relative_to(directory).as_posix()] = content

        # Hash the entire set before pinning anything. The trusted API receives
        # the bytes for only-hash, but no public availability is implied.
        for digest, item in objects.items():
            cid = client.add(item["content"], only_hash=True)
            if item["expected"] and cid != item["expected"]:
                raise PublicationError(f"IPFS CID mismatch for {sorted(item['roles'])} object {digest}")
            item["cid"] = cid
        for entry in receipt["contracts"]:
            entry["metadata_cid"] = objects[entry.pop("metadata_object")]["cid"]
            entry["sources"] = {name: objects[digest]["cid"] for name, digest in entry["sources"].items()}
        bundle_index = {"version": 1, "contracts": receipt["contracts"], "deployment_approved": False}
        exports["release-index.json"] = (json.dumps(bundle_index, sort_keys=True, indent=2) + "\n").encode("utf-8")
        for item in objects.values():
            exports["objects/" + item["cid"]] = item["content"]
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in sorted(exports.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, content)
        bundle = buffer.getvalue()
        bundle_cid = client.add(bundle, only_hash=True)
        (directory / "ipfs-release-bundle.zip").write_bytes(bundle)
        receipt["status"] = "publishing"
        write_receipt(directory, receipt)
        items = list(objects.items()) + [(hashlib.sha256(bundle).hexdigest(),
                {"content": bundle, "cid": bundle_cid, "roles": {"release_bundle"}})]
        for digest, item in items:
            cid = client.add(item["content"])
            if cid != item["cid"]:
                raise PublicationError("IPFS publication returned a CID different from preflight")
            client.confirm(cid, item["content"])
            receipt["objects"].append({"cid": cid, "sha256": digest, "bytes": len(item["content"]),
                "roles": sorted(item["roles"]), "recursive_pin_verified": True, "read_back_verified": True})
            write_receipt(directory, receipt)
        receipt["release_bundle_cid"] = bundle_cid
        receipt["status"] = "published"
        write_receipt(directory, receipt)
        return receipt
    except Exception as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error) if isinstance(error, PublicationError) else f"Artifact preparation or publication failed ({type(error).__name__})"
        receipt["partial_pins_may_exist"] = True
        write_receipt(directory, receipt)
        raise PublicationError(receipt["error"]) from None
