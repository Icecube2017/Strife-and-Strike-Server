"""Independent, paired-seat evaluation using frozen assets and legal action masks."""
from __future__ import annotations

import argparse
import copy
import hashlib
from pathlib import Path
import time

import numpy as np
import torch
from sb3_contrib import MaskablePPO

from .experiment import (DECISION_POLICY_ID, RUNTIME_MIGRATION_ID, bundle_paths, check_contract,
                         environment, read_json, verify_source, write_json)
from .tasks import resolve_cases, scenario_catalog
from .rewards import outcome_reward


def summarize(rows, expected_seats=None):
    completed = [r for r in rows if r["terminated"] and not r["truncated"]]
    groups = {}
    for row in rows:
        groups.setdefault((row["opponent"], row["scenarioId"], row["seed"]), []).append(row)
    paired = [sum(r["reward"] for r in group) / len(group) for group in groups.values()
              if len(group) == 2 and {r['learnerId'] for r in group} == {'a', 'b'}
              and all(r["terminated"] and not r["truncated"] for r in group)]
    seat_groups = [group for (_, scenario, _), group in groups.items()
        if expected_seats and len(group) == len(expected_seats[scenario])
        and {r['learnerId'] for r in group} == set(expected_seats[scenario])
        and all(r['terminated'] and not r['truncated'] for r in group)]
    # Same seed across seats/scenarios/opponents is one resampling cluster.
    seed_groups = {}
    for row in rows:
        seed_groups.setdefault(row['seed'], []).append(row)
    clusters = [sum(r['reward'] for r in group) / len(group) for group in seed_groups.values()
                if all(r['terminated'] and not r['truncated'] for r in group)]
    interval = None
    if len(clusters) >= 2:
        rng = np.random.default_rng(5917)
        means = rng.choice(clusters, size=(2000, len(clusters)), replace=True).mean(axis=1)
        interval = list(map(float, np.quantile(means, [.025, .975])))
    return {"episodes": len(rows), "completed": len(completed),
        "truncated": sum(r["truncated"] for r in rows),
        "technicalFailures": sum(r.get("reason") == "technicalFailure" for r in rows),
        "wins": sum(r["reward"] == 1 for r in completed),
        "losses": sum(r["reward"] == -1 for r in completed),
        "draws": sum(r["reward"] == 0 for r in completed),
        "winRateCompletedOnly": sum(r["reward"] == 1 for r in completed) / len(completed) if completed else None,
        "meanRewardCompletedOnly": float(np.mean([r["reward"] for r in completed])) if completed else None,
        "completeSeatPairs": len(paired), "pairedMeanReward95BootstrapInterval": interval,
        'completeSeatGroups': len(seat_groups),
        "allCompleted": len(completed) == len(rows),
        "completeSeedClusters": len(clusters),
        "intervalUnit": "seed cluster; seats/scenarios/opponents kept together; exploratory small-suite estimate"}


class EvaluationProgress:
    """Atomically persist completed episodes; retry only the interrupted episode."""
    def __init__(self, path, identity, settings, *, resume=False):
        self.path = Path(path)
        self.contract = {'evaluationProgressVersion': 1, 'identity': identity, 'settings': settings}
        self.rows = []
        self.active = None
        self.previous_seconds = 0.0
        self.started = time.perf_counter()
        if self.path.exists():
            if not resume:
                raise ValueError('Evaluation progress already exists; use --resume or a new output path')
            saved = read_json(self.path)
            if any(saved.get(k) != v for k, v in self.contract.items()):
                raise ValueError('Evaluation model or suite differs from saved progress')
            self.rows = saved['episodes']
            self.previous_seconds = saved.get('elapsedSeconds',0.0)
            keys = [self.key(row) for row in self.rows]
            expected = {(opponent, case['scenarioId'], case['learnerId'], seed)
                        for opponent in settings['opponents'] for case in settings['cases'] for seed in settings['seeds']}
            if len(set(keys)) != len(keys) or not set(keys) <= expected:
                raise ValueError('Evaluation progress contains duplicate or unknown episodes')
        elif resume:
            raise ValueError('No evaluation progress exists at this output path')
        self.persist('running')

    @staticmethod
    def key(row):
        return row['opponent'], row['scenarioId'], row['learnerId'], row['seed']

    @property
    def elapsed_seconds(self):
        return self.previous_seconds + time.perf_counter() - self.started

    def persist(self, status, error=None):
        write_json(self.path, {**self.contract, 'status': status, 'completedEpisodes': len(self.rows),
            'expectedEpisodes': len(self.contract['settings']['opponents']) * len(self.contract['settings']['cases']) * len(self.contract['settings']['seeds']),
            'activeEpisode': self.active, 'episodes': self.rows, 'error': error,
            'elapsedSeconds': self.elapsed_seconds})


