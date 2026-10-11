"""Unit tests for edge/index.py. No AWS, no boto3: the S3 client is a fake injected through the module-level factory.
Run: python3 -m unittest discover -s tests -p 'test_*.py'      (from the sample folder)"""
import calendar
import importlib.util
import json
import math
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('edge_index', os.path.join(HERE, '..', 'edge', 'index.py'))
edge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(edge)

CFG = {'startMin': 780, 'endMin': 1080, 'inTtl': 0, 'outTtl': 14400}   # 13:00 to 18:00 UTC
CFG_TEXT = json.dumps({'default': CFG})                                  # one default window for every path
IN = 'public, max-age=0, s-maxage=0'
OUT = 'public, max-age=0, s-maxage=14400'
W1 = {'startMin': 480, 'endMin': 1020, 'inTtl': 0, 'outTtl': 14400}      # 08:00-17:00
W2 = {'startMin': 600, 'endMin': 660, 'inTtl': 30, 'outTtl': 7200}       # 10:00-11:00


def at(h, m, s=0, ms=0):
    return calendar.timegm((2026, 10, 10, h, m, s)) + ms / 1000.0


def ev(status='200', headers=None, uri='/page'):
    return {'Records': [{'cf': {'request': {'uri': uri},
                                'response': {'status': status, 'statusDescription': 'x', 'headers': {} if headers is None else headers}}}]}


def cc(r):
    h = r.get('headers', {}).get('cache-control')
    return h[0]['value'] if h else None


def rule(path, w=W1):
    return dict(w, path=path)


class Harness:
    """A handler with a fake config source and a fake clock."""

    def __init__(self, text=CFG_TEXT, t=at(0, 30), fail=False, fail_exc=None):
        self.t, self.loads, self.text, self.fail, self.fail_exc = t, 0, text, fail, fail_exc
        self.handler = edge.make_handler(load_text=self.load, now=lambda: self.t)

    def load(self):
        self.loads += 1
        if self.fail:
            raise self.fail_exc or RuntimeError('AccessDenied for bucket secret-name')
        return self.text

    def run(self, **kw):
        return self.handler(ev(**kw))


class Logs:
    """Collects what the module logs."""

    def __enter__(self):
        self.lines = []
        self.patch = mock.patch.object(edge, '_log', self.lines.append)
        self.patch.start()
        return self.lines

    def __exit__(self, *a):
        self.patch.stop()


def pick(cfg, uri):
    with Logs():
        return edge.select_window(edge.parse_config(json.dumps(cfg)), uri)


