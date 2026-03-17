"""Generate case-sensitive redeemable PIN/code pairs for PrivateComboStorage.

The on-chain contract expects:
    codeHash = keccak256(bytes(pin + code))

Each run writes the generated results into this tool directory's results/
subdirectory and also prints them to stdout in the requested format.

PINs and codes are drawn from OS-backed cryptographic entropy via
``secrets.SystemRandom``.
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
    pin: str
    code: str
    concatenated: str
    code_hash: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate case-sensitive redeemable PIN/code pairs and the "
            "keccak256 hash of pin+code for PrivateComboStorage."
        )
    )
    parser.add_argument(
        "--pin-length",
        type=int,
        required=True,
        help="Length of the generated PIN.",
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
            "Characters allowed in generated PINs. Defaults to mixed-case "
            "letters and digits."
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
        "--format",
        choices=("text", "json", "csv"),
        default="text",
        help="Output format (default: text).",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.pin_length <= 0:
        raise ValueError("--pin-length must be greater than zero")
    if args.code_length <= 0:
        raise ValueError("--code-length must be greater than zero")
    if args.count <= 0:
        raise ValueError("--count must be greater than zero")
    if not args.pin_alphabet:
        raise ValueError("--pin-alphabet must not be empty")
    if not args.code_alphabet:
        raise ValueError("--code-alphabet must not be empty")


def generate_token(length: int, alphabet: str) -> str:
    alphabet_length = len(alphabet)
    return "".join(alphabet[SYSTEM_RANDOM.randrange(alphabet_length)] for _ in range(length))


def build_code(
    pin_length: int,
    code_length: int,
    pin_alphabet: str,
    code_alphabet: str,
) -> RedeemableCode:
    pin = generate_token(pin_length, pin_alphabet)
    code = generate_token(code_length, code_alphabet)
    concatenated = f"{pin}{code}"
    code_hash = f"0x{keccak(concatenated.encode('utf-8')).hex()}"
    return RedeemableCode(
        pin=pin,
        code=code,
        concatenated=concatenated,
        code_hash=code_hash,
    )


def generate_codes(args: argparse.Namespace) -> list[RedeemableCode]:
    return [
        build_code(
            args.pin_length,
            args.code_length,
            args.pin_alphabet,
            args.code_alphabet,
        )
        for _ in range(args.count)
    ]


def render_text(records: list[RedeemableCode]) -> str:
    lines: list[str] = []
    for index, record in enumerate(records, start=1):
        lines.append(f"[{index}]")
        lines.append(f"pin:          {record.pin}")
        lines.append(f"code:         {record.code}")
        lines.append(f"concatenated: {record.concatenated}")
        lines.append(f"code_hash:    {record.code_hash}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_json(records: list[RedeemableCode]) -> str:
    return json.dumps([asdict(record) for record in records], indent=2) + "\n"


def render_csv(records: list[RedeemableCode]) -> str:
    buffer = io.StringIO()
    writer = csv.DictWriter(
        buffer,
        fieldnames=["pin", "code", "concatenated", "code_hash"],
        lineterminator="\n",
    )
    writer.writeheader()
    for record in records:
        writer.writerow(asdict(record))
    return buffer.getvalue()


def render_output(records: list[RedeemableCode], output_format: str) -> str:
    if output_format == "json":
        return render_json(records)
    if output_format == "csv":
        return render_csv(records)
    return render_text(records)


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
        records = generate_codes(args)
        output_text = render_output(records, args.format)
        output_path = write_results(output_text, args.format)
        sys.stdout.write(output_text)
        print(f"Saved results to: {output_path}", file=sys.stderr)
        return 0
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())