def evaluate_model(model, root, run, config, metadata, suite=None, *, progress_path=None, resume=False, model_identity=None):
    settings = copy.deepcopy(suite or config["evaluation"])
    # Old partial evaluations must never be resumed under different decisions/rules.
    settings['decisionPolicy'] = DECISION_POLICY_ID
    catalog = scenario_catalog(run / 'assets/scenarios')
    cases = resolve_cases(catalog, settings.get("cases", config["cases"]), unique=True)
    settings['cases'] = cases
    expected_seats = {key: row['learners'] for key, row in catalog.items()}
    if (not cases or not settings.get('seeds') or not settings.get('opponents')
            or any(x not in ('rules', 'random') for x in settings['opponents'])
            or type(settings.get('maximumLearnerSteps')) is not int or settings['maximumLearnerSteps'] < 1
            or type(settings.get('deterministic')) is not bool
            or any(type(seed) is not int or seed < 0 for seed in settings['seeds'])):
        raise ValueError('Evaluation requires nonempty cases/seeds/opponents, a positive limit and boolean deterministic')
    if any(config["trainingSeedStart"] <= seed <= config["trainingSeedStop"] for seed in settings["seeds"]):
        raise ValueError("Evaluation seeds overlap the training seed range")
    cfg = {**config, "maximumLearnerSteps": settings["maximumLearnerSteps"]}
    journal = EvaluationProgress(progress_path, model_identity or {'metadata': metadata}, settings,
                                 resume=resume) if progress_path else None
    rows = journal.rows if journal else []
    completed_keys = {EvaluationProgress.key(row) for row in rows}
    if journal and rows:
        print(f'Resuming evaluation: {len(rows)} episodes already saved', flush=True)
    started = time.perf_counter()
    # Isolate evaluation sampling from training RNG; do not perturb the learner.
    with torch.random.fork_rng(devices=[]):
        for opponent in settings["opponents"]:
            env = environment(root, run, cfg, opponent=opponent)
            try:
                check_contract(env, metadata)
                for case_index, case in enumerate(cases):
                    for seed in settings["seeds"]:
                        context = {**case, 'seed': seed, 'opponent': opponent}
                        if EvaluationProgress.key(context) in completed_keys:
                            continue
                        if journal:
                            journal.active = context
                            journal.persist('running')
                        print(f"eval start {opponent} {case['scenarioId']} seat={case['learnerId']} seed={seed}",flush=True)
                        try:
                            env.learner_id = case["learnerId"]
                            torch.manual_seed(seed + case_index * 100003)
                            obs, info = env.reset(seed=seed, options={"scenario_id": case["scenarioId"]})
                            reward, terminated, truncated = info['reset_reward'], info['terminated'], info['truncated']
                            total_return = reward
                            steps = 0
                            while not (terminated or truncated):
                                action, _ = model.predict(obs, deterministic=settings["deterministic"], action_masks=env.action_masks())
                                obs, reward, terminated, truncated, info = env.step(int(action))
                                total_return += reward
                                steps += 1
                            reward = outcome_reward(env.frame, env.learner_id)
                            row = {**case, "seed": seed, "opponent": opponent, "reward": reward,
                                "terminated": terminated, "truncated": truncated, "reason": info["reason"],
                                "learnerSteps": steps, "trainingReturn": total_return,
                                "ratingPotential": env.rating_potential, "outcome": info["outcome"]}
                            rows.append(row)
                            completed_keys.add(EvaluationProgress.key(row))
                            if journal:
                                journal.active = None
                                journal.persist('running')
                            print(f"eval {opponent} {case['scenarioId']} seat={case['learnerId']} seed={seed}: reward={reward:+.0f} steps={steps} reason={info['reason']}", flush=True)
                        except BaseException as error:
                            if journal:
                                journal.persist('interrupted', f'{type(error).__name__}: {error}')
                            raise
            finally:
                env.close()
    modes = sorted({r['mode'] for r in rows})
    by_mode = {mode: summarize([r for r in rows if r['mode'] == mode], expected_seats) for mode in modes}
    summary = summarize(rows, expected_seats)
    if journal:
        journal.persist('finished')
    return {"evaluationVersion": 2, "settings": settings, "wallSeconds": journal.elapsed_seconds if journal else time.perf_counter() - started,
        "summary": summary, 'byMode': by_mode,
        "byOpponent": {name: summarize([r for r in rows if r['opponent'] == name], expected_seats) for name in settings['opponents']},
        'byOpponentAndMode': {name: {mode: summarize([r for r in rows if r['opponent'] == name and r['mode'] == mode], expected_seats)
            for mode in modes} for name in settings['opponents']},
        'selectionScore': float(np.mean([r['meanRewardCompletedOnly'] for r in by_mode.values()])) if summary['allCompleted'] else None,
        'selectionMetric': 'macroMeanRewardAcrossModes', 'caseCoverage': expected_seats,
        "episodes": rows}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--suite", type=Path, default=Path('ai/configs/evaluation.json'))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--deterministic", action="store_true")
    parser.add_argument("--resume", action="store_true", help="Continue this output file's saved evaluation episodes")
    args = parser.parse_args()
    root = Path.cwd().resolve()
    model_path, run, metadata = bundle_paths(args.model)
    manifest = verify_source(root, run, allow_workflow_changes=True)
    config = manifest['config']
    torch.set_num_threads(config['torchThreads'])
    model = MaskablePPO.load(model_path, device='cpu')
    suite = read_json(args.suite) if args.suite else copy.deepcopy(config['evaluation'])
    if args.deterministic:
        suite['deterministic'] = True
    if args.out.exists() and not args.resume:
        raise ValueError('Evaluation output already exists; use --resume or a new output path')
    identity = {'model': str(model_path), 'modelSha256': hashlib.sha256(model_path.read_bytes()).hexdigest(),
                'numTimesteps': metadata['numTimesteps']}
    result = evaluate_model(model, root, run, config, metadata, suite,
        progress_path=args.out.with_suffix('.progress.json'), resume=args.resume, model_identity=identity)
    verify_source(root, run, allow_workflow_changes=True)
    result['importedWorkflowChanges'] = manifest['importedWorkflowChanges']
    result['importedRuntimeChanges'] = manifest['importedRuntimeChanges']
    result['runtimeImplementation'] = manifest.get('runtimeImplementation', RUNTIME_MIGRATION_ID)
    result['runtimeMigrationId'] = (manifest['importedRuntimeMigration']['migrationId']
                                    if manifest['importedRuntimeMigration'] else None)
    result['model'] = str(model_path)
    result['numTimesteps'] = metadata['numTimesteps']
    result['overlapsDevelopmentSeeds'] = bool(set(suite['seeds']) & set(config['evaluation']['seeds']))
    write_json(args.out, result)
    print(result['summary'], flush=True)
    if not result['summary']['allCompleted']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