class Window(unittest.TestCase):
    def test_inside_window_uses_inttl(self):
        self.assertEqual(cc(Harness(t=at(14, 30)).run()), IN)

    def test_outside_window_outttl_capped_by_time_to_next_opening(self):
        cases = [(at(0, 0), 14400), (at(0, 30), 14400), (at(8, 59), 14400), (at(9, 0), 14400), (at(10, 0), 10800),
                 (at(12, 0), 3600), (at(12, 59), 60), (at(18, 0), 14400), (at(18, 1), 14400), (at(23, 59), 14400)]
        for t, ttl in cases:
            self.assertEqual(cc(Harness(t=t).run()), 'public, max-age=0, s-maxage=%d' % ttl, t)

    def test_boundaries_start_inclusive_end_exclusive_seconds_precision(self):
        f = edge.cache_control_for
        self.assertEqual(f(CFG, at(12, 59, 58)), 'public, max-age=0, s-maxage=2')
        self.assertEqual(f(CFG, at(12, 59, 59)), 'public, max-age=0, s-maxage=1')   # 1 s before the opening
        self.assertEqual(f(CFG, at(13, 0, 0)), IN)                                   # startMin itself is inside
        self.assertEqual(f(CFG, at(17, 59, 59)), IN)                                 # last second of the window
        self.assertEqual(f(CFG, at(18, 0, 0)), OUT)                                  # endMin itself is outside

    def test_milliseconds_remaining_time_is_floored(self):
        f = edge.ttl_seconds_for
        self.assertEqual(f(CFG, at(12, 59, 58, 500)), 1)   # 1.5 s left -> 1
        self.assertEqual(f(CFG, at(12, 59, 59, 500)), 0)   # 0.5 s left -> 0, not cached
        self.assertEqual(f(CFG, at(13, 0, 0, 0)), 0)       # inside, inTtl 0

    def test_after_the_close_the_cap_is_tomorrows_opening(self):
        c = {'startMin': 780, 'endMin': 1080, 'inTtl': 0, 'outTtl': 86400}
        self.assertEqual(edge.ttl_seconds_for(c, at(18, 0, 0)), 86400 - 18 * 3600 + 13 * 3600)   # 19 h
        self.assertEqual(edge.ttl_seconds_for(c, at(23, 59, 59)), 1 + 13 * 3600)
        self.assertEqual(edge.ttl_seconds_for(c, at(0, 0, 0)), 13 * 3600)

    def test_midnight_wrap(self):
        early = {'startMin': 0, 'endMin': 60, 'inTtl': 0, 'outTtl': 14400}
        self.assertEqual(edge.ttl_seconds_for(early, at(0, 0, 0)), 0)
        self.assertEqual(edge.ttl_seconds_for(early, at(1, 0, 0)), 14400)
        self.assertEqual(edge.ttl_seconds_for(early, at(23, 59, 59)), 1)    # 1 s to tomorrow's 00:00 opening
        late = {'startMin': 1200, 'endMin': 1440, 'inTtl': 0, 'outTtl': 14400}
        self.assertEqual(edge.ttl_seconds_for(late, at(19, 59, 59)), 1)
        self.assertEqual(edge.ttl_seconds_for(late, at(23, 59, 59)), 0)     # still inside
        self.assertEqual(edge.ttl_seconds_for(late, at(0, 0, 0)), 14400)

    def test_cap_never_negative_or_nan_and_smaller_outttl_wins(self):
        f = edge.ttl_seconds_for
        self.assertEqual(f(dict(CFG, outTtl=30), at(12, 0, 0)), 30)
        self.assertEqual(f(dict(CFG, outTtl=0), at(12, 0, 0)), 0)
        self.assertEqual(f(dict(CFG, startMin=float('nan')), at(12, 0, 0)), 0)
        self.assertEqual(f(dict(CFG, outTtl=float('nan')), at(12, 0, 0)), 0)
        self.assertEqual(f(dict(CFG, inTtl=-5), at(14, 0, 0)), 0)
        self.assertEqual(f(dict(CFG, inTtl=60), at(14, 0, 0)), 60)

    def test_cap_is_computed_per_invocation_with_the_config_cached(self):
        h = Harness(t=at(12, 59, 0))
        self.assertEqual(cc(h.run()), 'public, max-age=0, s-maxage=60')
        h.t = at(12, 59, 20)
        self.assertEqual(cc(h.run()), 'public, max-age=0, s-maxage=40')
        h.t = at(12, 59, 29)
        self.assertEqual(cc(h.run()), 'public, max-age=0, s-maxage=31')
        self.assertEqual(h.loads, 1, 'one S3 read for all three (config cached 30 s)')

    def test_non_zero_inttl_is_used_as_given(self):
        self.assertEqual(edge.cache_control_for(dict(CFG, inTtl=60), at(14, 0)), 'public, max-age=0, s-maxage=60')

    def test_window_opens_without_a_config_reload(self):
        h = Harness(t=at(12, 59, 50))
        self.assertEqual(cc(h.run()), 'public, max-age=0, s-maxage=10')
        h.t = at(13, 0, 5)
        self.assertEqual(cc(h.run()), IN)
        self.assertEqual(h.loads, 1)


