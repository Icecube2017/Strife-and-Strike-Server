"""Spawn-isolated 1/2/4-worker benchmarks on an identical episode set."""
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
from pathlib import Path
import platform
import queue
import sys
import time
import traceback

import numpy as np
import psutil

from .env import StrifeEnv


def _worker(config, indices, barrier, output):
    env = None
    try:
        env = StrifeEnv(project_root=config["projectRoot"], dart=config.get("dart"),
            content=config.get("content"), scenarios=config.get("scenarios"), registry=config.get("registry"),
            scenario_id=config["scenarioIds"][0], learner_id=config.get("learnerId", "a"),
            opponent=config.get("opponent", "rules"), failure_directory=config.get("failureDirectory"))
        warmup = time.perf_counter()
        obs, _ = env.reset(seed=991)
        for _ in range(5):
            legal = np.flatnonzero(obs["action_mask"])
            obs, _, terminated, truncated, _ = env.step(int(legal[-1]))
            if terminated or truncated:
                break
        startup = time.perf_counter() - warmup
        backend_before = env.bridge.request('metrics')
        barrier.wait(timeout=120)
        started = time.perf_counter()
        bridge_before = env.bridge.roundtrip_seconds
        decode_before = env.bridge.decode_seconds
        encode_before = env.encoding_seconds
        samples = []
        candidate_samples = []
        results = []
        kernel_commands = learner_steps = 0
        python_process = psutil.Process()
        def combined_rss():
            processes = [python_process, *python_process.children(recursive=True)]
            return sum(p.memory_info().rss for p in processes if p.is_running())
        peak_rss = combined_rss()
        dart_peak_rss = 0
        backend_after = backend_before
        for index in indices:
            seed = config.get("seed", 1000) + index
            rng = np.random.default_rng(seed ^ 0xBC3)
            obs, info = env.reset(seed=seed, options={"scenario_id": config["scenarioIds"][index % len(config["scenarioIds"])]})
            terminated, truncated = info["terminated"], info["truncated"]
            reward = info["reset_reward"]
            while not terminated and not truncated:
                legal = np.flatnonzero(env.action_masks())
                tick = time.perf_counter()
                obs, reward, terminated, truncated, info = env.step(int(rng.choice(legal)))
                samples.append(time.perf_counter() - tick)
                learner_steps += 1
                if learner_steps % 25 == 0:
                    peak_rss = max(peak_rss, combined_rss())
            metrics = env.bridge.request("metrics")
            backend_after = metrics
            candidate_samples.extend(metrics.get("candidateGenerationMicroseconds", []))
            dart_peak_rss = max(dart_peak_rss, metrics["maxRss"])
            kernel_commands += info["metrics"]["kernelCommands"]
            results.append({"episode": index, "seed": seed, "terminated": terminated,
                "truncated": truncated, "reason": info["reason"], "reward": reward,
                "learnerSteps": info["learner_steps"], "outcome": info["outcome"]})
        output.put({"ok": True, "started": started, "ended": time.perf_counter(),
            "startupSeconds": startup, "learnerSteps": learner_steps, "kernelCommands": kernel_commands,
            "roundtripSeconds": env.bridge.roundtrip_seconds - bridge_before,
            "jsonDecodeSeconds": env.bridge.decode_seconds - decode_before,
            "encodingSeconds": env.encoding_seconds - encode_before,
            "backendSerializationSeconds": (backend_after.get('serializationMicroseconds', 0) - backend_before.get('serializationMicroseconds', 0)) / 1000000,
            "backendDispatchSeconds": (backend_after.get('dispatchMicroseconds', 0) - backend_before.get('dispatchMicroseconds', 0)) / 1000000,
            "stepSamplesSeconds": samples, "candidateSamplesMicroseconds": candidate_samples,
            "sampledCombinedPeakRssBytes": peak_rss, "dartPeakRssBytes": dart_peak_rss,
            "episodes": results})
    except BaseException as error:
        try:
            barrier.abort()
        except Exception:
            pass
        output.put({"ok": False, "error": str(error), "stack": traceback.format_exc()})
    finally:
        if env:
            env.close()


def _stop_owned_worker(process):
    if not process.is_alive():
        process.join(timeout=5)
        return
    try:
        children = psutil.Process(process.pid).children(recursive=True)
    except psutil.NoSuchProcess:
        children = []
    for child in children:
        try:
            child.terminate()
        except psutil.NoSuchProcess:
            pass
    process.terminate()
    process.join(timeout=5)


