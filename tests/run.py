"""Run the Lua 5.1 mocked regression suite with optional Lupa.

Install the runner dependency with: python -m pip install lupa
The Lua suite also runs directly: lua5.1 tests/regression.lua
"""

from pathlib import Path


def main() -> None:
    try:
        from lupa.lua51 import LuaRuntime
    except ImportError as exc:
        raise SystemExit(
            "Install lupa (python -m pip install lupa), or run "
            "lua5.1 tests/regression.lua from the addon directory."
        ) from exc

    root = Path(__file__).resolve().parents[1]
    source = (root / "ForeverRank.lua").read_text(encoding="utf-8-sig")
    harness = (root / "tests" / "regression.lua").read_text(encoding="utf-8")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().FOREVERRANK_TEST_SOURCE = source
    lua.execute(harness)


if __name__ == "__main__":
    main()
