# Test your CloudFront cost brake before you need it

**The problem.** A cost brake you never fired is a guess. You deployed alarms, an SNS topic and a Lambda that disables a
CloudFront distribution when traffic or cost explodes. Does the alarm really reach the Lambda? Does the distribution really
turn off, how fast, and does your restore procedure really bring the site back? This sample fires the brake on purpose,
measures each step in seconds, and puts the site back.

It tests a stack with: an SNS topic, a requests alarm and a bytes alarm, a Lambda that disables ONE distribution when
`ActionOnTrip=Disable`, and the outputs `AlarmNames`, `FunctionName` and `ReEnableCommand`. Nothing in this folder deploys anything.

## Safety, read first

- **With `ActionOnTrip=Disable` the site goes down for several minutes** (CloudFront needs time to propagate a disable, and again to propagate the enable). Run it when that is acceptable.
- The script restores the distribution at the end, and also on any error or Ctrl-C (unless you pass `--no-auto-restore`). If your session dies anyway, run `--restore-only`.
- **`--restore-only` can undo a REAL brake trip**, so it first shows the state of every stack alarm. If an alarm is in `ALARM` and this test did not set it (its state reason lacks `cost-brake-test`), or the state cannot be read, it stops and asks you to type `RESTORE <last 4 characters of the distribution id>`; `--force` skips the question. Check the alarm and your traffic before you do either. A trip by the monthly **budget** leaves no alarm in `ALARM`, so the guard cannot see it: check your email first.
- Before it disables anything you must type `DISABLE <last 4 characters of the distribution id>`.
- Run it only with the person who owns the AWS account: it is a test of a production brake. It does not need admin: use the minimum policy in "Minimum IAM permissions" below.
- **Do not paste raw output anywhere public.** The screen summary and results file are redacted (account ids, ARNs, distribution id, site host, `*.cloudfront.net` names, AWS error text), but that is a best effort. Read the results file before you share it.
- The script shows the state of the stack's alarms first, then refuses to start unless the site answers `EXPECT_CODE` (default 200), the requests alarm is `OK`, and the `SITE_URL` host is the distribution's own domain name or one of its aliases (a wildcard alias `*.example.com` matches exactly one more label, like `blog.example.com`). `SITE_URL` must be `https://` and must not contain `@`. If the site does not answer, **the brake may have tripped for real**: check the alarm before you restore anything. `--restore-only` only warns about the alias, because it re-enables the stack's `DistributionId`, not `SITE_URL`.
- Run it **inside tmux** (or `screen`) in CloudShell: a dropped browser tab then does not kill the run halfway through a disable (`tmux new -s brake`, and after a reconnect `tmux attach -t brake`; tmux also keeps the scrollback).
- **Do not pipe the output** (`./test-disable-enable.sh | tee log`). A Ctrl-C kills `tee` as well, and the restore messages then have nowhere to go. The script survives it (it ignores SIGPIPE and moves its exit messages to stderr, or to the terminal), but you may not see the restore. The `results-<UTC>.txt` file is your log. Before the real run, open a **fresh CloudShell tab** and run `./test-disable-enable.sh --restore-only` once (harmless when the site is already enabled) to prove the rescue path works from a clean session with your rights.
- Exit handling: Ctrl-C, SIGTERM and SIGHUP start the restore, and during the restore they are ignored (a second Ctrl-C does not interrupt it). It prints the restore command first, then resets our forced alarm, then re-enables the distribution. If the restore itself fails it is tried once more at exit.
- Safest path: first run it with the stack on `ActionOnTrip=AlertOnly` (nothing changes), then switch to `Disable` for the real test, then leave it on `Disable`.
- Only `us-east-1`. The script refuses any other region.
- No credentials are in the scripts. Account ids, ARNs, the distribution id and your site host are redacted from the screen summary and the results file.

## Run it in CloudShell

Open AWS CloudShell in **us-east-1** (it has the aws CLI, jq, curl). Copy this folder there (or `git clone` the repo), then:

```
cd cost-brake-test
export STACK_NAME=<your cost-protection stack name>
export SITE_URL=https://<your blog host>

./test-disable-enable.sh --dry-run          # prints every command, changes nothing
./test-disable-enable.sh                    # the real test
./test-disable-enable.sh --restore-only     # only if a run was cut off and the site is still down
```

What it does, in order: reads the stack (distribution id, ActionOnTrip, alarm names, function name) and says what will happen;
shows the alarm states; checks the site answers 200; sets **T0**; forces the requests alarm to ALARM with `set-alarm-state`; polls every 5 seconds
(up to `TIMEOUT`, 900 s: CloudFront often needs 5 to 15 minutes to reach `Deployed`) until the distribution reports `Enabled=false` and `Status=Deployed`; reads the alarm history and
the Lambda log lines since T0 (the log group is read from the function with `aws lambda get-function-configuration`, falling back to `/aws/lambda/<stack>-brake`; the function name in the stack output is auto-generated and is not the log group name); optionally asks which minute the notification email arrived (UTC, `HH:MM`, Enter skips);
then re-enables with the same read-modify-write as the stack's `ReEnableCommand` (with `If-Match`), polls until `Enabled=true`
and `Deployed`, and checks `SITE_URL` answers `EXPECT_CODE`. Before the restore it sets the alarm back to OK, but **only if the alarm's state reason carries this test's marker** (`cost-brake-test`); a real alarm is never reset.
With `AlertOnly` it fires the alarm and checks for `ALERT_WAIT` seconds (default 120) that the distribution stays enabled.

## Options (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `TIMEOUT` | 900 | seconds to wait for the distribution to change, in both scripts (CloudFront often needs 5 to 15 minutes to reach `Deployed`) |
| `POLL_INTERVAL` | 5 | seconds between polls |
| `ALERT_WAIT` | 120 | AlertOnly: seconds to watch that nothing changes |
| `LOG_TRIES` | 12 | tries (`POLL_INTERVAL` apart) to find the alarm history entry and the Lambda log line |
| `EMAIL_PROMPT_TIMEOUT` | 120 | seconds the optional "which minute did the email arrive" prompt waits |
| `EXPECT_CODE` | 200 | HTTP status of your healthy site after redirects (`curl -L`) |
| `ATTEMPTS` | 3 | forced-alarm attempts when the Lambda logs `not confirmed` (1 try and 2 retries), at most 5. Before each retry the requests alarm must be `OK` again; otherwise the run stops and restores nothing (it may be a real trip) |
| `LOG_CHECK_EVERY` | 30 | while polling the distribution, look for `not confirmed` in the Lambda log at most this often (a log group that does not exist yet is not an error) |
| `RETRY_PAUSE` | 10 | seconds between those attempts |
| `RESULTS_DIR` | `.` | where `results-<UTC>.txt` is written (mode 600, git-ignored) |
| `N`, `BATCH` | 300, 50 | `flood.sh` only. `N` at most 2000 and at most `3 x RequestsPer5Min + 100`; `BATCH` at most 50 |

## Optional: a real request burst (`flood.sh`)

`test-disable-enable.sh` forces the alarm state, so it does not prove that real traffic reaches the metric. `flood.sh` does:
it sends N requests (default 300) with curl in parallel batches, and measures request, metric, alarm, disable.

1. Lower the threshold below N. CloudFormation, the stack, Update, Use existing template, change parameter `RequestsPer5Min`
   (for example to `100`). CLI equivalent:
   ```
   aws cloudformation update-stack --region us-east-1 --stack-name "$STACK_NAME" --use-previous-template \
     --capabilities CAPABILITY_IAM --parameters ParameterKey=RequestsPer5Min,ParameterValue=100 \
     <ParameterKey=...,UsePreviousValue=true for every other parameter of the stack>
   ```
   The console is easier because it keeps the other parameters.
2. `N=300 ./flood.sh` (dry run first with `--dry-run`). It refuses if `RequestsPer5Min` is empty, not a number, or not below N, if N is more than `3 x RequestsPer5Min + 100`, or if the alarm is not `OK`. `SITE_URL` may contain a path (kept) and a query (dropped; the script adds `?cbt=...`).
3. **Put `RequestsPer5Min` back** to its normal value (default 10000) the same way. Do not forget this: a low threshold trips on real visitors.

