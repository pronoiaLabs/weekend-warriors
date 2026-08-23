from __future__ import annotations

import argparse

from weekend_warriors_ml.pipeline import cook, fit, inspect
from weekend_warriors_ml.session import create_session
from weekend_warriors_ml.specs import SPECS


def main() -> None:
    parser = argparse.ArgumentParser(description="NFL models on FEATURES. Fit in Workspace.")
    parser.add_argument(
        "command",
        choices=("list", "inspect", "fit", "cook"),
        help="list = specs; inspect = row counts; fit = walk-forward; cook = fit+register+score",
    )
    parser.add_argument(
        "model",
        nargs="?",
        default="NFL_GAME_TOTAL",
        help="Registry model name. Default NFL_GAME_TOTAL.",
    )
    parser.add_argument(
        "--batch",
        action="store_true",
        help="Also run mv.run_batch on ML_DEV_POOL after writing the pred table.",
    )
    args = parser.parse_args()
    if args.command == "list":
        for name, spec in SPECS.items():
            print(f"{name}\t{spec.task}\t{spec.label_column}\t{spec.notebook}")
        return

    session = create_session()
    try:
        if args.command == "inspect":
            inspect(session, args.model)
        elif args.command == "fit":
            fit(session, args.model)
        else:
            cook(session, args.model, batch=args.batch)
    finally:
        session.close()


if __name__ == "__main__":
    main()
