"""Small CPU MaskablePPO pilot. Checkpoints are published after optimizer updates."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime
from pathlib import Path
import signal
import time

import torch
from sb3_contrib import MaskablePPO
from stable_baselines3.common.callbacks import BaseCallback
from stable_baselines3.common.logger import configure

from .evaluate import evaluate_model
from .experiment import (TrainingFailure, bundle_paths, check_contract, environment, make_vector,
                         prepare_run, read_json, save_checkpoint, validate_config, verify_source, write_json)


class EpisodeGuard(BaseCallback):
    def __init__(self, run):
        super().__init__()
        self.run = run
        self.episodes = []

    def _on_step(self):
        for info in self.locals['infos']:
            if info.get('reason') in ('technicalFailure', 'encodingFailure'):
                raise TrainingFailure(f"Environment failed; rollout rejected. See {self.run / 'failures'}")
            if 'episode' in info:
                self.episodes.append({**info['episode'], 'reason': info.get('reason'), 'outcome': info.get('outcome'),
                    **{k: info.get(k) for k in ('mode', 'scenarioId', 'learnerId')}})
        return True


def train(root, run, config, resume=None, evaluate=True, *, warm_start=None):
    config = validate_config(copy.deepcopy(config))
    if resume and warm_start:
        raise ValueError('Choose resume or warm-start, not both')
    parent = metadata = None
    model_path = None
    if resume or warm_start:
        model_path, parent, metadata = bundle_paths(resume or warm_start)
        old = verify_source(root, parent, allow_workflow_changes=True)['config']
        allowed = {'totalDecisionSteps', 'checkpointEveryUpdates', 'evaluateEveryUpdates'}
        if resume and {k:v for k,v in old.items() if k not in allowed} != {k:v for k,v in config.items() if k not in allowed}:
            raise ValueError('Resume requires the same training contract; only step budget and save/evaluation intervals may change')
        if warm_start and old['policyHiddenSizes'] != config['policyHiddenSizes']:
            raise ValueError('Warm-start requires the same network architecture')
    lineage = {'model': str(model_path), 'sourceTimesteps': metadata['numTimesteps'],
        'semantics': 'policy+critic weights only; fresh optimizer, rollout and task step count'} if warm_start else None
    prepare_run(root, run, config, parent, warm_start=lineage)
    torch.set_num_threads(config['torchThreads'])
    vec = None
    stop = False
    previous_handler = signal.getsignal(signal.SIGINT)

    def request_stop(signum, frame):
        nonlocal stop
        if stop:
            raise KeyboardInterrupt()
        stop = True
        print('Stop requested. Finishing this PPO update, then saving; press Ctrl+C again to abort immediately.', flush=True)

    signal.signal(signal.SIGINT, request_stop)
    started = time.perf_counter()
    latest = None
    guard = EpisodeGuard(run)
    updates = 0
    best = float('-inf')
    status = 'failed'
    try:
        probe = environment(root, run, config)
        try:
            encoder, registry = probe.encoder.manifest(), probe.encoder.registry.document
            if metadata:
                check_contract(probe, metadata)
        finally:
            probe.close()
        vec = make_vector(root, run, config)
        if resume:
            model = MaskablePPO.load(model_path, env=vec, device='cpu', force_reset=True)
            # Begin fresh episodes with a fresh deterministic stream, not repeated parent games.
            model.set_random_seed(config['seed'] + model.num_timesteps)
        else:
            model = MaskablePPO('MultiInputPolicy', vec, seed=config['seed'], device='cpu',
                learning_rate=config['learningRate'], n_steps=config['rolloutSteps'], batch_size=config['batchSize'],
                n_epochs=config['optimizationEpochs'], gamma=config['gamma'], gae_lambda=config['gaeLambda'],
                ent_coef=config['entropyCoefficient'], policy_kwargs={'net_arch': dict(pi=config['policyHiddenSizes'], vf=config['policyHiddenSizes'])}, verbose=1)
            if warm_start:
                source_model = MaskablePPO.load(model_path, device='cpu')
                if source_model.observation_space != vec.observation_space or source_model.action_space != vec.action_space:
                    raise ValueError('Warm-start observation/action spaces differ')
                model.policy.load_state_dict(source_model.policy.state_dict(), strict=True)
                del source_model
                model.set_random_seed(config['seed'])
        model.set_logger(configure(str(run / 'metrics'), ['stdout', 'csv']))
        initial_steps = model.num_timesteps
        target = initial_steps + config['totalDecisionSteps']
        chunk = config['rolloutSteps'] * config['workers']
        latest = save_checkpoint(model, root, run, encoder, registry)
        while model.num_timesteps < target and not stop:
            # One complete rollout and optimizer update; partial rollouts are never published.
            model.learn(total_timesteps=chunk, reset_num_timesteps=False, callback=guard, log_interval=1)
            model.logger.dump(step=model.num_timesteps)
            updates += 1
            verify_source(root, run)
            need_eval = evaluate and (updates % config['evaluateEveryUpdates'] == 0 or model.num_timesteps >= target)
            if updates % config['checkpointEveryUpdates'] == 0 or need_eval or stop or model.num_timesteps >= target:
                latest = save_checkpoint(model, root, run, encoder, registry)
            if need_eval:
                checkpoint_meta = read_json(latest.parent / 'checkpoint.json')
                result = evaluate_model(model, root, run, config, checkpoint_meta)
                write_json(run / 'evaluations' / f'step-{model.num_timesteps:09d}.json', result)
                summary = result['summary']
                if summary['allCompleted'] and result['selectionScore'] > best:
                    best = result['selectionScore']
                    write_json(run / 'best.json', {'model': str(latest.relative_to(run)), 'selectionMeanReward': best,
                        'selectionMetric': result['selectionMetric'],
                        'note': 'selected on development evaluation seeds, not an independent final test'})
                if summary['technicalFailures']:
                    raise TrainingFailure('Evaluation encountered a technical failure; see failures/')
            write_json(run / 'progress.json', {'numTimesteps': model.num_timesteps, 'requestedAdditionalSteps': config['totalDecisionSteps'],
                'actualAdditionalSteps': model.num_timesteps - initial_steps, 'updatesThisRun': updates,
                'episodes': len(guard.episodes), 'episodesByMode': {mode: sum(e['mode'] == mode for e in guard.episodes)
                    for mode in sorted({e['mode'] for e in guard.episodes})},
                'wallSeconds': time.perf_counter() - started})
        status = 'stopped' if stop else 'completed'
        return latest
    except BaseException as error:
        write_json(run / 'failure.json', {'error': str(error), 'type': type(error).__name__,
            'latestCompleteCheckpoint': str(latest) if latest else None})
        raise
    finally:
        if vec:
            vec.close()
        signal.signal(signal.SIGINT, previous_handler)
        write_json(run / 'summary.json', {'status': status, 'updatesThisRun': updates,
            'wallSeconds': time.perf_counter() - started, 'latestCompleteCheckpoint': str(latest) if latest else None,
            'episodes': guard.episodes, 'modelTrained': updates > 0})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, default=Path('ai/configs/pilot.json'))
    parser.add_argument('--out', type=Path)
    parser.add_argument('--steps', type=int, help='Additional learner decisions; rounded up to a complete rollout')
    parser.add_argument('--seed', type=int)
    loading = parser.add_mutually_exclusive_group()
    loading.add_argument('--resume', type=Path, help='Same task: restore optimizer and cumulative steps')
    loading.add_argument('--warm-start', type=Path, help='New task: inherit weights; reset optimizer and step count')
    parser.add_argument('--skip-evaluation', action='store_true', help='Plumbing tests only; does not certify the model')
    args = parser.parse_args()
    root = Path.cwd().resolve()
    config = read_json(args.config)
    if args.steps is not None:
        config['totalDecisionSteps'] = args.steps
    if args.seed is not None:
        config['seed'] = args.seed
    run = (args.out or Path('ai/runs') / datetime.now().strftime('pilot-%Y%m%d-%H%M%S')).resolve()
    latest = train(root, run, config, args.resume, not args.skip_evaluation, warm_start=args.warm_start)
    print(f'Latest complete model: {latest}', flush=True)


if __name__ == '__main__':
    main()