In `Disable` mode the script waits for the alarm to return to OK before restoring, otherwise the same busy 5-minute window would trip it again, so the site stays down a few minutes longer.

## Results

Each run writes `results-<UTC timestamp>.txt` and prints it. Lines look like:

```
TEST=enabled_false RESULT=PASS SECONDS=48 DETAIL="Enabled=false seen"
```

`RESULT` is `PASS`, `FAIL`, `INCONCLUSIVE` (could not decide, for example evidence not visible yet, or the Lambda logged `not confirmed`; read the line), `MEASURED` (a number to read, no threshold), `SKIPPED`, or `OVERRIDDEN` (`--restore-only` restored although an alarm was in ALARM, after the phrase or `--force`). `SECONDS` counts from T0 (the alarm set, or the first request in `flood.sh`) unless noted.

Exit codes (both scripts):

| Code | Meaning |
|---|---|
| `0` | pass (in `AlertOnly` mode also when a line is `INCONCLUSIVE`) |
| `1` | at least one `FAIL`, or a refusal before anything changed (site not healthy, alarm not OK, host mismatch) |
| `2` | bad input (option, region, URL, number out of range) |
| `3` | the typed phrase did not match; nothing was changed |
| `4` | `Disable` mode: no `FAIL`, but at least one `INCONCLUSIVE`, so the brake was not proven. Read the lines and run again |
| `129`, `130`, `143` | stopped by SIGHUP, Ctrl-C or SIGTERM (the restore still ran unless `--no-auto-restore`) |

| TEST | Meaning |
|---|---|
| `alarm_set` | the requests alarm was forced to ALARM |
| `enabled_false` | seconds until the distribution config said `Enabled=false`: alarm, SNS, Lambda, update accepted |
| `disable_deployed` | seconds until `Status=Deployed` after the disable: the site is really off at the edge (about when users see errors) |
| `alertonly_stays_enabled` | AlertOnly: the distribution stayed enabled (SECONDS = how long it was watched) |
| `alarm_history` | seconds until CloudWatch logged the state change to ALARM |
| `lambda_log` | seconds until the Lambda wrote its "disabled" (or "AlertOnly: would disable") line, from the log timestamp |
| `email_minute` | seconds to the minute you typed for the email, resolution about one minute, depends on your reading |
| `restore_enabled`, `restore_deployed` | seconds for the restore to be accepted and to finish propagating |
| `site_http` | the site answers `EXPECT_CODE` again |
| `alarm_reset` | the forced alarm was set back to OK (a real alarm is never touched) |
| `restore_guard` | `--restore-only` only: restored although an alarm was in ALARM without this test's marker |
| `flood_sent`, `alarm_in_alarm`, `alarm_back_to_ok` | `flood.sh` only: requests sent, seconds until the alarm tripped on its own, seconds until it cleared |

### How to read the timing

`enabled_false` is your reaction time: the time the brake needs after an alarm. In the forced test it should be seconds to a minute.
`disable_deployed` is how long until users actually see the site down (typically a few minutes). In `flood.sh`, `alarm_in_alarm`
adds the CloudFront metric delay (about a minute) and the 5-minute alarm period, so expect roughly 5 to 10 minutes from the first request.
Compare with your damage per minute: that is how much a flood can cost before the brake bites.

### A forced alarm can revert: INCONCLUSIVE, not FAIL

`set-alarm-state` is a manual override. CloudWatch re-evaluates the alarm on its next period and can put it back to `OK` within about a minute. If that happens **before the Lambda's own check** (it logs `trigger not confirmed by AWS, nothing done`), the Lambda correctly does nothing and the distribution is not disabled. That is not a defect of the brake, but it looks like a failure. So when the Lambda log says `not confirmed`, the script forces the alarm again (up to `ATTEMPTS` times, at most 5, each time only if the alarm is `OK` again) and, if it still happens, reports `INCONCLUSIVE` with a hint instead of `FAIL` (exit code 4 in `Disable` mode). A `FAIL` with no `not confirmed` line in the log is a real finding. Only `flood.sh`, where the alarm trips by itself, tests the real path.

