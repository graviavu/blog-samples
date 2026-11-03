"""Unit test of the kill switch code inlined in cfn/app.yaml (ZipFile), against a fake boto3. Standard library only.

Run: python3 -I tests/py/test_kill_switch.py   (tests/run.sh runs it when python3 is installed)
"""
import json
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, '..', '..', 'cfn', 'app.yaml')


def kill_code():
    """The ZipFile block of KillFunction, without YAML: the lines after 'ZipFile: |' that are indented deeper."""
    lines = open(TEMPLATE, encoding='utf-8').read().split('\n')
    start = next(i for i, l in enumerate(lines) if l.strip() == 'ZipFile: |')
    indent = len(lines[start]) - len(lines[start].lstrip()) + 2
    out = []
    for l in lines[start + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) < indent:
            break
        out.append(l[indent:])
    return '\n'.join(out)


class DataNotFoundError(Exception):
    pass


class UnknownServiceError(DataNotFoundError):
    pass


class Fake:
    """Records calls; `fail` names the operations that raise; `no_lambda_web` makes boto3.client('lambda-web') unknown."""

    def __init__(self, fail=(), no_lambda_web=False, enabled=True):
        self.fail, self.no_lambda_web, self.enabled, self.calls = set(fail), no_lambda_web, enabled, []

    def client(self, name):
        if name == 'lambda-web' and self.no_lambda_web:
            raise UnknownServiceError('Unknown service: lambda-web')
        fake = self

        class C:
            def __getattr__(self, op):
                def call(**kw):
                    fake.calls.append((name, op, kw))
                    if op in fake.fail:
                        raise PermissionError(op)
                    if op == 'get_distribution_config':
                        return {'DistributionConfig': {'Enabled': fake.enabled}, 'ETag': 'E1'}
                    if op == 'list_access_keys':
                        return {'AccessKeyMetadata': [{'AccessKeyId': 'K1', 'Status': 'Active'}, {'AccessKeyId': 'K2', 'Status': 'Inactive'}]}
                    return {}
                return call
        return C()


def load(fake):
    boto3 = types.ModuleType('boto3')
    boto3.client = fake.client
    botocore = types.ModuleType('botocore')
    exc = types.ModuleType('botocore.exceptions')
    exc.DataNotFoundError = DataNotFoundError
    exc.UnknownServiceError = UnknownServiceError
    botocore.exceptions = exc
    sys.modules.update({'boto3': boto3, 'botocore': botocore, 'botocore.exceptions': exc})
    os.environ.update({'DIST_ID': 'D', 'USER_NAME': 'U', 'FU_NAME': 'F', 'WF_NAME': 'W', 'WF_ENDPOINT': 'live'})
    ns = {}
    exec(compile(kill_code(), 'kill_switch', 'exec'), ns)  # noqa: S102 - the template's own code, under test
    return ns['handler']


class KillSwitch(unittest.TestCase):
    def test_all_steps_work(self):
        f = Fake()
        out = load(f)({}, None)
        self.assertEqual(out, {'cloudfront': 'disabled', 'worker_keys': 'deactivated:1', 'function_url': 'reserved-concurrency-0', 'web_function': 'rate-limit-0'})
        ops = [c[1] for c in f.calls]
        self.assertIn('update_distribution', ops)
        self.assertIn(('lambda', 'put_function_concurrency', {'FunctionName': 'F', 'ReservedConcurrentExecutions': 0}), f.calls)

    def test_a_failed_essential_step_raises_with_every_result(self):
        f = Fake(fail={'put_function_concurrency'})
        with self.assertRaises(RuntimeError) as cm:
            load(f)({}, None)
        res = json.loads(str(cm.exception))
        self.assertEqual(res['function_url'], 'error:PermissionError')
        self.assertEqual(res['cloudfront'], 'disabled')       # the other steps still ran
        self.assertEqual(res['worker_keys'], 'deactivated:1')

    def test_each_essential_step_counts(self):
        for op in ('get_distribution_config', 'list_access_keys'):
            with self.subTest(op=op), self.assertRaises(RuntimeError):
                load(Fake(fail={op}))({}, None)

    def test_no_lambda_web_client_is_reported_not_raised_and_not_claimed_as_throttled(self):
        out = load(Fake(no_lambda_web=True))({}, None)
        self.assertEqual(out['web_function'], 'not-throttled:no-lambda-web-client')

    def test_a_failed_web_function_throttle_is_reported_but_does_not_raise(self):
        out = load(Fake(fail={'update_web_function_endpoint'}))({}, None)
        self.assertEqual(out['web_function'], 'error:PermissionError')

    def test_idempotent(self):
        out = load(Fake(enabled=False))({}, None)
        self.assertEqual(out['cloudfront'], 'already-disabled')


if __name__ == '__main__':
    unittest.main(verbosity=1)
