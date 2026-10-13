# SPDX-License-Identifier: GPL-2.0-or-later

import datetime
import os


def default_report_name(scene):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"mesh-inspection-{stamp}.txt"


def build_report(scene):
    result = scene.msi_result
    lines = [
        "Mesh Inspector Report",
        "=" * 60,
        f"Scene     : {scene.name}",
        f"Generated : {datetime.datetime.now().isoformat(timespec='seconds')}",
        f"Objects   : {result.checked_objects}",
        "",
    ]

    if not result.findings:
        return "\n".join(lines + ["No problems found."]) + "\n"

    lines += ["-" * 60, "Summary", "-" * 60]
    for summary in sorted(result.object_summaries, key=lambda item: -item.issue_total):
        lines.append(
            f"{summary.object_name:<32} faces={summary.face_count:<8} "
            f"verts={summary.vert_count:<8} issues={summary.issue_total}"
        )

    lines += ["", "-" * 60, "Details", "-" * 60]
    for name in dict.fromkeys(finding.object_name for finding in result.findings):
        lines.append(f"[{name}]")
        for finding in result.findings:
            if finding.object_name == name:
                lines.append(
                    f"  {finding.severity:<7} {finding.check:<20} "
                    f"count={finding.count:<6} {finding.detail}"
                )
        lines.append("")

    return "\n".join(lines) + "\n"


def write_report(filepath, text, *, use_timestamp_dir=False):
    filepath = os.path.abspath(filepath)
    directory = os.path.dirname(filepath)

    if use_timestamp_dir:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        directory = os.path.join(directory, stamp)
        filepath = os.path.join(directory, os.path.basename(filepath))

    os.makedirs(directory, exist_ok=True)
    with open(filepath, "w", encoding="utf-8", newline="\n") as report_file:
        report_file.write(text)
    return filepath
