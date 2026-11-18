"""MatchedConsecutiveLines, as SolidLSP's ls.py builds it: some lines of a file around one line."""
from dataclasses import dataclass, field


@dataclass
class MatchedConsecutiveLines:
    lines: list = field(default_factory=list)          # (line number, text), 0-based
    source_file_path: str | None = None

    @classmethod
    def from_file_contents(cls, file_contents, line, context_lines_before=0, context_lines_after=0, source_file_path=None):
        all_lines = file_contents.split("\n")
        start = max(0, line - context_lines_before)
        end = min(len(all_lines) - 1, line + context_lines_after)
        return cls([(n, all_lines[n]) for n in range(start, end + 1)], source_file_path)

    def to_display_string(self, include_line_numbers=True):
        return "\n".join(f"{n:>4}:{t}" if include_line_numbers else t for n, t in self.lines)
