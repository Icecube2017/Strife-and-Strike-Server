"""Frozen local experiments and a bounded, mask-aware training environment."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import signal
import sys
import time
from importlib.metadata import version

import gymnasium as gym
import numpy as np
import psutil
from stable_baselines3.common.monitor import Monitor
from stable_baselines3.common.vec_env import DummyVecEnv, SubprocVecEnv

from .env import StrifeEnv
from .tasks import CaseSchedule, resolve_cases, scenario_catalog
from .rewards import reward_config


# These files change experiment orchestration, not engine execution or encoding.
# Legacy models may import across these changes; each new run remains strictly frozen.
WORKFLOW_SOURCES = frozenset(f'ai/src/sns_ai/{name}.py' for name in ('train', 'evaluate', 'experiment', 'tasks'))

# Exact audited implementation pairs, not a general exemption for encoder/engine
# edits. Model compatibility still uses the unchanged numeric schema and registry.
RUNTIME_MIGRATION_ID = 'scalar-fused-v1'
RUNTIME_SOURCE_UPGRADE = {
    'ai/src/sns_ai/encoding.py': (
        'ba5561369a7c51ff621975ccc7aaec7165c166413a446b10b0fa762fbf06942c',
        '0ccfe18083ef9d7666c07cf8bb2d175618eeebe0cc2e5b119745c781fa216e13'),
    'ai/src/sns_ai/env.py': (
        '359211753ca3ba23075fbabec71507561c51746b6df271910ed5d0e08564e008',
        'eaa50923ee9129d05a9696c21964219894468bad3880c1963cb9837f4a6b0c55'),
    'bin/ai_bridge.dart': (
        '4e664ed4c43ccf2d4d20d42dcd456fd7d9695d635c53e26826206acd93904598',
        '462ded6a94781e0c98b3f1071951f4ce8572663661faadc90b8f50b63da9bf48'),
}


ADVANCE_MIGRATION_ID = 'chunked-advance-v1'
ADVANCE_SOURCE_UPGRADE = {
    'ai/src/sns_ai/bridge.py': (
        '7509fba491a2c199734dc24cff968596a4927b509f9cab5cdec03411fbac03d3',
        'fbd8505aa16c8f0ce3f14a0f413ee047fdf24da103372d6978f06c73524c3b0b'),
    'ai/src/sns_ai/env.py': (
        'b4269c2d8cadcc073e7e6eae2285f9395768ddfcf7e48411fbb95d8959ddc8b4',
        '0941e73559463c153a5e1cb0d9a4d3aaa6bc9ab5e7c085dfd63567bce08c61df'),
    'lib/development/ai/learner_session.dart': (
        'a2ae77eaba6da1e05c7a0b561ca95db280dd8bcc5e10ee857978850017f2b572',
        'e2a68e5a85376336e2a3ffe040c5bc138524902b9894cd19022fbace6e56d436'),
    'bin/ai_bridge.dart': (
        'a7a75e2879e66ea8bf79223fc9396591aa5d9eefe25053ee0098ccb95f9c15dc',
        '2cfef3ddb72dc74bae09632c1aa3c274ac955688fb195e83a2a4974ce354f9b1'),
}

# This is a deliberate decision/rule change, not a numerically equivalent
# transport optimization. Only explicitly reviewed source pairs may opt in.
DECISION_POLICY_ID = 'legal-progress-v4'
DECISION_POLICY_UPGRADE = {
    'ai/src/sns_ai/bridge.py': (('7509fba491a2c199734dc24cff968596a4927b509f9cab5cdec03411fbac03d3', 'fbd8505aa16c8f0ce3f14a0f413ee047fdf24da103372d6978f06c73524c3b0b'), 'fbd8505aa16c8f0ce3f14a0f413ee047fdf24da103372d6978f06c73524c3b0b'),
    'ai/src/sns_ai/env.py': (('0941e73559463c153a5e1cb0d9a4d3aaa6bc9ab5e7c085dfd63567bce08c61df', 'b4269c2d8cadcc073e7e6eae2285f9395768ddfcf7e48411fbb95d8959ddc8b4', 'd2937894ee1149c1ae105051970de78151a23c770f5835e44736affbacc9fab3'), 'd2937894ee1149c1ae105051970de78151a23c770f5835e44736affbacc9fab3'),
    'bin/ai_bridge.dart': (('2cfef3ddb72dc74bae09632c1aa3c274ac955688fb195e83a2a4974ce354f9b1', 'a7a75e2879e66ea8bf79223fc9396591aa5d9eefe25053ee0098ccb95f9c15dc'), '2cfef3ddb72dc74bae09632c1aa3c274ac955688fb195e83a2a4974ce354f9b1'),
    'lib/development/ai/arena.dart': (('68031107e9d7f89c636855ef637913b4ea438ead287009b864f64e267ce90867', 'cd8f639cb9075f2c3c4d8569e66f1e1447c433a1347be3c49eff5f0f80d3727e'), '68031107e9d7f89c636855ef637913b4ea438ead287009b864f64e267ce90867'),
    'lib/development/ai/learner_session.dart': (('a2ae77eaba6da1e05c7a0b561ca95db280dd8bcc5e10ee857978850017f2b572', 'e2a68e5a85376336e2a3ffe040c5bc138524902b9894cd19022fbace6e56d436'), 'e2a68e5a85376336e2a3ffe040c5bc138524902b9894cd19022fbace6e56d436'),
    'packages/sns_kernel/lib/src/ai_decisions.dart': (('76e06c9d128c7325e8386d227f86d1e097592a9084c7815d47fc1418d83021ef', 'b47c1851ee80692f5b83a570864fdd7d0d92fd6b2830a3ea356fc41c400f3031', 'e87d60e32caff5a1026b3ea34ba72648f97f2409577b06c0c192c616b1d19f41'), 'e87d60e32caff5a1026b3ea34ba72648f97f2409577b06c0c192c616b1d19f41'),
    'packages/sns_kernel/lib/src/attack_rules.dart': (('1e0744d94ec9c947ee82c16aed0bdd9b41adbd231f0ffbf68603a466d0f0acc0', '2f7147c37598c7062b0956f691b3f11dd90e85b03d313229b9b25b2e13bf45f5'), '2f7147c37598c7062b0956f691b3f11dd90e85b03d313229b9b25b2e13bf45f5'),
    'packages/sns_kernel/lib/src/engine.dart': (('0b75200452deb00317f00248260d9e1edfe404bf9af22306233dffe8d9f831db', '38fff89b3290088a018ddea2367ea5fca64651ce469924de173763a79a4be094', '5cc1df8a79af7e2f547adc10ead2f95015757cdee3746e6207edabab26b9690d', '960de765de84b2f3cb01a7498750555fd02ab9574782a14cc8036b7364b51f65', 'f32b5ef9c364a5510af06235d961174fc340ea8be57210a8295e5964c463c5fa'), '0b75200452deb00317f00248260d9e1edfe404bf9af22306233dffe8d9f831db'),
    'packages/sns_kernel/lib/src/recovery_engine.dart': (('1ce36397be95aa0d79aeb04227ec43fafbf9836c2d5f394cd5e5341535adada5', '4a8bd4bb9a7156ec163bef9d28e924979ab58d13ad06a97f7edc25d330fb4cff', '57fec0f7104a15fbe933737cbb768b59bcb6495ef238d72952cc065688c8ccb3', '8e2b3d20469323c6a4968624d17c246679989a58c93deb38ad06769814b7c65e', 'c4a682b7a93ac4a59a5f31b91b5e23ec6d8670d4a717580cf2b5e27ac34f9500'), 'c4a682b7a93ac4a59a5f31b91b5e23ec6d8670d4a717580cf2b5e27ac34f9500'),
    'packages/sns_kernel/lib/src/response_engine.dart': (('53628cf68b62a42207ee1f1e8818cb1d7a634ffe9ce748afcd830a38d7c54ce8', '7c79b3d9304b42258c60334ba838126810a926f75e1527602985e59d8d98cb72', 'd4cecb9db5ce6cd6f19608b3aca58175ba98bb7d5cd7613eb2a1f56194aa2643'), 'd4cecb9db5ce6cd6f19608b3aca58175ba98bb7d5cd7613eb2a1f56194aa2643'),
    'packages/sns_kernel/lib/src/ability_flow.dart': (('270f0ccbd7c457fb7ddc790721b0509d28f2382f8fb9b7adfb43d730f9992af1', 'ccad8262f30ad87821c283cb76f04871b9caa80e3503ebeb96752e95c63c5961'), 'ccad8262f30ad87821c283cb76f04871b9caa80e3503ebeb96752e95c63c5961'),
    'packages/sns_kernel/lib/src/ability_preparation.dart': (('7aa40a92bba13f7a01a1fa4c05b2063846c02158edbfe19d39a0f29e0502fca8', 'bcd80c5ae29a74ab306eceb47b8392b39f5789c04f6130b1bbf847554b0e06fe'), 'bcd80c5ae29a74ab306eceb47b8392b39f5789c04f6130b1bbf847554b0e06fe'),
    'packages/sns_kernel/lib/src/ability_options.dart': (('441bfd5f898e22ccfe7d3e156f009bb4783ba729099b6bc170700ef2d0c2b408', 'ac022a1dfc1b860167b09f9936973e748c07e126ba32dbcdf031e8a7ff523722'), '441bfd5f898e22ccfe7d3e156f009bb4783ba729099b6bc170700ef2d0c2b408'),
    'packages/sns_kernel/lib/src/bound_choices.dart': (('0244040072e193e6ca1fb6fdbb4fbeec2497c096f929f1bea9b978b3191c6eee', '58d423e33874506cd5100b50c71f6f9c27ccab54d79f42ea1b805b9edab2cdd6'), '58d423e33874506cd5100b50c71f6f9c27ccab54d79f42ea1b805b9edab2cdd6'),
    'packages/sns_kernel/lib/src/query_operations.dart': (('24e5ab3907bd519c2dceb76ec1c3a96058e8d1737fb80522ddde4be15a85d2bb', 'c0a6021f68a977584734b68e4a2034772fcaa5b25162559a272df98b101c37c1'), '24e5ab3907bd519c2dceb76ec1c3a96058e8d1737fb80522ddde4be15a85d2bb'),
    'packages/sns_kernel/lib/src/skill_modules.dart': (('022d06dec315bdeebe34e77a35d06b1a2a3604d62de1ed0552d89b33e15b047f', 'caa759ee2be47e6186c1e96187c8918d1856ac235221520884d7148b72ed24f2'), '022d06dec315bdeebe34e77a35d06b1a2a3604d62de1ed0552d89b33e15b047f'),
}


def implementation_digest(path):
    # Line endings can differ between checkouts; executable statements cannot.
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def runtime_source_pairs(root, run, migration_id=RUNTIME_MIGRATION_ID):
    pairs = {}
    if migration_id == DECISION_POLICY_ID:
        for name, (accepted, after) in DECISION_POLICY_UPGRADE.items():
            live, frozen = root / name, run / 'source' / name
            before = implementation_digest(frozen) if frozen.is_file() else None
            if (before not in accepted or not live.is_file()
                    or implementation_digest(live) != after):
                raise ValueError(f'Unrecognized decision policy implementation: {name}')
            if before != after:
                pairs[name] = {'before': before, 'after': after}
        return pairs
    sources = ADVANCE_SOURCE_UPGRADE if migration_id == ADVANCE_MIGRATION_ID else RUNTIME_SOURCE_UPGRADE
    for name, (before, after) in sources.items():
        live, frozen = root / name, run / 'source' / name
        if (not live.is_file() or not frozen.is_file()
                or implementation_digest(frozen) != before
                or implementation_digest(live) != after):
            raise ValueError(f'Unrecognized runtime implementation: {name}; no migration exemption applies')
        pairs[name] = {'before': before, 'after': after}
    return pairs


def approved_runtime_migration(root, run):
    policy_receipt = run / 'decision-policy-upgrade.json'
    if policy_receipt.is_file():
        saved = read_json(policy_receipt)
        checks = saved.get('validation', {})
        if (saved.get('migrationVersion') != 1 or saved.get('migrationId') != DECISION_POLICY_ID
                or saved.get('validated') is not True or saved.get('behaviorEquivalent') is not False
                or checks.get('verifiedCases') != 3 or checks.get('realTransitions', 0) < 1
                or not all(checks.get(k) is True for k in (
                    'modelContractUnchanged', 'checkpointBytesUnchanged', 'noTechnicalFailures'))
                or saved.get('sourcePairs') != runtime_source_pairs(root, run, DECISION_POLICY_ID)):
            raise ValueError('Invalid decision policy upgrade; run scripts/upgrade_ai_decision_policy.py')
        return saved
    receipt = run / 'runtime-migration.json'
    if not receipt.is_file():
        return None
    saved = read_json(receipt)
    checks = saved.get('validation', {})
    if (saved.get('migrationVersion') != 1 or saved.get('migrationId') not in (RUNTIME_MIGRATION_ID, ADVANCE_MIGRATION_ID)
            or saved.get('validated') is not True
            or checks.get('completedEpisodes', 0) < 1
            or checks.get('completedEpisodes') != checks.get('expectedEpisodes')
            or checks.get('matchedTransitions', 0) < 1
            or not all(checks.get(k) is True for k in (
                'observationsIdentical', 'candidatesIdentical', 'kernelCheckpointsIdentical',
                'normalizationIdentical', 'checkpointBytesUnchanged'))):
        raise ValueError('Invalid runtime migration receipt; rerun scripts/migrate_ai_runtime.py')
    if saved.get('sourcePairs') != runtime_source_pairs(root, run, saved['migrationId']):
        raise ValueError('Runtime migration source pairs differ')
    return saved


class TrainingFailure(RuntimeError):
    pass


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".pending")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    for attempt in range(7):
        try:
            temporary.replace(path)
            break
        except PermissionError:
            # Windows indexers/antivirus may briefly hold the destination open.
            # Keep the old complete JSON until replacement succeeds.
            if attempt == 6:
                raise
            time.sleep(.01 * 2 ** attempt)


def validate_config(config):
    if config.get("configVersion") != 1 or config.get("device") != "cpu":
        raise ValueError("Pilot v1 requires configVersion=1 and device=cpu")
    for key in ("workers", "torchThreads", "totalDecisionSteps", "rolloutSteps", "batchSize",
                "optimizationEpochs", "checkpointEveryUpdates", "evaluateEveryUpdates",
                "maximumKernelDecisions", "maximumLearnerSteps"):
        if type(config.get(key)) is not int or config[key] < 1:
            raise ValueError(f"{key} must be a positive integer")
    if config["workers"] > 4 or config["rolloutSteps"] * config["workers"] % config["batchSize"]:
        raise ValueError("Use at most 4 workers and batchSize dividing the rollout")
    if config["rolloutSteps"] * config["workers"] < 2:
        raise ValueError("A PPO rollout needs at least two samples")
    if config.get("opponent") not in ("rules", "random"):
        raise ValueError("Unknown fixed opponent")
    if not config.get("cases") or any(not {'scenarioId', 'learnerId'} <= set(c)
            or set(c) - {'scenarioId', 'learnerId', 'mode', 'weight'} for c in config["cases"]):
        raise ValueError("Explicit scenarioId/learnerId cases are required")
    if any(type(c.get('weight', 1)) is not int or not 1 <= c.get('weight', 1) <= 100 for c in config['cases']):
        raise ValueError('Task weights must be integers from 1 to 100')
    if not config.get("policyHiddenSizes") or any(type(x) is not int or x < 1 for x in config["policyHiddenSizes"]):
        raise ValueError("Invalid policyHiddenSizes")
    low, high = config["trainingSeedStart"], config["trainingSeedStop"]
    if not 0 <= low < high or any(low <= s <= high for s in config["evaluation"]["seeds"]):
        raise ValueError("Training and evaluation seed ranges must be disjoint")
    if not config["evaluation"]["seeds"] or any(x not in ("rules", "random") for x in config["evaluation"]["opponents"]):
        raise ValueError("Invalid evaluation suite")
    reward_config(config.get("reward"))
    return config


def source_files(root):
    files = []
    for directory, suffix in (("packages/sns_kernel/lib", ".dart"), ("lib/development/ai", ".dart"),
                              ("ai/src/sns_ai", ".py")):
        files.extend(p for p in (root / directory).rglob("*" + suffix) if p.is_file())
    files.extend(root / p for p in ("bin/ai_bridge.dart", "pubspec.yaml", "pubspec.lock",
                                   "packages/sns_kernel/pubspec.yaml", "ai/pyproject.toml"))
    return sorted(p for p in files if p.is_file())


def verify_source(root, run, *, allow_workflow_changes=False, runtime_migration=None):
    manifest = read_json(run / "run.json")
    if manifest.get("experimentVersion") not in (1, 2):
        raise ValueError("Unsupported experimentVersion")
    if runtime_migration not in (None, RUNTIME_MIGRATION_ID, ADVANCE_MIGRATION_ID, DECISION_POLICY_ID):
        raise ValueError('Unknown runtime migration')
    receipt = None
    approved_runtime_files = set()
    if runtime_migration is not None:
        approved_runtime_files = set(runtime_source_pairs(root, run, runtime_migration))
    elif allow_workflow_changes:
        receipt = approved_runtime_migration(root, run)
        if receipt:
            approved_runtime_files = set(receipt['sourcePairs'])
    workflow_changes = []
    runtime_changes = []
    for name in manifest["sourceFiles"]:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid frozen source path")
        live, frozen = root / relative, run / "source" / relative
        if not live.is_file() or live.read_bytes() != frozen.read_bytes():
            if name in approved_runtime_files:
                runtime_changes.append(name)
                continue
            if allow_workflow_changes and name in WORKFLOW_SOURCES and live.is_file():
                workflow_changes.append(name)
                continue
            hint = ('; validate this optimization with python scripts/migrate_ai_runtime.py --run <experiment>'
                    if name in RUNTIME_SOURCE_UPGRADE else '; use the frozen source checkout')
            raise ValueError(f"Source differs from the model experiment: {name}{hint}")
    added = {p.relative_to(root).as_posix() for p in source_files(root)} - set(manifest['sourceFiles'])
    for name in sorted(added):
        if allow_workflow_changes and name in WORKFLOW_SOURCES:
            workflow_changes.append(name)
        else:
            raise ValueError(f'Source added after experiment snapshot: {name}')
    if asset_contract(run) != manifest['assets']:
        raise ValueError('Frozen content, registry or scenarios were modified')
    return {**manifest, 'importedWorkflowChanges': workflow_changes,
            'importedRuntimeChanges': runtime_changes, 'importedRuntimeMigration': receipt}


def asset_contract(run):
    return {'content': read_json(run / 'assets/content.json'),
            'registry': read_json(run / 'assets/definitions.json'),
            'scenarios': {p.name: read_json(p) for p in sorted((run / 'assets/scenarios').glob('*.json'))}}


def prepare_run(root, run, config, parent=None, *, warm_start=None, asset_parent=None):
    imported = verify_source(root, parent, allow_workflow_changes=True) if parent else None
    scenario_source = root / config.get('scenarioSet', 'ai/scenarios/full-match')
    if asset_parent is not None:
        scenario_source = asset_parent / 'assets/scenarios'
    if parent and not warm_start:
        scenario_source = parent / 'assets/scenarios'
    if not parent or warm_start:
        scenario_source = scenario_source.resolve()
        if not scenario_source.is_relative_to(root.resolve()):
            raise ValueError('Scenario set must be inside the project')
    for path in scenario_source.glob('*.json'):
        scenario = read_json(path)
        if scenario.get('trainingMode') != 'fullMatch':
            raise ValueError('Training requires production fullMatch scenarios; diagnostic fixtures cannot receive match rewards')
    catalog = scenario_catalog(scenario_source)
    resolved = resolve_cases(catalog, config['cases'])
    run.mkdir(parents=True, exist_ok=False)
    assets = run / "assets"
    assets.mkdir()
    content_parent = asset_parent or parent
    if content_parent:
        shutil.copyfile(content_parent / 'assets/content.json', assets / 'content.json')
        shutil.copyfile(content_parent / 'assets/definitions.json', assets / 'definitions.json')
    else:
        shutil.copyfile(root / "content/content_items.json", assets / "content.json")
        shutil.copyfile(root / "ai/configs/definitions.json", assets / "definitions.json")
    shutil.copytree(scenario_source, assets / 'scenarios')
    files = source_files(root)
    names = []
    for source in files:
        name = source.relative_to(root).as_posix()
        target = run / "source" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        names.append(name)
    manifest = {"experimentVersion": 2, "numericObservationSchema": 3, "actionSchema": 2,
        "rulesVersion": "sns-ai-full-match-3", "balanceRevision": "2026-10-30.1",
        "decisionPolicy": DECISION_POLICY_ID,
        "trainingContract": "full-match-reward-v2", "reward": reward_config(config.get("reward")),
        "scope": config.get('taskName', "restricted-four-character-pilot"), "config": copy.deepcopy(config),
        "resolvedCases": resolved, 'caseCatalog': catalog,
        "sourceFiles": names, "assets": asset_contract(run), "python": sys.version, "pythonExecutable": sys.executable,
        "packages": {p: version(p) for p in ("torch", "stable-baselines3", "sb3-contrib", "gymnasium", "numpy", "psutil")},
        "resumedFrom": str(parent) if parent and not warm_start else None,
        'warmStartedFrom': warm_start,
        'importedWorkflowChanges': imported['importedWorkflowChanges'] if imported else [],
        'importedRuntimeChanges': imported['importedRuntimeChanges'] if imported else [],
        'runtimeImplementation': 'full-match-cards-v3',
        'importedRuntimeMigration': ({
            'migrationId': imported['importedRuntimeMigration']['migrationId'],
            'validatedAt': imported['importedRuntimeMigration']['validatedAt'],
            'sourceExperiment': str(parent),
        } if imported and imported['importedRuntimeMigration'] else None),
        "resumeSemantics": "model+optimizer+step-count; fresh episodes and rollout; not bit-exact continuation"}
    write_json(run / "run.json", manifest)
    return manifest


def environment(root, run, config, **kwargs):
    return StrifeEnv(project_root=root, content=run / "assets/content.json",
        scenarios=run / "assets/scenarios", registry=run / "assets/definitions.json",
        maximum_kernel_decisions=config["maximumKernelDecisions"],
        maximum_learner_steps=config["maximumLearnerSteps"],
        failure_directory=run / "failures", reward=config.get("reward"), **kwargs)


class PilotEnv(gym.Wrapper):
    def __init__(self, root, run, config, worker):
        self.cases = resolve_cases(scenario_catalog(run / 'assets/scenarios'), config['cases'])
        super().__init__(environment(root, run, config, opponent=config["opponent"]))
        self.config, self.worker, self.episode_index = config, worker, 0
        self.schedule = self._schedule(config['seed'])

    def _schedule(self, seed):
        return CaseSchedule(self.cases, seed, self.worker,
                            self.config['trainingSeedStart'], self.config['trainingSeedStop'])

    def reset(self, *, seed=None, options=None):
        if seed is not None:
            self.schedule = self._schedule(seed)
            self.episode_index = 0
        case, game_seed = self.schedule.sample()
        self.current_case = case
        self.episode_index += 1
        self.env.learner_id = case["learnerId"]
        obs, info = self.env.reset(seed=game_seed, options={"scenario_id": case["scenarioId"]})
        if info["terminated"] or info["truncated"]:
            raise TrainingFailure(f"Invalid initial training episode: {info}")
        return obs, {**info, **self._case_info()}

    def _case_info(self):
        return {'mode': self.current_case['mode'], 'scenarioId': self.current_case['scenarioId'],
                'learnerId': self.current_case['learnerId']}

    def step(self, action):
        obs, reward, terminated, truncated, info = self.env.step(action)
        return obs, reward, terminated, truncated, {**info, **self._case_info()}

    def action_masks(self):
        return self.env.action_masks()


class OwnedSubprocVecEnv(SubprocVecEnv):
    """Bounded shutdown also covers a crashed worker with an unfinished receive."""
    def __init__(self, *args, failure_directory=None, **kwargs):
        self.failure_directory = Path(failure_directory) if failure_directory else None
        super().__init__(*args, **kwargs)

    def step_wait(self):
        try:
            return super().step_wait()
        except (EOFError, BrokenPipeError, ConnectionResetError) as error:
            self.waiting = False
            details = 'No reproduction file was written'
            if self.failure_directory:
                failures = sorted(self.failure_directory.glob('failure-*.json'))
                if failures:
                    latest = failures[-1]
                    saved = read_json(latest)
                    details = f"{saved.get('adapterError') or saved.get('error') or saved.get('adapterReason')}; case: {latest}"
            raise TrainingFailure(f'Environment worker exited: {details}') from error

    def close(self):
        if self.closed:
            return
        owned = []
        for process in self.processes:
            try:
                owned.extend(psutil.Process(process.pid).children(recursive=True))
            except psutil.NoSuchProcess:
                pass
        for remote in self.remotes:
            try:
                if self.waiting and remote.poll(.05):
                    remote.recv()
                remote.send(("close", None))
            except (OSError, EOFError):
                pass
        for process in self.processes:
            process.join(timeout=5)
            if process.is_alive():
                process.terminate()
                process.join(timeout=3)
        _, alive = psutil.wait_procs(owned, timeout=1)
        for process in alive:
            try:
                process.terminate()
            except psutil.NoSuchProcess:
                pass
        _, alive = psutil.wait_procs(alive, timeout=2)
        for process in alive:
            try:
                process.kill()
            except psutil.NoSuchProcess:
                pass
        for remote in self.remotes:
            remote.close()
        self.closed = True


def make_vector(root, run, config):
    def factory(index):
        def create():
            # Console Ctrl+C also reaches Windows subprocesses. The parent owns
            # graceful stopping; workers must finish their current rollout.
            if config['workers'] > 1:
                signal.signal(signal.SIGINT, signal.SIG_IGN)
            return Monitor(PilotEnv(root, run, config, index))
        return create
    factories = [factory(i) for i in range(config["workers"])]
    return DummyVecEnv(factories) if len(factories) == 1 else OwnedSubprocVecEnv(factories, start_method="spawn", failure_directory=run / "failures")


def bundle_paths(model_path):
    model = Path(model_path).resolve()
    if model.is_dir():
        model = model / "model.zip"
    metadata = read_json(model.parent / "checkpoint.json")
    if metadata.get("checkpointVersion") != 1:
        raise ValueError("Unsupported checkpointVersion")
    run = model.parent.parent.parent
    if not model.is_file() or not (run / "run.json").is_file():
        raise ValueError("Expected a complete local experiment checkpoint bundle")
    return model, run, metadata


def check_contract(env, metadata):
    if env.encoder.manifest() != metadata["encoder"] or env.encoder.registry.document != metadata["registry"]:
        raise ValueError("Model encoder or definition registry differs")


def save_checkpoint(model, root, run, encoder, registry):
    verify_source(root, run)
    name = f"step-{model.num_timesteps:09d}"
    target = run / "checkpoints" / name
    target.mkdir(parents=True, exist_ok=False)
    # Publish the completion metadata last. Avoid Windows directory renames while
    # antivirus/indexing still holds the large ZIP open; incomplete bundles cannot load.
    model.save(target / "model.zip")
    write_json(target / "checkpoint.json", {"checkpointVersion": 1, "numTimesteps": model.num_timesteps,
        "updates": model._n_updates, "encoder": encoder, "registry": registry})
    write_json(run / "latest.json", {"model": str(target.relative_to(run) / "model.zip"),
        "numTimesteps": model.num_timesteps})
    return target / "model.zip"
