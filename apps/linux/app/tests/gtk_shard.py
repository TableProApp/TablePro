def parse(spec):
    index, count = spec.split("/")
    index, count = int(index), int(count)
    if count < 1 or not 1 <= index <= count:
        raise ValueError(f"bad shard {spec!r}, expected i/n with 1 <= i <= n")
    return index, count


def select(items, spec):
    if not spec:
        return list(items)
    index, count = parse(spec)
    return [item for position, item in enumerate(items) if position % count == index - 1]
