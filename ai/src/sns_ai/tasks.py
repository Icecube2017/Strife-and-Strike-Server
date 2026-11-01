"""Task metadata and reproducible, episode-weighted curricula; no hidden state."""
from __future__ import annotations

import copy
import json
from pathlib import Path

import numpy as np


def scenario_catalog(directory):
    result = {}
    for path in sorted(Path(directory).glob('*.json')):
        row = json.loads(path.read_text(encoding='utf-8'))
        if row['id'] in result:
            raise ValueError(f"Duplicate scenario ID: {row['id']}")
        players = row['players']
        teams = {p['teamId'] for p in players}
        if len(players) == 2 and len(teams) == 2:
            mode = 'duel'
        elif len(teams) == len(players):
            mode = 'ffa'
        elif len(teams) == 2:
            mode = 'team'
        else:
            raise ValueError('Numeric schema v1 does not represent relationships between multiple enemy teams')
        result[row['id']] = {'mode': mode, 'learners': [p['id'] for p in players]}
    if not result:
        raise ValueError('Scenario set is empty')
    return result


def resolve_cases(catalog, cases, *, unique=False):
    result, seen = [], set()
    for raw in cases:
        case = copy.deepcopy(raw)
        if set(case) - {'scenarioId', 'learnerId', 'mode', 'weight'}:
            raise ValueError('Unknown task case fields')
        spec = catalog.get(case.get('scenarioId'))
        if spec is None or case.get('learnerId') not in spec['learners']:
            raise ValueError(f"Unknown scenario or learner: {case}")
        if case.get('mode', spec['mode']) != spec['mode']:
            raise ValueError('Task mode differs from scenario team structure')
        case['mode'] = spec['mode']
        weight = case.get('weight', 1)
        if type(weight) is not int or not 1 <= weight <= 100:
            raise ValueError('Task weight must be an integer from 1 to 100')
        key = (case['scenarioId'], case['learnerId'])
        if unique:
            case.pop('weight', None)
            if key in seen:
                continue
        seen.add(key)
        result.append(case)
    if not result or sum(c.get('weight', 1) for c in result) > 4096:
        raise ValueError('Empty or oversized task schedule')
    return result


class CaseSchedule:
    """Every complete shuffled cycle has the exact configured episode mix."""
    def __init__(self, cases, seed, worker, low, high):
        self.cases, self.low, self.high = cases, low, high
        self.rng = np.random.default_rng(np.random.SeedSequence([seed, worker]))
        self.bag = [i for i, c in enumerate(cases) for _ in range(c.get('weight', 1))]
        self.order = []
        self.position = 0

    def sample(self):
        if self.position == len(self.order):
            self.order = list(self.rng.permutation(self.bag))
            self.position = 0
        case = self.cases[self.order[self.position]]
        self.position += 1
        return case, int(self.rng.integers(self.low, self.high + 1))
