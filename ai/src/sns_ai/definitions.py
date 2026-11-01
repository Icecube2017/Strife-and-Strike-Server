"""Append-only vocabularies; no content hash and no JSON-position indices."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

GROUPS = ("characters", "templates", "races", "traits", "cards", "skills", "statuses", "marks", "variables", "tags", "options")
ID_SCALE = 65535


class DefinitionRegistry:
    def __init__(self, document: dict):
        if document.get("registrySchema") != 1:
            raise ValueError("Unsupported definition registry")
        self.document = json.loads(json.dumps(document))
        self.indices = {}
        for group in GROUPS:
            values = self.document["groups"][group]
            if not values or values[0] is not None or len(values) > ID_SCALE:
                raise ValueError(f"Invalid registry group {group}")
            if len(set(values)) != len(values):
                raise ValueError(f"Duplicate registry IDs in {group}")
            self.indices[group] = {key: i for i, key in enumerate(values) if key is not None}

    @classmethod
    def from_content(cls, content: dict, previous: DefinitionRegistry | None = None):
        ids = {group: set() for group in GROUPS}
        for group in GROUPS[:9]:
            for row in content.get(group, []):
                key = row["id"]
                if group == "variables":
                    key = f"{row.get('namespace', '')}:{key}"
                ids[group].add(key)

        def walk(value):
            if isinstance(value, dict):
                ids["tags"].update(x for x in value.get("tags", []) if isinstance(x, str))
                if value.get("op") == "selectOption":
                    ids["options"].update(x["id"] for x in value.get("options", []) if "id" in x)
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)
        walk(content)
        groups = {}
        for group in GROUPS:
            existing = list(previous.document["groups"][group]) if previous else [None]
            groups[group] = existing + sorted(ids[group] - set(existing))
        return cls({"registrySchema": 1, "revision": (previous.document["revision"] + 1) if previous else 1,
                    "idScale": ID_SCALE, "groups": groups})

    def token(self, group: str, key) -> float:
        return self.indices[group].get(key, 0) / ID_SCALE

    def known(self, group: str, key) -> bool:
        return key in self.indices[group]

    def save(self, path: str | Path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path):
        return cls(json.loads(Path(path).read_text(encoding="utf-8")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--content", type=Path, default=Path("content/content_items.json"))
    parser.add_argument("--out", type=Path, default=Path("ai/configs/definitions.json"))
    parser.add_argument("--extend", type=Path)
    args = parser.parse_args()
    previous = DefinitionRegistry.load(args.extend) if args.extend else None
    DefinitionRegistry.from_content(json.loads(args.content.read_text(encoding="utf-8")), previous).save(args.out)


if __name__ == "__main__":
    main()
