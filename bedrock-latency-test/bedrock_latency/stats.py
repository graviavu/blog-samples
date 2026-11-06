"""Median, nearest-rank percentile, savings and ratios."""
import math


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def percentile(xs, p):
    """Nearest-rank percentile: the ceil(p/100 * n)-th smallest value. With under 10 values p90 is the maximum."""
    xs = sorted(xs)
    if not xs:
        return None
    k = max(1, math.ceil(p / 100.0 * len(xs)))
    return xs[k - 1]


def saving_pct(base, x):
    """Percent saved versus base: positive means x is lower than base."""
    if base is None or x is None or base == 0:
        return None
    return (base - x) / base * 100.0


def ratio(a, b):
    if a is None or b is None or b == 0:
        return None
    return a / b