## Minimum IAM permissions

Not admin. Replace the placeholders (stack name, distribution id, alarm name and function name are in the stack and its outputs).
The log group is **not** derived from the function name: read it from the function and use that value:
`aws lambda get-function-configuration --region us-east-1 --function-name <function-name> --query LoggingConfig.LogGroup --output text`

```
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": "cloudformation:DescribeStacks",
    "Resource": "arn:aws:cloudformation:us-east-1:<account-id>:stack/<stack-name>/*" },
  { "Effect": "Allow", "Action": ["cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"],
    "Resource": "arn:aws:cloudfront::<account-id>:distribution/<distribution-id>" },
  { "Effect": "Allow", "Action": "cloudwatch:SetAlarmState",
    "Resource": "arn:aws:cloudwatch:us-east-1:<account-id>:alarm:<requests-alarm-name>" },
  { "Effect": "Allow", "Action": ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"], "Resource": "*" },
  { "Effect": "Allow", "Action": "lambda:GetFunctionConfiguration",
    "Resource": "arn:aws:lambda:us-east-1:<account-id>:function:<function-name>" },
  { "Effect": "Allow", "Action": "logs:FilterLogEvents",
    "Resource": "arn:aws:logs:us-east-1:<account-id>:log-group:<LoggingConfig.LogGroup value>:*" }
] }
```

The two CloudWatch read actions get their own statement on `*`: they only read alarm state and history, and resource-level
scoping of them is not reliable. The write action `SetAlarmState` stays limited to the requests alarm. The script reads all
stack alarms (requests and bytes) to show their state.

If the distribution uses **AWS WAF** or **Lambda@Edge**, `UpdateDistribution` sends the whole config back, and CloudFront may
check those associations with the caller's rights: for example `wafv2:GetWebACL` on the web ACL, or `lambda:GetFunction`
(and possibly `lambda:EnableReplication*`) on the associated function versions. If the restore fails with `AccessDenied`
naming such an action, add it read-only for that resource. The brake Lambda's own role already does this update, so its
policy is a good reference.

Only for the `flood.sh` threshold change (step 1 of the flood section, which you can also do in the console with another identity): `cloudformation:UpdateStack` on that stack plus the rights CloudFormation needs to update the stack's resources (including `iam:PassRole` and the IAM actions for the Lambda role, because `--capabilities CAPABILITY_IAM` is used). That is close to admin for that stack, so use a separate identity for it.

This policy was written from the AWS API names and was **not tested against a real account** (the scripts were developed against stubs only). Start with `--dry-run` and an `AlertOnly` run.

## What is NOT covered

- **The budget path.** The monthly budget alert and its Lambda trigger are not exercised. Budgets only fire on a real alert.
- **Billing lag.** AWS cost data arrives hours late. This test shows the fast brake (alarms), not the slow one.
- **Real spend.** No money threshold is crossed. The bytes alarm is not tested either, only the requests alarm.
- Drift: after this test the distribution is back to Enabled, but a later update of the main blog stack would also re-enable a disabled one.

## Tests of the scripts themselves

`tests/run.sh` runs both scripts against a fake `aws` and `curl` (shell stubs in `tests/bin`): disable, alert-only, restore-only,
dry-run, an AWS error mid-run, Ctrl-C, `--no-auto-restore`, refusals, flood and its guards, redaction. The stubs behave like the real stack where it matters:
an auto-generated function name, a log group that only exists under its real name (and only after the first Lambda run), alarm-history timestamps with `+05:30`, `-08:00` and `Z` offsets,
a forced alarm that reverts (`not confirmed`), a real trip during the retries, a stale ETag (`PreconditionFailed`), a non-OK alarm, a bytes alarm in a real ALARM, a wildcard alias,
a redirecting site, very long Lambda logs, an `Enabled` read that lags behind the update, and output piped into a reader that dies with the Ctrl-C. No AWS account and no network needed.

```
./tests/run.sh
```

Needs bash 3.2 or newer, and jq. The test run is verified on bash 3.2 (macOS). The scripts are not checked with shellcheck (it was not available).