def measure(config: dict, workers: int, episodes: int):
    context = mp.get_context("spawn")
    output, barrier = context.Queue(), context.Barrier(workers)
    processes = [context.Process(target=_worker, args=(config, list(range(i, episodes, workers)), barrier, output))
                 for i in range(workers)]
    try:
        for process in processes:
            process.start()
        rows = []
        for _ in processes:
            try:
                row = output.get(timeout=300)
            except queue.Empty as error:
                raise RuntimeError("Benchmark worker timed out") from error
            if not row["ok"]:
                raise RuntimeError(row["error"] + "\n" + row["stack"])
            rows.append(row)
        wall = max(row["ended"] for row in rows) - min(row["started"] for row in rows)
        steps = sum(row["learnerSteps"] for row in rows)
        commands = sum(row["kernelCommands"] for row in rows)
        samples = [x for row in rows for x in row["stepSamplesSeconds"]]
        candidates = [x for row in rows for x in row["candidateSamplesMicroseconds"]]
        results = sorted([r for row in rows for r in row["episodes"]], key=lambda r: r["episode"])
        return {"workers": workers, "episodes": episodes, "wallSeconds": wall,
            "completed": sum(row["terminated"] for row in results),
            "truncated": sum(row["truncated"] for row in results),
            "technicalFailures": sum(row["reason"] == "technicalFailure" for row in results),
            "learnerSteps": steps, "kernelCommands": commands,
            "learnerStepsPerSecond": steps / wall, "kernelCommandsPerSecond": commands / wall,
            "gamesPerHour": episodes * 3600 / wall,
            "stepP50Milliseconds": float(np.quantile(samples, .5) * 1000) if samples else 0,
            "stepP95Milliseconds": float(np.quantile(samples, .95) * 1000) if samples else 0,
            "candidateP50Microseconds": float(np.quantile(candidates, .5)) if candidates else 0,
            "candidateP95Microseconds": float(np.quantile(candidates, .95)) if candidates else 0,
            "encodingCpuSeconds": sum(row["encodingSeconds"] for row in rows),
            "roundtripWorkerSeconds": sum(row["roundtripSeconds"] for row in rows),
            "jsonDecodeCpuSeconds": sum(row["jsonDecodeSeconds"] for row in rows),
            "backendSerializationCpuSeconds": sum(row['backendSerializationSeconds'] for row in rows),
            "backendDispatchCpuSeconds": sum(row['backendDispatchSeconds'] for row in rows),
            "maximumWorkerCombinedRssBytes": max(row["sampledCombinedPeakRssBytes"] for row in rows),
            "maximumDartRssBytes": max(row["dartPeakRssBytes"] for row in rows),
            "workerStartupSeconds": [row["startupSeconds"] for row in rows], "results": results}
    finally:
        for process in processes:
            if process.pid is not None:
                process.join(timeout=5)
                _stop_owned_worker(process)
        output.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("ai/configs/environment.json"))
    parser.add_argument("--workers", nargs="+", type=int, default=[1, 2, 4])
    parser.add_argument("--episodes", type=int, default=24)
    parser.add_argument("--out", type=Path, default=Path("ai/runs/gym-benchmark/report.json"))
    parser.add_argument("--dart")
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    config["projectRoot"] = str(Path(config.get("projectRoot", ".")).resolve())
    for name in ("content", "scenarios", "registry"):
        if config.get(name):
            config[name] = str((Path(config["projectRoot"]) / config[name]).resolve())
    if args.dart:
        config["dart"] = args.dart
    config.setdefault('failureDirectory', str((args.out.parent / 'failures').resolve()))
    if args.episodes < max(args.workers) or any(x < 1 or x > 8 for x in args.workers):
        parser.error("Use 1-8 workers and at least one episode per worker")
    rows = []
    for count in args.workers:
        row = measure(config, count, args.episodes)
        rows.append(row)
        print(json.dumps({k: v for k, v in row.items() if k != "results"}), flush=True)
    fingerprints = [[(r["seed"], r["outcome"], r["learnerSteps"], r["reward"]) for r in row["results"]] for row in rows]
    repeatable = all(value == fingerprints[0] for value in fingerprints[1:])
    report = {"benchmarkVersion": 1, "python": sys.version, "platform": platform.platform(),
              "config": config, "deterministicAcrossWorkerCounts": repeatable, "measurements": rows}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    if not repeatable or any(row["truncated"] or row["technicalFailures"] for row in rows):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