class Responses(unittest.TestCase):
    def test_error_statuses_are_not_rewritten(self):
        h = Harness(t=at(0, 30))
        for status in ['400', '404', '500', '503', 500]:
            r = h.run(status=status, headers={'cache-control': [{'key': 'Cache-Control', 'value': 'origin-value'}]})
            self.assertEqual(cc(r), 'origin-value', str(status))
        self.assertEqual(h.loads, 0, 'errors do not even read the config')

    def test_only_200_203_204_206_are_rewritten(self):
        h = Harness(t=at(0, 30))
        for status in ['200', '203', '204', '206', 200]:
            self.assertEqual(cc(h.run(status=status)), OUT, str(status))

    def test_redirects_304_and_other_statuses_are_left_untouched(self):
        h = Harness(t=at(0, 30))
        for status in ['201', '205', '301', '302', '304']:
            self.assertIsNone(cc(h.run(status=status)), status)
        self.assertEqual(h.loads, 0)

    def test_origin_private_no_store_no_cache_left_untouched(self):
        for v in ['private', 'no-store', 'no-cache', 'public, no-cache', 'max-age=0, No-Store', 'private, max-age=60', 'no-cache="set-cookie"']:
            r = Harness(t=at(0, 30)).run(headers={'cache-control': [{'key': 'Cache-Control', 'value': v}]})
            self.assertEqual(cc(r), v, v)

    def test_a_cache_control_header_that_is_not_a_list_is_left_alone(self):
        for bad in ['public', {'key': 'Cache-Control', 'value': 'public'}, 5]:
            r = Harness(t=at(0, 30)).run(headers={'cache-control': bad})
            self.assertEqual(r['headers']['cache-control'], bad, repr(bad))

    def test_origin_set_cookie_left_untouched(self):
        r = Harness(t=at(0, 30)).run(headers={'set-cookie': [{'key': 'Set-Cookie', 'value': 'a=b'}]})
        self.assertIsNone(cc(r))

    def test_harmless_origin_cache_control_is_replaced_and_lookalikes_do_not_count(self):
        for v in ['public, max-age=60', 'max-age=0', 'x-private-ish=1', 'privately=1']:
            r = Harness(t=at(0, 30)).run(headers={'cache-control': [{'key': 'Cache-Control', 'value': v}]})
            self.assertEqual(cc(r), OUT, v)
        self.assertFalse(edge.origin_forbids_shared(None))

    def test_other_response_headers_are_kept(self):
        r = Harness().run(headers={'content-type': [{'key': 'Content-Type', 'value': 'text/plain'}]})
        self.assertEqual(r['headers']['content-type'][0]['value'], 'text/plain')


