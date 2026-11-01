"""Numeric schema v3 with expanded card entities and ordered references. Only player-visible frames and static public definitions."""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass

import numpy as np
from gymnasium import spaces

from .definitions import DefinitionRegistry

ACTION_KINDS = ("pagePrevious", "pageNext", "yield", "attack", "playCards", "useSkill", "activateTrait", "activateStatus", "confirmAbility", "cancelAbility", "choose", "beginResponse", "respondCard", "pass", "recordAction", "discard", "endTurn")
PHASES = ("created", "opening", "start", "draw", "action", "discard", "end", "finished", "choice", "preparation", "response", "opportunity")


class EncodingOverflow(ValueError):
    pass


@dataclass(frozen=True)
class EncoderConfig:
    players: int = 8
    statuses: int = 32
    marks: int = 16
    hand: int = 256
    skills: int = 16
    variables: int = 128
    records: int = 8
    candidate_capacity: int = 64

    def __post_init__(self):
        if self.candidate_capacity < 4 or any(value < 1 for value in asdict(self).values()):
            raise ValueError("Invalid encoder capacities")
        if self.players > 8 or self.hand > 256 or self.skills > 16 or self.records > 8:
            raise ValueError("Entity capacities exceed numeric schema v3; upgrade the schema first")


class ObservationEncoder:
    schema = 3
    # Fixed divisors never change when a vocabulary gains entries.
    scales = {"hp": 4000, "mp": 32, "stat": 1000, "count": 64, "round": 64, "id": 65535}

    def __init__(self, registry: DefinitionRegistry, content: dict, config: EncoderConfig | None = None):
        self.registry, self.config = registry, config or EncoderConfig()
        self.metadata = {group: {row["id"]: row for row in content.get(group, [])}
                         for group in ("cards", "skills", "statuses", "characters")}
        c = self.config
        self.shapes = {"global": (32,), "players": (c.players, 24),
                       "statuses": (c.players, c.statuses, 16), "marks": (c.players, c.marks, 8),
                       "hand": (c.hand, 32), "skills": (c.skills, 20),
                       "public_skills": (c.players, c.skills, 8), "pending_cards": (c.hand, 8),
                       "revealed_history": (c.players, c.hand, 3),
                       "variables": (c.variables, 14), "records": (c.records, 4 + c.hand),
                       "candidates": (c.candidate_capacity, 64 + c.hand), "action_mask": (c.candidate_capacity,)}
        self.space = spaces.Dict({key: spaces.Box(-1.0, 1.0, shape, dtype=np.float32)
                                  for key, shape in self.shapes.items()})

    @staticmethod
    def number(value, scale=1):
        if not isinstance(value, (int, float, bool)) or not math.isfinite(value):
            return 0.0
        normalized = value / scale
        return -1.0 if normalized < -1 else 1.0 if normalized > 1 else float(normalized)

    @staticmethod
    def card_position(index):
        # Keep all v2 values (positions 1..16) identical for weight migration.
        # Later positions remain distinct and bounded, without touching tail fields.
        position = index + 1
        return position / 17 if position <= 16 else position / (position + 1)

    @staticmethod
    def bounded(values, maximum, name):
        if len(values) > maximum:
            raise EncodingOverflow(f"{name}: {len(values)} > {maximum}; no entities were silently dropped")
        return values

    def encode(self, frame: dict, *, offset: int = 0, terminal: bool = False):
        c, reg = self.config, self.registry
        decision = frame.get("decision") or {}
        observed = frame.get("learnerObservation") or decision.get("observation")
        if not isinstance(observed, dict):
            raise ValueError("Missing learner-visible observation")
        public, private = observed["public"], observed["private"]
        learner = private["playerId"]
        players = self.bounded(public["players"], c.players, "players")
        pivot = next(i for i, p in enumerate(players) if p["playerId"] == learner)
        players = players[pivot:] + players[:pivot]
        slots = {p["characterId"]: i for i, p in enumerate(players)}
        slots.update({p["playerId"]: i for i, p in enumerate(players)})
        rel = lambda key: (slots[key] + 1) / (c.players + 1) if key in slots else 0.0
        out = {key: np.zeros(shape, dtype=np.float32) for key, shape in self.shapes.items()}
        g = out["global"]
        phase = decision.get("phase", public.get("phase"))
        if phase in PHASES:
            g[PHASES.index(phase)] = 1
        g[12:24] = [self.number(public.get("round"), 64), self.number(public.get("turn"), 64),
                    rel(public.get("activePlayerId")), bool(public.get("extraTurn")), bool(public.get("duel")),
                    self.number(public.get("drawPileCount"), 256), self.number(public.get("discardCount"), 32),
                    self.number((public.get("responseWindow") or {}).get("depth"), 16),
                    self.number(public.get("turnDirection", 1)), self.number(public.get("nextRoundDirection", 1)),
                    self.number(decision.get("candidateCount"), 100000), self.number(offset, 100000)]
        g[24] = frame.get("terminated", False)
        g[25] = frame.get("truncated", False) or (terminal and not frame.get("terminated"))
        g[26] = self.number(private.get("mpFloor"), 32)
        g[27] = bool((private.get("preparation") or {}).get("canConfirm"))
        g[28] = bool((private.get("responseWindow") or {}).get("canSubmit"))
        unknown = 0
        for i, p in enumerate(players):
            definition = p.get("definitionId")
            meta = self.metadata["characters"].get(definition, {})
            out["players"][i] = [1, reg.token("characters", definition), reg.known("characters", definition),
                p["teamId"] == players[0]["teamId"], i == 0, bool(p.get("alive")),
                p.get("resourcePolicy") == "healthActions", p.get("resourcePolicy") == "defenseLife",
                self.number(p.get("hp"), 4000), self.number(p.get("maxHp"), 4000),
                self.number(p.get("mp"), 32), self.number(p.get("maxMp"), 32), self.number(p.get("shield"), 4000),
                self.number(p.get("attack"), 1000), self.number(p.get("defense"), 1000),
                self.number(p.get("actionsRemaining"), 16), self.number(p.get("handCount"), 32),
                self.number(p.get("hiddenSkillCount"), 16),
                self.number(sum(x.get("amount", 0) for x in p.get("temporaryDefense", [])), 1000),
                reg.token("races", meta.get("raceId")), reg.token("templates", meta.get("templateId")),
                p.get("playerId") == public.get("activePlayerId"), bool(p.get("lastRevealedHand") is not None),
                self.number(len(p.get("skills", [])), 16)]
            for j, status in enumerate(self.bounded(p.get("statuses", []), c.statuses, "statuses")):
                did = status.get("definitionId")
                static = self.metadata["statuses"].get(did, {})
                temporary = status.get("isStatusEffect", static.get("isStatusEffect", True)) is False
                anomaly = status.get("category", static.get("category")) == "anomaly"
                negative = not temporary and not anomaly and bool(static.get("negative"))
                positive = bool(static) and not temporary and not anomaly and not negative and not static.get("neutral", False)
                out["statuses"][i, j] = [1, reg.token("statuses", did), reg.known("statuses", did),
                    positive, negative, anomaly and not temporary, temporary,
                    self.number(status.get("stacks"), 32), self.number(status.get("intensity"), 32),
                    rel(status.get("sourceId")), rel(status.get("anchorPlayerId")),
                    status.get("decayPhase") == "turnStart", status.get("decayPhase") == "turnEnd",
                    status.get("decayPhase") == "afterMpRecovery", self.number(status.get("damageLimit"), 4000),
                    self.number(status.get("damageTaken"), 4000)]
            for j, mark in enumerate(self.bounded(private.get("marks", []) if i == 0 else p.get("marks", []), c.marks, "marks")):
                did = mark.get("definitionId", mark.get("markId"))
                out["marks"][i, j] = [1, reg.token("marks", did), reg.known("marks", did),
                    self.number(mark.get("count"), 64), rel(mark.get("sourceId")),
                    bool(mark.get("sourceId")), 0, 0]
            for j, skill in enumerate(self.bounded(p.get("skills", []), c.skills, "public skills")):
                did = skill.get("definitionId")
                out["public_skills"][i, j] = [1, reg.token("skills", did), reg.known("skills", did),
                    self.number(skill.get("cooldown"), 64), bool(skill.get("passive")), bool(skill.get("borrowed")),
                    bool(skill.get("leasedOut")), self.number(skill.get("remainingUses"), 64)]
            for j, card in enumerate(self.bounded(p.get("lastRevealedHand") or [], c.hand, "last revealed hand")):
                did = card.get("definitionId") if isinstance(card, dict) else card
                out["revealed_history"][i, j] = [1, reg.token("cards", did), reg.known("cards", did)]

        hand = self.bounded(private.get("cards", []), c.hand, "hand")
        hand_slots = {card["instanceId"]: i for i, card in enumerate(hand)}
        for i, card in enumerate(hand):
            did = card.get("definitionId")
            meta = self.metadata["cards"].get(did, {})
            row = out["hand"][i]
            base_cost = meta.get("mpCost", next((x["amount"] for x in meta.get("costs", []) if x.get("resource") == "mp"), 1))
            if not meta:
                base_cost = None
            row[:15] = [1, reg.token("cards", did), reg.known("cards", did), card.get("disabled", False),
                card.get("reinforced", False), self.number(base_cost, 32), self.number(meta.get("attackBonus"), 1000),
                self.number(meta.get("defenseBonus"), 1000), self.number(meta.get("diceBonus"), 32),
                self.number(meta.get("diceSides"), 32), meta.get("attacks", True) if meta else False, bool(meta.get("isLimited")),
                self.number(len(meta.get("tags", [])), 16), bool(card.get("attackCompanion")), bool(card.get("requiresTarget"))]
            for tag in meta.get("tags", []):
                token = reg.indices["tags"].get(tag, 0)
                if token >= 17:
                    raise EncodingOverflow("More than 16 registered tag slots; upgrade numeric schema")
                if token:
                    row[15 + token - 1] = 1
            row[31] = isinstance(base_cost, (int, float))

        carried = self.bounded((public.get("pending") or {}).get("cards", []), c.hand, "carried cards")
        carried_slots = {card["instanceId"]: i for i, card in enumerate(carried)}
        for i, card in enumerate(carried):
            did = card.get("definitionId")
            meta = self.metadata["cards"].get(did, {})
            out["pending_cards"][i] = [1, reg.token("cards", did), reg.known("cards", did),
                self.number(meta.get("attackBonus"), 1000), self.number(meta.get("defenseBonus"), 1000),
                self.number(meta.get("diceBonus"), 32), self.number(meta.get("diceSides"), 32), bool(card.get("reinforced"))]

        skills = self.bounded(private.get("skills", []), c.skills, "skills")
        skill_slots = {skill["instanceId"]: i for i, skill in enumerate(skills)}
        for i, skill in enumerate(skills):
            anchor = skill.get("cooldownAnchor") or {}
            did = skill.get("definitionId")
            out["skills"][i] = [1, reg.token("skills", did), reg.known("skills", did),
                self.number(skill.get("cooldown"), 64), self.number(skill.get("mpCost"), 32),
                self.number(skill.get("lifeCost"), 4000), bool(skill.get("anytime")), bool(skill.get("passive")),
                bool(skill.get("requirementsMet")), bool(skill.get("costsPayable")), bool(skill.get("revealed")),
                bool(skill.get("borrowed")), bool(skill.get("leasedOut")), bool(skill.get("beforeAttack")),
                bool(skill.get("beforeCards")), self.number(skill.get("remainingUses"), 64), skill.get("remainingUses") is None,
                rel(anchor.get("anchorPlayerId")), self.number(anchor.get("turn"), 64), anchor.get("phase") == "turnEnd"]

        # Variable tokens retain every primitive/list/map leaf, with explicit bounds.
        leaves = []
        def leaf(value, key=None, position=0, depth=0):
            if isinstance(value, dict) and value:
                for n, (k, v) in enumerate(sorted(value.items())):
                    yield from leaf(v, k, n, depth + 1)
            elif isinstance(value, list) and value:
                for n, v in enumerate(value):
                    yield from leaf(v, key, n, depth + 1)
            else:
                yield value, key, position, depth
        for var in sorted(private.get("variables", []), key=lambda v: (reg.indices["variables"].get(f"{v.get('namespace', '')}:{v['id']}", 0), v['id'], rel(v.get('holderId')))):
            vid = f"{var.get('namespace', '')}:{var['id']}"
            unknown += not reg.known("variables", vid)
            for value, key, position, depth in leaf(var.get("value")):
                leaves.append([1, reg.token("variables", vid), reg.known("variables", vid), rel(var.get("holderId")),
                    self.number(value, 1000), self.number(len(value) if isinstance(value, (list, dict, str)) else 0, 64),
                    reg.token("tags", value) if isinstance(value, str) else 0, rel(key), self.number(position, 128),
                    self.number(depth, 8), isinstance(value, (list, dict)), self.number(int(key) if isinstance(key, str) and key.isdecimal() else 0, 128),
                    rel(value) if isinstance(value, str) else 0,
                    reg.token('cards', value) if isinstance(value, str) else 0])
        for i, row in enumerate(self.bounded(leaves, c.variables, "variable leaves")):
            out["variables"][i] = row
        records = self.bounded(private.get("actionRecords", []), c.records, "records")
        record_slots = {record["id"]: i for i, record in enumerate(records)}
        for i, record in enumerate(records):
            out["records"][i, :4] = [1, self.number(record.get("damage"), 4000),
                                               self.number(len(record.get("cards", [])), 16), rel(record.get("actorId"))]
            for j, card in enumerate(self.bounded(record.get("cards", []), c.hand, "record cards")):
                out["records"][i, 4 + j] = reg.token("cards", card)

        if not terminal and not frame.get("terminated") and not frame.get("truncated"):
            total = decision["candidateCount"]
            page = self.bounded(decision["candidates"], c.candidate_capacity - 2, "candidate page")
            if decision["candidateOffset"] != offset:
                raise ValueError("Mismatched candidate page")
            if offset:
                out["candidates"][0, 0] = out["action_mask"][0] = 1
            if offset + len(page) < total:
                out["candidates"][1, 1] = out["action_mask"][1] = 1
            for slot, candidate in enumerate(page, 2):
                row = out["candidates"][slot]
                tail = row[25 + c.hand:]
                kind, command, features = candidate["kind"], candidate.get("command", {}), candidate.get("features", {})
                adapter_kind = kind if kind in ('selectCard', 'unselectCard', 'cancelCardSelection') else None
                if adapter_kind:
                    kind = 'playCards'
                    tail[30 + ('selectCard', 'unselectCard', 'cancelCardSelection').index(adapter_kind)] = 1
                    for position, iid in enumerate(candidate.get('features', {}).get('selectedCardIds', [])):
                        if iid in hand_slots:
                            row[25 + hand_slots[iid]] = self.card_position(position)
                    tail[34] = features.get('canCommit', False)
                    iid = candidate.get('features', {}).get('cardInstanceId')
                    if iid in hand_slots:
                        tail[33] = self.card_position(hand_slots[iid])
                if kind not in ACTION_KINDS:
                    raise ValueError(f"Unsupported candidate kind: {kind}")
                row[ACTION_KINDS.index(kind)] = 1
                targets = command.get("targetIds", features.get("targets", [command.get("targetId")]))
                for target in targets:
                    if target in slots:
                        row[17 + slots[target]] = 1
                for position, iid in enumerate(command.get("cardInstanceIds", [])):
                    if iid in hand_slots:
                        row[25 + hand_slots[iid]] = self.card_position(position)
                option = features.get("option", {})
                did = features.get("definitionId") or option.get("definitionId") or option.get("statusId") or option.get("markId")
                group = next((group for group in ("skills", "cards", "statuses", "marks", "characters") if reg.known(group, did)), "cards")
                tail[:23] = [reg.token(group, did), reg.known(group, did), reg.token("skills", command.get("copiedSkillId")),
                    self.number(command.get("number"), 128), self.number(command.get("diceResult"), 256), bool(command.get("reverse")),
                    (record_slots[command["recordId"]] + 1) / 9 if command.get("recordId") in record_slots else 0,
                    (skill_slots[command["skillInstanceId"]] + 1) / 17 if command.get("skillInstanceId") in skill_slots else 0,
                    self.number(features.get("quotedMpCost", features.get("mpCost")), 32), "quotedMpCost" in features or "mpCost" in features, bool(features.get("attack")),
                    self.number(features.get("attackPower"), 1000), self.number(features.get("damage"), 4000),
                    self.number(features.get("healing"), 4000), self.number(features.get("shield"), 4000),
                    self.number(features.get("draw"), 16), self.number(features.get("targetStatusBenefit"), 64),
                    bool(features.get("cancel")), option.get("hidden", "definitionId" not in option and "targetId" in option),
                    bool(option.get("skip") or option.get("done") or option.get("action") in ("skip", "pass", "done")),
                    rel(option.get("targetId")), self.number(option.get("stacks"), 32), self.number(option.get("intensity"), 32)]
                tail[23] = reg.token("options", option.get("optionId"))
                tail[24] = self.number(option.get("value", option.get("count")), 64)
                tail[25] = bool(command.get("cardInstanceId"))
                tail[26] = self.number(features.get("selfStatusBenefit"), 64)
                tail[27] = self.number(features.get("cardCount"), 16)
                tail[28] = self.card_position(carried_slots[command["cardInstanceId"]]) if command.get("cardInstanceId") in carried_slots else 0
                if command.get("cardInstanceId") in carried_slots:
                    tail[29] = reg.token("cards", carried[carried_slots[command["cardInstanceId"]]].get("definitionId"))
                out["action_mask"][slot] = 1
            if not np.any(out["action_mask"]):
                raise ValueError("Nonterminal observation has no legal actions")
        g[29] = self.number(unknown, 128)
        if not self.space.contains(out):
            raise ValueError("Encoded observation does not match its declared space")
        return out

    def manifest(self):
        return {"numericObservationSchema": self.schema, "encoderVersion": 3,
                "actionSchema": 2, "candidateCapacity": self.config.candidate_capacity,
                "config": asdict(self.config), "shapes": {k: list(v) for k, v in self.shapes.items()},
                "scales": self.scales, "definitionRegistryRevision": self.registry.document["revision"],
                "paging": {"previous": 0, "next": 1, "firstCandidate": 2}}
