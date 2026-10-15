def run_scenarios(scenarios, run, retries, report=print):
    failures = []
    for scenario in scenarios:
        name = scenario.__name__
        for attempt in range(retries + 1):
            try:
                run(scenario)
            except AssertionError as error:
                if attempt == retries:
                    failures.append((name, error))
                    report(f"FAILED: {name}")
                    report(f"AssertionError: {error}")
                    break
                first = str(error).splitlines()[0][:300]
                report(f"RETRY: {name} failed once, running it again: {first}")
                continue
            report(f"passed: {name}")
            break
    return failures


def summary(failures):
    return f"{len(failures)} GTK scenario(s) failed: {', '.join(name for name, _ in failures)}"
