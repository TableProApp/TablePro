import importlib.util
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def load_checker():
    spec = importlib.util.spec_from_file_location("check_function_size", ROOT / "check-function-size.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def measure_source(checker, source):
    with tempfile.TemporaryDirectory(prefix="bookie-function-size-") as temporary:
        path = Path(temporary) / "sample.rs"
        path.write_text(source, encoding="utf8")
        return {name: body for name, _, body in checker.measure(path)}


def a_brace_in_a_literal_does_not_swallow_the_rest_of_the_file(checker):
    source = (
        "fn holds_a_brace_literal() {\n"
        '    let opening = b"{";\n'
        "    let raw = r#\"{ not code }\"#;\n"
        "    let single = '{';\n"
        "    let byte = b'{';\n"
        '    let escaped = "quote \\" and {";\n'
        "    // a comment with { and }\n"
        "    /* a block { comment } */\n"
        "    let _ = (opening, raw, single, byte, escaped);\n"
        "}\n"
        "\n"
        "fn measured_separately() {\n"
        "    let x = 1;\n"
        "}\n"
    )
    bodies = measure_source(checker, source)
    assert "measured_separately" in bodies, f"a later function was hidden by a brace literal: {bodies}"
    assert bodies["holds_a_brace_literal"] == 8, bodies
    assert bodies["measured_separately"] == 1, bodies


def a_lifetime_is_not_read_as_a_char_literal(checker):
    source = "fn borrows<'a>(x: &'a str) -> &'a str {\n    x\n}\n\nfn after() {\n    let y = 2;\n}\n"
    bodies = measure_source(checker, source)
    assert bodies == {"borrows": 1, "after": 1}, bodies


def an_over_limit_function_is_still_found(checker):
    body = "\n".join(f"    let x{n} = {n};" for n in range(checker.LIMIT + 5))
    bodies = measure_source(checker, f"fn too_long() {{\n{body}\n}}\n")
    assert bodies["too_long"] > checker.LIMIT, bodies


def main():
    checker = load_checker()
    for check in (
        a_brace_in_a_literal_does_not_swallow_the_rest_of_the_file,
        a_lifetime_is_not_read_as_a_char_literal,
        an_over_limit_function_is_still_found,
    ):
        check(checker)
    print("function-size checker: OK")


if __name__ == "__main__":
    sys.exit(main())