class Failures(unittest.TestCase):
    def test_s3_failure_gives_fallback_never_a_long_ttl_and_no_leak(self):
        with Logs() as logs:
            r = Harness(t=at(0, 30), fail=True).run()
        self.assertEqual(cc(r), edge.FALLBACK_CACHE_CONTROL)
        self.assertEqual(edge.FALLBACK_CACHE_CONTROL, IN)
        self.assertTrue(logs)
        self.assertNotIn('secret-name', '\n'.join(logs), 'error message text must not be logged')

    def test_botocore_style_error_logs_only_the_error_code(self):
        class ClientError(Exception):
            response = {'Error': {'Code': 'NoSuchKey', 'Message': 'The key bhc-secret does not exist'}}
        with Logs() as logs:
            r = Harness(t=at(0, 30), fail=True, fail_exc=ClientError('bhc-secret')).run()
        self.assertEqual(cc(r), IN)
        self.assertEqual(logs, ['config read failed (NoSuchKey), using fallback'])

    def test_bad_json_wrong_shape_and_a_bad_default_all_give_the_fallback(self):
        def w(**o):
            return json.dumps({'default': dict(CFG, **o)})
        bad = ['not json', '', 'null', '[]', '"x"', '{}', '{"rules":"x"}', '{"rules":{}}',
               w(startMin=1080, endMin=780), w(startMin=780, endMin=780), w(startMin=-1), w(endMin=1441), w(outTtl=-5),
               w(outTtl=31536001), w(outTtl='14400'), w(inTtl=1.5), w(outTtl=True),
               '{"default": {"startMin": 780, "endMin": 1080, "inTtl": 0}}',
               '{"default": {"startMin": NaN, "endMin": 1080, "inTtl": 0, "outTtl": 5}}']
        for text in bad:
            with Logs():
                r = Harness(text=text, t=at(0, 30)).run()
            self.assertEqual(cc(r), edge.FALLBACK_CACHE_CONTROL, text)
        with Logs():
            self.assertIsNotNone(edge.parse_config(CFG_TEXT))
            self.assertIsNotNone(edge.parse_config(json.dumps({'default': dict(CFG, outTtl=5.0)})), '5.0 is the integer 5, as in JSON.parse')

    def test_config_cached_30s_then_read_again(self):
        h = Harness(t=at(0, 30, 0))
        h.run()
        h.t = at(0, 30, 29)
        h.run()
        self.assertEqual(h.loads, 1)
        h.text = json.dumps({'default': dict(CFG, outTtl=60)})
        h.t = at(0, 30, 31)
        self.assertEqual(cc(h.run()), 'public, max-age=0, s-maxage=60')
        self.assertEqual(h.loads, 2)

    def test_after_expiry_a_failing_read_gives_the_fallback_not_the_old_long_ttl(self):
        h = Harness(t=at(0, 30, 0))
        self.assertEqual(cc(h.run()), OUT)
        h.fail = True
        h.t = at(0, 30, 10)
        self.assertEqual(cc(h.run()), OUT, 'still inside the 30 s memory cache')
        h.t = at(0, 30, 31)
        with Logs():
            self.assertEqual(cc(h.run()), edge.FALLBACK_CACHE_CONTROL)

    def test_a_failure_is_remembered_a_few_seconds_then_s3_is_tried_again(self):
        h = Harness(t=at(0, 30, 0), fail=True)
        with Logs():
            h.run()
            h.t = at(0, 30, 3)
            h.run()
        self.assertEqual(h.loads, 1)
        h.fail = False
        h.t = at(0, 30, 6)
        self.assertEqual(cc(h.run()), OUT)
        self.assertEqual(h.loads, 2)

    def test_the_handler_never_raises(self):
        h = Harness()
        self.assertEqual(h.handler({}), {})
        self.assertEqual(h.handler({'Records': []}), {})
        r = h.handler({'Records': [{'cf': {'response': {'status': 'x'}}}]})
        self.assertEqual(r, {'status': 'x'})
        r = h.handler({'Records': [{'cf': {'response': {'status': '200', 'headers': None}}}]})
        self.assertEqual(cc(r), edge.FALLBACK_CACHE_CONTROL, 'no request uri: matches nothing, fail safe')
        r = h.handler(ev(headers=None, uri='/ok'))
        self.assertEqual(cc(r), OUT)


