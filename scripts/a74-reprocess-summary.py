#!/usr/bin/env python3
"""Reprocess an existing A7.4 compact ZIP; no GPU, FFmpeg, or repeated edits.

Only aggregates recorded per-trial JSONs. Original evidence is preserved.
"""
from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from a74_batch_report import summarize

MAX_FILES = 300
MAX_UNCOMPRESSED_BYTES = 96 * 1024 * 1024
ALLOWED_NAMES = {
    "a74_batch_manifest.json",
    "a74_batch_report.json",
    "a74_batch_trials.csv",
    "a74_capture_manifest.json",
    "a74_events.jsonl",
    "a74_pilot_review.json",
    "a74_reference.json",
    "a74_ready.json",
    "a74_result.json",
}


def reprocess(source: Path, output: Path) -> dict:
    source = source.resolve()
    output = output.resolve()
    if not source.is_file() or source == output:
        raise ValueError("Source ZIP missing or output overlaps original")
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite existing report: {output}")
    with tempfile.TemporaryDirectory(prefix="a74-reprocess-") as tmp:
        root = Path(tmp).resolve()
        with zipfile.ZipFile(source) as archive:
            infos = archive.infolist()
            if len(infos) > MAX_FILES:
                raise ValueError("Unusually many files in evidence archive")
            if sum(i.file_size for i in infos) > MAX_UNCOMPRESSED_BYTES:
                raise ValueError("Unexpected decompressed evidence size")
            for info in infos:
                normalized = info.filename.replace("\\", "/")
                if info.is_dir() or normalized.endswith("/"):
                    continue
                rel = PurePosixPath(normalized)
                if (normalized.startswith("/") or ":" in normalized or
                        any(x in (".", "..") for x in rel.parts) or
                        rel.name not in ALLOWED_NAMES):
                    raise ValueError(f"Unsafe/unexpected evidence path: {normalized}")
                target = root.joinpath(*rel.parts)
                if not target.resolve().is_relative_to(root):
                    raise ValueError("Archive entry escapes isolated directory")
                if target.exists():
                    raise ValueError(f"Duplicate evidence path: {normalized}")
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info, "r") as src, target.open("wb") as dest:
                    shutil.copyfileobj(src, dest)
        prior = root/"a74_batch_report.json"
        if prior.is_file():
            prior.rename(root/"a74_batch_report_original.json")
        report = summarize(root)
        if not report["collection_complete"]:
            raise ValueError(
                f"Cannot reprocess without provenance-complete trials: "
                f"invalid={report['invalid_runs']} requested={report['requested_runs']}"
            )
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for item in sorted(root.rglob("*")):
                if item.is_file():
                    archive.write(item, arcname=item.relative_to(root).as_posix())
    return report


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("summary_zip", type=Path)
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    output = args.output or args.summary_zip.with_name(
        args.summary_zip.stem + "-reprocessed.zip"
    )
    report = reprocess(args.summary_zip, output)
    print("A74_REPROCESS_OK " + json.dumps({
        "output": str(output), "requested": report["requested_runs"],
        "valid": report["valid_diagnostic_runs"],
        "timing_ambiguous": report["video_timing_ambiguous_runs"],
        "strict_gate": report["edit_100_gate"],
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
