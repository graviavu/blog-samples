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
- Before it disables anything you must type `DISABLE <last 4 characters of the distribution id>`.
- Run it only with the person who owns the AWS account: it needs admin-level rights (CloudFormation read, CloudWatch alarm state, CloudFront update, Logs read) and it is a test of a production brake.
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
checks the site answers 200; sets **T0**; forces the requests alarm to ALARM with `set-alarm-state`; polls every 5 seconds
(default timeout 600 s, `TIMEOUT=900` to change) until the distribution reports `Enabled=false` and `Status=Deployed`; reads the alarm history and
the Lambda log lines since T0; optionally asks which minute the notification email arrived (UTC, `HH:MM`, Enter skips);
then re-enables with the same read-modify-write as the stack's `ReEnableCommand` (with `If-Match`), polls until `Enabled=true`
and `Deployed`, checks `SITE_URL` answers HTTP 200 and sets the alarm back to OK.
With `AlertOnly` it fires the alarm and checks for `ALERT_WAIT` seconds (default 120) that the distribution stays enabled.

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
2. `N=300 ./flood.sh` (dry run first with `--dry-run`). It refuses if `RequestsPer5Min` is not below N.
3. **Put `RequestsPer5Min` back** to its normal value (default 10000) the same way. Do not forget this: a low threshold trips on real visitors.

In `Disable` mode the script waits for the alarm to return to OK before restoring, otherwise the same busy 5-minute window would trip it again, so the site stays down a few minutes longer.

## Results

Each run writes `results-<UTC timestamp>.txt` and prints it. Lines look like:

```
TEST=enabled_false RESULT=PASS SECONDS=48 DETAIL="Enabled=false seen"
```

`RESULT` is `PASS`, `FAIL`, `INCONCLUSIVE` (could not decide, for example evidence not visible yet), `MEASURED` (a number to read, no threshold) or `SKIPPED`. `SECONDS` counts from T0 (the alarm set, or the first request in `flood.sh`) unless noted.

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
| `site_http_200` | the site answers 200 again |
| `alarm_reset` | the forced alarm was set back to OK (a real alarm is never touched) |
| `flood_sent`, `alarm_in_alarm`, `alarm_back_to_ok` | `flood.sh` only: requests sent, seconds until the alarm tripped on its own, seconds until it cleared |

### How to read the timing

`enabled_false` is your reaction time: the time the brake needs after an alarm. In the forced test it should be seconds to a minute.
`disable_deployed` is how long until users actually see the site down (typically a few minutes). In `flood.sh`, `alarm_in_alarm`
adds the CloudFront metric delay (about a minute) and the 5-minute alarm period, so expect roughly 5 to 10 minutes from the first request.
Compare with your damage per minute: that is how much a flood can cost before the brake bites.

## What is NOT covered

- **The budget path.** The monthly budget alert and its Lambda trigger are not exercised. Budgets only fire on a real alert.
- **Billing lag.** AWS cost data arrives hours late. This test shows the fast brake (alarms), not the slow one.
- **Real spend.** No money threshold is crossed. The bytes alarm is not tested either, only the requests alarm.
- Drift: after this test the distribution is back to Enabled, but a later update of the main blog stack would also re-enable a disabled one.

## Tests of the scripts themselves

`tests/run.sh` runs both scripts against a fake `aws` and `curl` (shell stubs in `tests/bin`): disable, alert-only, restore-only,
dry-run, an AWS error mid-run, Ctrl-C, `--no-auto-restore`, refusals, flood, redaction. No AWS account and no network needed.

```
./tests/run.sh
```

Needs bash 3.2 or newer, jq. The scripts are written to be shellcheck clean (not checked automatically here).