class S3Client(unittest.TestCase):
    def setUp(self):
        self._client, self._factory = edge._client, edge.S3_CLIENT_FACTORY
        edge._client = None

    def tearDown(self):
        edge._client, edge.S3_CLIENT_FACTORY = self._client, self._factory

    @staticmethod
    def fake(body=b'{}', error=None):
        calls = []

        class Body:
            def read(self, n=-1):
                calls.append(('read', n))
                return body if n < 0 else body[:n]

        class Client:
            def get_object(self, **kw):
                calls.append(('get_object', kw))
                if error:
                    raise error
                return {'Body': Body()}
        return Client(), calls

    def test_the_real_loader_reads_the_baked_in_object_through_the_injected_client(self):
        client, calls = self.fake(('﻿' + CFG_TEXT).encode('utf-8'))
        edge.S3_CLIENT_FACTORY = lambda: client
        text = edge.load_from_s3()
        self.assertEqual(calls[0], ('get_object', {'Bucket': edge.CONFIG_BUCKET, 'Key': edge.CONFIG_KEY}))
        self.assertEqual(calls[1], ('read', edge.MAX_CONFIG_BYTES + 1), 'never reads more than the limit plus one byte')
        self.assertIsNotNone(edge.parse_config(text), 'a BOM in front of the JSON is ignored')

    def test_the_client_is_created_once_per_container(self):
        client, _ = self.fake()
        made = []
        edge.S3_CLIENT_FACTORY = lambda: made.append(1) or client
        edge.load_from_s3()
        edge.load_from_s3()
        self.assertEqual(len(made), 1)

    def test_the_real_handler_with_a_fake_client_end_to_end(self):
        client, _ = self.fake(json.dumps({'rules': [rule('/a/*', W1)]}).encode())
        edge.S3_CLIENT_FACTORY = lambda: client
        h = edge.make_handler(load_text=edge.load_from_s3, now=lambda: at(0, 30))
        self.assertEqual(cc(h(ev(uri='/a/x'))), OUT)
        self.assertEqual(cc(h(ev(uri='/zzz'))), IN)

    def test_a_non_utf8_body_gives_the_fallback(self):
        client, _ = self.fake(b'\xff\xfe\x00{')
        edge.S3_CLIENT_FACTORY = lambda: client
        h = edge.make_handler(load_text=edge.load_from_s3, now=lambda: at(0, 30))
        with Logs() as logs:
            self.assertEqual(cc(h(ev())), IN)
        self.assertEqual(logs, ['config read failed (UnicodeDecodeError), using fallback'])

    def test_boto3_missing_the_function_still_answers_with_s_maxage_0_and_logs_one_word(self):
        try:
            import boto3  # noqa: F401
            self.skipTest('boto3 is installed here: this path cannot be exercised')
        except ImportError:
            pass
        with Logs() as logs:
            r = edge.lambda_handler(ev(uri='/prices/a'))
        self.assertEqual(cc(r), edge.FALLBACK_CACHE_CONTROL)
        self.assertEqual(logs, ['s3-client-unavailable'])

    def test_a_loader_that_reports_the_client_unavailable_logs_only_that_word(self):
        with Logs() as logs:
            r = Harness(t=at(0, 30), fail=True, fail_exc=edge.S3ClientUnavailable('Cannot import boto3 from /var/task/x')).run()
        self.assertEqual(cc(r), IN)
        self.assertEqual(logs, ['s3-client-unavailable'])

    def test_the_timeouts_and_retries_are_configured(self):
        with open(os.path.join(HERE, '..', 'edge', 'index.py'), encoding='utf-8') as f:
            src = f.read()
        self.assertIn('connect_timeout=S3_TIMEOUT_SECONDS', src)
        self.assertIn('read_timeout=S3_TIMEOUT_SECONDS', src)
        self.assertIn("retries={'max_attempts': 0}", src)
        self.assertEqual(edge.S3_TIMEOUT_SECONDS, 1.5)


