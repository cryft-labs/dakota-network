"""Generate redeemable codes for the current PrivateComboStorage flow.

The on-chain contract now expects:
    codeHash = keccak256(bytes(code))

PINs are no longer generated off-chain. Instead, storeDataBatch receives one
entropy seed plus one PIN policy per entry, and the contract assigns PINs during
storage. This tool therefore generates:
    - cleartext redeemable codes
    - keccak256(code) hashes
    - one entropy value per entry for storeDataBatch
    - one PIN configuration per entry

Each run writes the generated results into this tool directory's results/
subdirectory and also prints them to stdout in the requested format.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import secrets
import string
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from eth_hash.auto import keccak


DEFAULT_ALPHABET = string.ascii_letters + string.digits
TOOL_DIR = Path(__file__).resolve().parent
RESULTS_DIR = TOOL_DIR / "results"
SYSTEM_RANDOM = secrets.SystemRandom()
FILE_EXTENSIONS = {
    "text": "txt",
    "json": "json",
    "csv": "csv",
}


@dataclass(frozen=True)
class RedeemableCode:
    entropy: str
    pin_length: int
    use_special_chars: bool
    code: str
    code_hash: str


@dataclass(frozen=True)
class GenerationBatch:
    count: int
    records: list[RedeemableCode]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate redeemable codes, keccak256(code) hashes, and per-entry "
            "storage parameters for PrivateComboStorage with contract-assigned PINs."
        )
    )
    parser.add_argument(
        "--pin-length",
        type=int,
        required=True,
        nargs="+",
        help="One or more PIN lengths to cycle through per generated entry.",
    )
    parser.add_argument(
        "--code-length",
        type=int,
        required=True,
        help="Length of the generated redeemable code.",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="How many PIN/code pairs to generate (default: 1).",
    )
    parser.add_argument(
        "--pin-alphabet",
        default=DEFAULT_ALPHABET,
        help=(
            "Deprecated compatibility flag. PINs are assigned on-chain, so "
            "this value is ignored."
        ),
    )
    parser.add_argument(
        "--code-alphabet",
        default=DEFAULT_ALPHABET,
        help=(
            "Characters allowed in generated redeemable codes. Defaults to "
            "mixed-case letters and digits."
        ),
    )
    parser.add_argument(
        "--use-special-chars",
        choices=("true", "false"),
        nargs="+",
        default=["false"],
        help="One or more special-character flags to cycle through per generated entry.",
    )
    parser.add_argument(
        "--entropy",
        help=(
            "Optional comma-separated list of 32-byte hex entropy values to pass "
            "to storeDataBatch. If omitted, cryptographically random values are generated."
        ),
    )
    parser.add_argument(
        "--format",
        choices=("text", "json", "csv"),
        default="text",
        help="Output format (default: text).",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    for pin_length in args.pin_length:
        if pin_length <= 0:
            raise ValueError("each --pin-length must be greater than zero")
        if pin_length > 8:
            raise ValueError("each --pin-length must be less than or equal to 8")
    if args.code_length <= 0:
        raise ValueError("--code-length must be greater than zero")
    if args.count <= 0:
        raise ValueError("--count must be greater than zero")
    if not args.code_alphabet:
        raise ValueError("--code-alphabet must not be empty")
    if args.entropy is not None:
        entropy_values = [item.strip() for item in args.entropy.split(",") if item.strip()]
        if len(entropy_values) != args.count:
            raise ValueError("--entropy must provide exactly one 32-byte hex value per record")
        for entropy_value in entropy_values:
            normalized = entropy_value.lower()
            if normalized.startswith("0x"):
                normalized = normalized[2:]
            if len(normalized) != 64:
                raise ValueError("each --entropy value must be exactly 32 bytes (64 hex chars)")
            try:
                int(normalized, 16)
            except ValueError as error:
                raise ValueError("each --entropy value must be valid hex") from error


def generate_token(length: int, alphabet: str) -> str:
    alphabet_length = len(alphabet)
    return "".join(alphabet[SYSTEM_RANDOM.randrange(alphabet_length)] for _ in range(length))


def normalize_entropy_values(entropy: str | None, count: int) -> list[str]:
    if entropy is None:
        return [f"0x{secrets.token_bytes(32).hex()}" for _ in range(count)]

    normalized_values: list[str] = []
    for entropy_value in entropy.split(","):
        trimmed = entropy_value.strip().lower()
        if trimmed.startswith("0x"):
            trimmed = trimmed[2:]
        normalized_values.append(f"0x{trimmed}")
    return normalized_values


def build_code(
    code_length: int,
    code_alphabet: str,
    entropy: str,
    pin_length: int,
    use_special_chars: bool,
) -> RedeemableCode:
    code = generate_token(code_length, code_alphabet)
    code_hash = f"0x{keccak(code.encode('utf-8')).hex()}"
    return RedeemableCode(
        entropy=entropy,
        pin_length=pin_length,
        use_special_chars=use_special_chars,
        code=code,
        code_hash=code_hash,
    )


def generate_codes(args: argparse.Namespace) -> GenerationBatch:
    records: list[RedeemableCode] = []
    seen_hashes: set[str] = set()
    entropy_values = normalize_entropy_values(args.entropy, args.count)
    pin_lengths = args.pin_length
    special_flags = [value == "true" for value in args.use_special_chars]
    entropy_index = 0

    while len(records) < args.count:
        record = build_code(
            args.code_length,
            args.code_alphabet,
            entropy_values[entropy_index],
            pin_lengths[entropy_index % len(pin_lengths)],
            special_flags[entropy_index % len(special_flags)],
        )
        if record.code_hash in seen_hashes:
            continue
        seen_hashes.add(record.code_hash)
        records.append(record)
        entropy_index += 1

    return GenerationBatch(
        count=args.count,
        records=records,
    )


def render_text(batch: GenerationBatch) -> str:
    lines: list[str] = []
    lines.append(f"count:              {batch.count}")
    lines.append("")
    lines.append("entropies: [")
    for record in batch.records:
        lines.append(f'  "{record.entropy}",')
    lines.append("]")
    lines.append("")
    lines.append("pin_lengths: [")
    for record in batch.records:
        lines.append(f"  {record.pin_length},")
    lines.append("]")
    lines.append("")
    lines.append("use_special_chars: [")
    for record in batch.records:
        lines.append(f"  {str(record.use_special_chars).lower()},")
    lines.append("]")
    lines.append("")
    lines.append("code_hashes: [")
    for record in batch.records:
        lines.append(f'  "{record.code_hash}",')
    lines.append("]")
    lines.append("")
    for index, record in enumerate(batch.records, start=1):
        lines.append(f"[{index}]")
        lines.append(f"entropy:   {record.entropy}")
        lines.append(f"pin_len:   {record.pin_length}")
        lines.append(f"specials:  {str(record.use_special_chars).lower()}")
        lines.append(f"code:      {record.code}")
        lines.append(f"code_hash: {record.code_hash}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_json(batch: GenerationBatch) -> str:
    payload = {
        "count": batch.count,
        "entropies": [record.entropy for record in batch.records],
        "pin_lengths": [record.pin_length for record in batch.records],
        "use_special_chars": [record.use_special_chars for record in batch.records],
        "code_hashes": [record.code_hash for record in batch.records],
        "records": [asdict(record) for record in batch.records],
    }
    return json.dumps(payload, indent=2) + "\n"


def render_csv(batch: GenerationBatch) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(
        buffer,
        fieldnames=[
            "pin_length",
            "use_special_chars",
            "entropy",
            "code",
            "code_hash",
        ],
        lineterminator="\n",
    )
    writer.writeheader()
    for record in batch.records:
        writer.writerow(
            {
                **asdict(record),
                "use_special_chars": str(record.use_special_chars).lower(),
            }
        )
    return buffer.getvalue()


def render_output(batch: GenerationBatch, output_format: str) -> str:
    if output_format == "json":
        return render_json(batch)
    if output_format == "csv":
        return render_csv(batch)
    return render_text(batch)


def build_output_path(output_format: str) -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    extension = FILE_EXTENSIONS[output_format]
    return RESULTS_DIR / f"redeemable_codes_{timestamp}.{extension}"


def write_results(output_text: str, output_format: str) -> Path:
    output_path = build_output_path(output_format)
    output_path.write_text(output_text, encoding="utf-8", newline="\n")
    return output_path


def main() -> int:
    try:
        args = parse_args()
        validate_args(args)
        batch = generate_codes(args)
        output_text = render_output(batch, args.format)
        output_path = write_results(output_text, args.format)
        sys.stdout.write(output_text)
        print(f"Saved results to: {output_path}", file=sys.stderr)
        return 0
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())