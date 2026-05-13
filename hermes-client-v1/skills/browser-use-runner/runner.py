#!/usr/bin/env python3
"""browser-use runner — exécute une tâche browser via la lib browser-use.

Usage :
    echo '{"task":"...","url":"...","max_steps":10}' | python runner.py

Output : JSON sur stdout, conforme au schema SKILL.md.

Cf. SKILL.md pour les contraintes (RGPD, sécurité, robots.txt).
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import traceback
import uuid
from pathlib import Path
from typing import Any

# Note : browser-use est optionnel à l'import car le skill peut être chargé
# sans être appelé. La vraie validation = quand le runner s'exécute.

SCREENSHOTS_DIR = Path(os.environ.get("BROWSER_USE_SCREENSHOTS", "/data/browser-use/screenshots"))
DEFAULT_MAX_STEPS = 15
HARD_TIMEOUT_S = 90
RATE_LIMIT_SLEEP_S = 3.0  # entre appels successifs même runner


def _emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.flush()


def _fail(msg: str, screenshot_path: str | None = None) -> None:
    _emit(
        {
            "ok": False,
            "data": None,
            "steps_taken": 0,
            "duration_ms": 0,
            "screenshot_path": screenshot_path,
            "error": msg,
        }
    )
    sys.exit(0)  # exit 0 pour que le caller parse stdout, l'erreur est dans le JSON


async def run_task(args: dict[str, Any]) -> dict[str, Any]:
    """Charge browser-use à la demande et exécute la tâche."""
    try:
        # Lazy import — évite l'erreur au chargement du skill si lib absente.
        from browser_use import Agent, ChatBrowserUse
    except ImportError as e:
        return {
            "ok": False,
            "error": f"browser-use non installé : {e}. Lancer `pip install browser-use` dans le container.",
            "data": None,
        }

    task = args.get("task", "").strip()
    url = args.get("url", "").strip() or None
    max_steps = int(args.get("max_steps", DEFAULT_MAX_STEPS))
    capture = bool(args.get("screenshot", True))
    extract_schema = args.get("extract_schema")

    if not task:
        return {"ok": False, "error": "field 'task' requis", "data": None}
    if max_steps > 30:
        return {"ok": False, "error": "max_steps > 30 interdit (anti-runaway)", "data": None}

    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    screenshot_path = (
        SCREENSHOTS_DIR / f"{time.strftime('%Y-%m-%d_%H%M%S')}_{uuid.uuid4().hex[:8]}.png"
        if capture
        else None
    )

    start_ms = int(time.time() * 1000)

    # LLM : browser-use accepte ChatBrowserUse natif OU n'importe quel LLM OpenAI-compat.
    # En prod Hermès Platform, on route via la gateway Hermès :8642 (OpenAI-compat).
    llm_kwargs: dict[str, Any] = {}
    if os.environ.get("BROWSER_USE_LLM_BASE_URL"):
        llm_kwargs["api_base"] = os.environ["BROWSER_USE_LLM_BASE_URL"]
    if os.environ.get("BROWSER_USE_LLM_API_KEY"):
        llm_kwargs["api_key"] = os.environ["BROWSER_USE_LLM_API_KEY"]

    llm = ChatBrowserUse(**llm_kwargs) if llm_kwargs else ChatBrowserUse()

    full_task = task
    if url:
        full_task = f"Aller sur {url}. Puis: {task}"
    if extract_schema:
        full_task += (
            f"\n\nExtraire les données dans ce schema JSON et retourner uniquement le JSON :"
            f"\n{json.dumps(extract_schema, ensure_ascii=False, indent=2)}"
        )

    try:
        agent = Agent(task=full_task, llm=llm)
        result = await asyncio.wait_for(
            agent.run(max_steps=max_steps),
            timeout=HARD_TIMEOUT_S,
        )
    except asyncio.TimeoutError:
        return {
            "ok": False,
            "error": f"timeout après {HARD_TIMEOUT_S}s",
            "data": None,
            "screenshot_path": str(screenshot_path) if screenshot_path else None,
        }
    except Exception as e:  # noqa: BLE001
        return {
            "ok": False,
            "error": f"agent error : {e}",
            "data": None,
            "screenshot_path": str(screenshot_path) if screenshot_path else None,
        }

    duration_ms = int(time.time() * 1000) - start_ms

    # Screenshot final (best-effort).
    if capture and screenshot_path:
        try:
            await agent.browser.screenshot(path=str(screenshot_path), full_page=True)
        except Exception:
            screenshot_path = None  # pas bloquant

    # Tentative de parser le résultat en JSON si extract_schema fourni.
    parsed_data: Any = None
    raw_output = result.final_result() if hasattr(result, "final_result") else str(result)
    if extract_schema:
        try:
            # Heuristique : trouver le premier { ... } valide
            json_start = raw_output.find("{")
            json_end = raw_output.rfind("}")
            if 0 <= json_start < json_end:
                parsed_data = json.loads(raw_output[json_start : json_end + 1])
            else:
                parsed_data = {"raw": raw_output}
        except json.JSONDecodeError:
            parsed_data = {"raw": raw_output}
    else:
        parsed_data = {"raw": raw_output}

    return {
        "ok": True,
        "data": parsed_data,
        "steps_taken": getattr(result, "steps", None) or max_steps,
        "duration_ms": duration_ms,
        "screenshot_path": str(screenshot_path) if screenshot_path else None,
        "error": None,
    }


def main() -> None:
    try:
        raw = sys.stdin.read()
        args = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        _fail(f"stdin not valid JSON : {e}")

    result = asyncio.run(run_task(args))
    _emit(result)
    # Rate limit léger pour ne pas spam les sites scrappés en boucle skill.
    time.sleep(RATE_LIMIT_SLEEP_S)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        _fail("interrupted")
    except Exception as e:  # noqa: BLE001
        _fail(f"runner crashed : {e}\n{traceback.format_exc()}")
