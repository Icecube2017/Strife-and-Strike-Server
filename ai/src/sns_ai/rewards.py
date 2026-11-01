"""Versioned, bounded reward policy, separate from observations and win metrics."""
from __future__ import annotations

import math


def reward_config(value=None):
    value = dict(value or {})
    if set(value) - {'mode', 'win', 'loss', 'draw', 'scoreWeight', 'scoreScale'}:
        raise ValueError('Unknown reward configuration')
    mode = value.get('mode', 'winLoss')
    if mode not in ('winLoss', 'hybrid'):
        raise ValueError('Unknown reward mode')
    result = {'mode': mode, 'win': 1.5 if mode == 'hybrid' else 1.0,
              'loss': -2.0 if mode == 'hybrid' else -1.0, 'draw': 0.0,
              'scoreWeight': 1.0, 'scoreScale': 10.0, **value}
    for key in ('win', 'loss', 'draw', 'scoreWeight', 'scoreScale'):
        if isinstance(result[key], bool) or not isinstance(result[key], (int, float)) or not math.isfinite(result[key]):
            raise ValueError('Reward values must be finite numbers')
    if not result['loss'] < result['draw'] < result['win'] or result['scoreScale'] <= 0 or result['scoreWeight'] < 0:
        raise ValueError('Invalid reward bounds')
    if mode == 'hybrid' and min(result['win']-result['draw'], result['draw']-result['loss']) <= result['scoreWeight']:
        raise ValueError('Outcome bonuses must dominate the bounded score contribution')
    return result


def outcome_reward(frame, learner_id):
    if not frame or not frame.get('terminated'):
        return 0.0
    outcome = frame.get('outcome') or {}
    if outcome.get('draw'):
        return 0.0
    won = (outcome.get('winnerTeamId') == frame['learnerTeamId']
           or outcome.get('winnerPlayerId') == learner_id)
    return 1.0 if won else -1.0


def score_potential(frame, config):
    if config['mode'] != 'hybrid':
        return 0.0
    rating = (frame.get('trainingFeedback') or {}).get('rating')
    if not isinstance(rating, (float, int)) or not math.isfinite(rating) or rating < 0:
        raise ValueError('Hybrid reward requires finite committed rating feedback')
    return config['scoreWeight'] * rating / (rating + config['scoreScale'])


def transition_reward(frame, learner_id, config, previous_potential):
    potential = score_potential(frame, config)
    score = potential - previous_potential
    outcome = outcome_reward(frame, learner_id)
    terminal = (config['win'] if outcome > 0 else config['loss'] if outcome < 0 else config['draw']) if frame.get('terminated') else 0.0
    return terminal + score, potential, {'outcome': terminal, 'score': score, 'ratingPotential': potential}