class PathRules(unittest.TestCase):
    def test_longest_matching_prefix_wins(self):
        cfg = {'rules': [rule('/a/*', W1), rule('/a/b/*', W2), rule('/*', dict(W1, outTtl=1))]}
        self.assertEqual(pick(cfg, '/a/b/c'), W2)
        self.assertEqual(pick(cfg, '/a/x'), W1)
        self.assertEqual(pick(cfg, '/zzz')['outTtl'], 1)
        self.assertEqual(pick({'rules': [rule('/a/b/*', W2), rule('/a/*', W1)]}, '/a/b/c'), W2, 'order in the file does not matter')

    def test_first_of_identical_patterns_wins(self):
        cfg = {'rules': [rule('/a/*', W1), rule('/a/*', W2)]}
        self.assertEqual(pick(cfg, '/a/x'), W1)

    def test_an_exact_path_beats_a_prefix(self):
        cfg = {'rules': [rule('/a/b/*', W1), rule('/a/b/c', W2)]}
        self.assertEqual(pick(cfg, '/a/b/c'), W2)
        self.assertEqual(pick(cfg, '/a/b/d'), W1)
        self.assertIsNone(pick({'rules': [rule('/a/b/c', W2)]}, '/a/b/c/'), 'exact means exact')

    def test_case_sensitive_and_prices_star_does_not_match_prices(self):
        cfg = {'rules': [rule('/prices/*', W1)]}
        self.assertIsNone(pick(cfg, '/Prices/x'))
        self.assertIsNone(pick(cfg, '/prices'))
        self.assertEqual(pick(cfg, '/prices/'), W1)

    def test_query_string_is_stripped_before_matching(self):
        cfg = {'rules': [rule('/a/b', W2), rule('/p/*', W1)]}
        self.assertEqual(pick(cfg, '/a/b?x=1&y=/p/z'), W2)
        self.assertEqual(pick(cfg, '/p/q?x=/a/b'), W1)

    def test_no_match_default_or_none(self):
        self.assertEqual(pick({'rules': [rule('/a/*', W1)], 'default': W2}, '/other'), W2)
        self.assertIsNone(pick({'rules': [rule('/a/*', W1)]}, '/other'))
        self.assertIsNone(pick({}, '/x'))

    def test_handler_no_match_and_no_default_gives_s_maxage_0(self):
        h = Harness(text=json.dumps({'rules': [rule('/a/*')]}), t=at(0, 30))
        self.assertEqual(cc(h.run(uri='/b/x')), edge.FALLBACK_CACHE_CONTROL)
        self.assertEqual(cc(h.run(uri='/a/x')), OUT)   # 00:30 -> 08:00 is 27000 s away, capped by outTtl 14400

    def test_uri_variants_are_never_cached_not_even_through_the_default(self):
        cfg = {'rules': [rule('/prices/*', W1)], 'default': W2}
        for u in ['//prices/a', '/prices//a', '/./prices/a', '/x/../prices/a', '/prices/.', '/prices/..', '/prices/a/.', '/%70rices/a',
                  '/prices%2fa', '/prices/%61', '/prices/..\\a', '/prices\\..\\x', '/prices/a\\', '', 'prices/a', '/x/./y', '/x/../y', '/x//y', '/100%']:
            self.assertIsNone(pick(cfg, u), repr(u))
            self.assertIsNone(pick(cfg, u + '?q=1'), repr(u + '?q=1'))
        h = Harness(text=json.dumps(cfg), t=at(0, 30))
        self.assertEqual(cc(h.run(uri='//prices/a')), edge.FALLBACK_CACHE_CONTROL)
        self.assertEqual(cc(h.run(uri='/%70rices/a')), edge.FALLBACK_CACHE_CONTROL)

    def test_other_unmatched_lookalikes_get_the_default(self):
        cfg = {'rules': [rule('/prices/*', W1)], 'default': W2}
        self.assertEqual(pick(cfg, '/Prices/a'), W2)
        self.assertEqual(pick(cfg, '/prices'), W2)
        self.assertEqual(pick(cfg, '/prices.html'), W2)
        self.assertIsNone(pick({'rules': [rule('/prices/*', W1)]}, '/Prices/a'))
        self.assertEqual(pick(cfg, '/prices/a.b..c/d'), W1, 'dots inside a name are not dot segments')

    def test_the_cap_is_applied_per_matched_rule_two_paths_at_the_same_moment(self):
        text = json.dumps({'rules': [
            {'path': '/prices/*', 'startMin': 660, 'endMin': 780, 'inTtl': 0, 'outTtl': 14400},
            {'path': '/rates/*', 'startMin': 780, 'endMin': 900, 'inTtl': 0, 'outTtl': 14400},
            {'path': '/rates/old/*', 'startMin': 1080, 'endMin': 1200, 'inTtl': 0, 'outTtl': 600}]})
        h = Harness(text=text, t=at(12, 0))
        self.assertEqual(cc(h.run(uri='/prices/x')), IN)
        self.assertEqual(cc(h.run(uri='/rates/x')), 'public, max-age=0, s-maxage=3600')
        self.assertEqual(cc(h.run(uri='/rates/old/x')), 'public, max-age=0, s-maxage=600')

    def test_bad_rules_are_skipped_good_ones_work_and_only_the_index_is_logged(self):
        hidden = '/secret-path-do-not-log/*'
        text = json.dumps({'rules': [
            rule('/ok/*'),                                              # 0 ok
            dict(rule(hidden), startMin=900, endMin=100),               # 1 bad window
            dict(W1, path='no-slash'),                                  # 2
            dict(W1, path='/a*b'),                                      # 3 star not at the end
            dict(W1, path='/a/**'),                                     # 4
            dict(W1, path=42),                                          # 5
            dict(W1, path='/x y'),                                      # 6 whitespace
            'junk', None,                                               # 7, 8
            {'path': '/ttl/*', 'startMin': 0, 'endMin': 10, 'inTtl': -1, 'outTtl': 5},          # 9
            {'path': '/ttl2/*', 'startMin': 0, 'endMin': 10, 'inTtl': 0, 'outTtl': 86401},      # 10
            dict(W1, path='/ok2')]})                                    # 11 ok
        with Logs() as logs:
            cfg = edge.parse_config(text)
        self.assertEqual([r['path'] for r in cfg['rules']], ['/ok/*', '/ok2'])
        for i in range(1, 11):
            self.assertIn('rule %d skipped (malformed)' % i, logs)
        self.assertNotIn('rule 0 skipped (malformed)', logs)
        self.assertNotIn('rule 11 skipped (malformed)', logs)
        joined = '\n'.join(logs)
        self.assertNotIn('secret-path', joined)
        self.assertNotIn('no-slash', joined)

    def test_a_malformed_default_is_skipped_but_the_rules_still_work(self):
        h = Harness(text=json.dumps({'rules': [rule('/a/*')], 'default': {'startMin': 5}}), t=at(0, 30))
        with Logs():
            self.assertEqual(cc(h.run(uri='/a/x')), OUT)
            self.assertEqual(cc(h.run(uri='/zzz')), edge.FALLBACK_CACHE_CONTROL)

    def test_the_whole_config_is_cached_once_for_different_paths(self):
        h = Harness(text=json.dumps({'rules': [rule('/a/*'), rule('/b/*', W2)]}), t=at(0, 30))
        for u in ('/a/1', '/b/1', '/c/1'):
            h.run(uri=u)
        self.assertEqual(h.loads, 1)

    def test_config_over_256kb_or_more_than_1000_rules_is_refused_and_only_config_too_large_is_logged(self):
        def many(n):
            return json.dumps({'rules': [rule('/p%d/*' % i) for i in range(n)]})
        with Logs() as logs:
            self.assertIsNotNone(edge.parse_config(many(1000)))
            self.assertIsNone(edge.parse_config(many(1001)))
            big = json.dumps({'default': W1, 'pad': 'x' * (256 * 1024)})
            self.assertIsNone(edge.parse_config(big))
            self.assertEqual(cc(Harness(text=big, t=at(0, 30)).run()), edge.FALLBACK_CACHE_CONTROL)
        self.assertIn('config too large', logs)
        self.assertFalse([l for l in logs if '/p1/' in l or 'xxxx' in l], 'content is never logged')

    def test_a_utf8_byte_order_mark_in_front_of_the_json_is_ignored(self):
        self.assertEqual(len(edge.parse_config('﻿' + json.dumps({'rules': [rule('/a/*')]}))['rules']), 1)

    def test_ttls_above_86400_make_the_rule_malformed_86400_is_fine(self):
        with Logs() as logs:
            cfg = edge.parse_config(json.dumps({'rules': [rule('/a/*', dict(W1, outTtl=86400)), rule('/b/*', dict(W1, outTtl=86401)),
                                                          rule('/c/*', dict(W1, inTtl=86401))]}))
        self.assertEqual([r['path'] for r in cfg['rules']], ['/a/*'])
        self.assertIn('rule 1 skipped (malformed)', logs)
        self.assertIn('rule 2 skipped (malformed)', logs)

    def test_duplicate_math_helpers_do_not_leak_nan(self):
        self.assertFalse(math.isnan(edge.ttl_seconds_for(dict(CFG, endMin=float('nan')), at(14, 0))))


if __name__ == '__main__':
    unittest.main()
