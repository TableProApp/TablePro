import time


def run_scenarios(scenarios, run, retries, report=print):
    failures = []
    for scenario in scenarios:
        name = scenario.__name__
        for attempt in range(retries + 1):
            started = time.perf_counter()
            try:
                run(scenario)
            except AssertionError as error:
                elapsed = time.perf_counter() - started
                if attempt == retries:
                    failures.append((name, error))
                    report(f"FAILED: {name} (duration: {elapsed:.3f}s)")
                    report(f"AssertionError: {error}")
                    break
                first = str(error).splitlines()[0][:300]
                report(f"RETRY: {name} failed after {elapsed:.3f}s, running it again: {first}")
                continue
            elapsed = time.perf_counter() - started
            report(f"passed: {name} (duration: {elapsed:.3f}s)")
            break
    return failures


def summary(failures):
    return f"{len(failures)} GTK scenario(s) failed: {', '.join(name for name, _ in failures)}"
