"""One learner, fixed-policy opponents and explicit terminal/truncation semantics."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
import time

import gymnasium as gym
import numpy as np

from .bridge import DartBridge
from .definitions import DefinitionRegistry
from .encoding import EncoderConfig, ObservationEncoder
from .rewards import reward_config, score_potential, transition_reward


class StrifeEnv(gym.Env):
    metadata = {"render_modes": []}

    def __init__(self, *, project_root: str | Path, scenario_id="rondo-encouragement-1v1",
                 learner_id="a", opponent="rules", dart=None, content=None, scenarios=None,
                 registry=None, encoder_config=None, maximum_kernel_decisions=10000,
                 maximum_learner_steps=10000, failure_directory=None, reward=None):
        super().__init__()
        self.reward_config = reward_config(reward)
        self.rating_potential = 0.0
        self.reward_parts = {}
        self.root = Path(project_root).resolve()
        self.content_path = Path(content or self.root / "content/content_items.json").resolve()
        self.scenario_path = Path(scenarios or self.root / "ai/scenarios/full-match").resolve()
        content_data = json.loads(self.content_path.read_text(encoding="utf-8"))
        if isinstance(registry, DefinitionRegistry):
            definitions = registry
        elif registry is not None:
            definitions = DefinitionRegistry.load(registry)
        else:
            definitions = DefinitionRegistry.load(self.root / "ai/configs/definitions.json")
        self.encoder = ObservationEncoder(definitions, content_data, encoder_config or EncoderConfig())
        self.observation_space = self.encoder.space
        self.action_space = gym.spaces.Discrete(self.encoder.config.candidate_capacity)
        self.payload_capacity = int(self.action_space.n) - 2
        self.scenario_id, self.learner_id, self.opponent = scenario_id, learner_id, opponent
        self.maximum_kernel_decisions = maximum_kernel_decisions
        self.maximum_learner_steps = maximum_learner_steps
        if maximum_kernel_decisions < 1 or maximum_learner_steps < 1:
            raise ValueError("Episode limits must be positive")
        self.failure_directory = Path(failure_directory) if failure_directory else None
        self.bridge = DartBridge(project_root=self.root, content=self.content_path,
                                 scenarios=self.scenario_path, dart=dart)
        self.frame = None
        self.observation = None
        self.offset = 0
        self.learner_steps = 0
        self.done = True
        self.encoding_seconds = 0.0
        self.local_truncation = None
        self.navigation_decision = None
        self.navigation_steps = 0

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        options = options or {}
        game_seed = int(seed) if seed is not None else int(self.np_random.integers(1, 2147483646))
        self.scenario_id = options.get("scenario_id", self.scenario_id)
        self.frame = self._request_frame("reset", scenarioId=self.scenario_id, seed=game_seed,
            learnerId=self.learner_id, opponent=self.opponent, policySeed=game_seed ^ 0x153A,
            maximumDecisions=self.maximum_kernel_decisions, capacity=self.payload_capacity,
            ratingFeedback=self.reward_config["mode"] == "hybrid")
        self.offset = 0
        self.learner_steps = 0
        self.local_truncation = None
        self.navigation_decision = None
        self.navigation_steps = 0
        self.rating_potential = score_potential(self.frame, self.reward_config)
        self.reward_parts = {}
        self.done = bool(self.frame["terminated"] or self.frame["truncated"])
        if self.frame.get("reason") == "technicalFailure":
            self._save_failure("technicalFailure")
        self._page()
        self._encode()
        return self._copy_observation(), self._info(reset_reward=self._reward())

    def _request_frame(self, method, **payload):
        # One learner step may settle an entire match after this player dies.
        # Drain bounded opponent batches without sampling or charging extra steps.
        frame = self.bridge.request(method, advanceBudget=256, **payload)
        while frame.get('advancing'):
            frame = self.bridge.request('advance', advanceBudget=256,
                                        capacity=self.payload_capacity)
        return frame

    def _page(self):
        decision = self.frame.get("decision")
        if decision is not None:
            # New reset/step/restore replies already contain this page. Old bridges
            # ignore capacity on those calls; request a page only when needed.
            expected = min(self.payload_capacity, decision["candidateCount"] - self.offset)
            if (decision["candidateOffset"] == self.offset
                    and len(decision["candidates"]) == expected):
                return
            self.frame = self.bridge.request("decision", offset=self.offset, capacity=self.payload_capacity)

    def _encode(self):
        started = time.perf_counter()
        try:
            # Adapter time limits preserve the underlying valid next observation.
            self.observation = self.encoder.encode(self.frame, offset=self.offset,
                terminal=bool(self.frame.get('terminated') or self.frame.get('truncated')))
            decision = self.frame.get('decision') or {}
            decision_id = decision.get('decisionId')
            if self.navigation_decision != decision_id:
                self.navigation_decision, self.navigation_steps = decision_id, 0
            pages = (decision.get('candidateCount', 0) + self.payload_capacity - 1) // self.payload_capacity
            if self.navigation_steps >= 2 * pages + 4:
                # Still allow returning to any earlier page and every real action.
                # Repeatedly flipping pages cannot consume the whole episode.
                self.observation['action_mask'][1] = 0
        except Exception:
            self._save_failure("encodingFailure", sys.exc_info()[1])
            raise
        finally:
            self.encoding_seconds += time.perf_counter() - started

    def _copy_observation(self):
        return {key: value.copy() for key, value in self.observation.items()}

    def action_masks(self):
        if self.observation is None:
            raise gym.error.ResetNeeded("Call reset before requesting masks")
        return self.observation["action_mask"].astype(bool, copy=True)

    def step(self, action):
        if self.done or self.frame is None:
            raise gym.error.ResetNeeded("Call reset after a finished episode")
        if not self.action_space.contains(action) or not self.action_masks()[int(action)]:
            raise gym.error.InvalidAction("Action is masked or outside the current candidate page")
        action = int(action)
        self.learner_steps += 1
        if action == 0:
            self.navigation_steps += 1
            self.offset -= self.payload_capacity
        elif action == 1:
            self.navigation_steps += 1
            self.offset += self.payload_capacity
        else:
            decision = self.frame["decision"]
            self.frame = self._request_frame("step", decisionId=decision["decisionId"],
                candidateIndex=self.offset + action - 2, capacity=self.payload_capacity)
            self.offset = 0
        terminated = bool(self.frame["terminated"])
        truncated = bool(self.frame["truncated"])
        if not terminated and not truncated and self.learner_steps >= self.maximum_learner_steps:
            self.local_truncation = "learnerDecisionLimit"
            truncated = True
        self.done = terminated or truncated
        if not terminated and not self.frame['truncated']:
            self._page()
        self._encode()
        if truncated and self.frame.get("reason") == "technicalFailure":
            self._save_failure("technicalFailure")
        return self._copy_observation(), self._reward(), terminated, truncated, self._info()

    def _reward(self):
        value, self.rating_potential, self.reward_parts = transition_reward(
            self.frame, self.learner_id, self.reward_config, self.rating_potential)
        return value

    def _info(self, **extra):
        decision = self.frame.get("decision") or {}
        return {"decision_id": decision.get("decisionId"), "candidate_offset": self.offset,
                "candidate_count": decision.get("candidateCount", 0), "learner_steps": self.learner_steps,
                "reason": self.local_truncation or self.frame.get("reason"),
                "terminated": bool(self.frame.get("terminated")),
                "truncated": bool(self.local_truncation or self.frame.get("truncated")),
                "outcome": copy.deepcopy(self.frame.get("outcome")),
                "reward_parts": dict(self.reward_parts),
                "metrics": copy.deepcopy(self.frame.get("metrics", {})), **extra}

    def checkpoint(self):
        if self.frame is None:
            raise gym.error.ResetNeeded("No episode to save")
        backend = self.bridge.request("checkpoint")
        return {"gymCheckpointVersion": 2, "rewardConfig": self.reward_config,
                "ratingPotential": self.rating_potential, "numericObservationSchema": self.encoder.schema,
                "encoderManifest": self.encoder.manifest(), "registry": self.encoder.registry.document,
                "scenarioId": self.scenario_id, "learnerId": self.learner_id,
                "backend": backend, "offset": self.offset, "learnerSteps": self.learner_steps,
                "done": self.done, "localTruncation": self.local_truncation,
                "navigationDecision": self.navigation_decision, "navigationSteps": self.navigation_steps,
                "numpyRngState": copy.deepcopy(self.np_random.bit_generator.state)}

    def restore(self, saved):
        if saved.get("gymCheckpointVersion") not in (1, 2) or saved.get("encoderManifest") != self.encoder.manifest() or saved.get("registry") != self.encoder.registry.document:
            raise ValueError("Incompatible environment checkpoint or definition mapping")
        if saved["learnerId"] != self.learner_id:
            raise ValueError("Learner identity differs")
        if reward_config(saved.get("rewardConfig")) != self.reward_config:
            raise ValueError("Environment reward contract differs")
        self.rating_potential = saved.get("ratingPotential", 0.0)
        self.reward_parts = {}
        backend = saved["backend"]
        self.frame = self._request_frame("restore", scenarioId=saved["scenarioId"],
            checkpoint=backend["checkpoint"], session=backend["session"],
            offset=saved["offset"], capacity=self.payload_capacity)
        self.scenario_id = saved["scenarioId"]
        self.offset, self.learner_steps = saved["offset"], saved["learnerSteps"]
        self.done, self.local_truncation = saved["done"], saved["localTruncation"]
        self.navigation_decision = saved.get('navigationDecision')
        self.navigation_steps = saved.get('navigationSteps', 0)
        self.np_random.bit_generator.state = copy.deepcopy(saved["numpyRngState"])
        self._page()
        self._encode()
        return self._copy_observation(), self._info()

    def _save_failure(self, reason, error=None):
        if not self.failure_directory:
            return
        self.failure_directory.mkdir(parents=True, exist_ok=True)
        try:
            case = self.bridge.request("failureCase")
        except Exception as error:
            case = {"error": str(error)}
        case["adapterReason"] = reason
        if error is not None:
            case["adapterError"] = f"{type(error).__name__}: {error}"
        case["numericEncoder"] = self.encoder.manifest()
        (self.failure_directory / f"failure-{time.time_ns()}.json").write_text(
            json.dumps(case, ensure_ascii=False, indent=2), encoding="utf-8")

    def close(self):
        if hasattr(self, "bridge"):
            self.bridge.close()
