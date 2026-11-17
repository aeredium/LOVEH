# The rate record

The rate record is the small contract that gives a LOVEH2 market its rate level. One record serves one
loan coin. It follows ten candidate lending protocols on other chains through readings that the AERKey
signer signs and anyone delivers. On each accepted reading it ranks the candidates by what is deposited
in them, names the three leaders, extends a history of the stated rates, and stores one figure: the
centre, the mean of the three leaders' average borrowing rates over the last 24 hours. The following
rate formula reads that figure on every touch of a market.

The record holds no value and moves no coin. It has no owner. The only authority is the signer, and the
signer changes only by a handover the signer itself signs, effective 72 hours later. Nobody can pause the
record, suspend a handover, or set the centre by hand.

Every rate is a per-second rate scaled by 1e18, the unit the rate formulas use: a figure of 1e18 means
100 percent per second.

## The instructions

Both instructions are EIP-712 typed messages under the domain `AERKey`, version `1`, bound to the chain id
and to the record's address. A signature over anything else, or by anyone but the current signer, is
refused. The record publishes `readingDigest(reading)` and `rotateDigest(rotate)`, the exact digests the
signer signs; no function accepts a raw digest.

### Reading

```
Reading(bytes32 id,uint64 asOf,uint256[10] deposits,uint256[10] rates,uint256 deadline)
```

| Field      | Meaning                                                                                   |
| ---------- | ----------------------------------------------------------------------------------------- |
| `id`       | A label unique across both instructions, forever. A second use is refused.                |
| `asOf`     | The moment the signer took the reading, as a Unix time.                                   |
| `deposits` | For each of the ten candidates, in index order, the amount deposited in it. Used only to rank. |
| `rates`    | For each candidate, its borrowing rate per second scaled by 1e18.                         |
| `deadline` | The last Unix time at which the reading may be delivered.                                 |

A fixed array is encoded as EIP-712 prescribes: the hash of its ten members' encodings laid end to end.

Delivered with `submitReading(reading, signature)` by anyone.

### Rotate

```
Rotate(bytes32 id,address next,uint256 deadline)
```

| Field      | Meaning                                                            |
| ---------- | ------------------------------------------------------------------ |
| `id`       | A label unique across both instructions, forever.                  |
| `next`     | The address that becomes the signer once the handover executes.    |
| `deadline` | The last Unix time at which the handover may be queued.            |

Delivered with `submitRotate(rotate, signature)` by anyone; executed later with `executeRotate(id)` by
anyone.

## The checks, in order

Every instruction passes these three first, each refused with its own error:

1. The deadline is not past: refused with `Expired(deadline)` once the block's time is after it. At the
   deadline itself it is still accepted.
2. The id has not been used before, by either kind of instruction: refused with `AlreadyUsed(id)`.
3. The signature recovers to the current signer: otherwise `BadSignature()`. A malformed signature is a
   bad signature.

A reading then passes, in this order:

4. `asOf` is not after the block's time: `FromTheFuture(asOf)`.
5. If a reading was accepted before, `asOf` is at least 30 minutes after the last accepted `asOf`:
   `TooSoon(asOf, lastAsOf)`.
6. Every rate is at most the record's highest rate: `RateTooHigh(index, rate)`.
7. At least three candidates have deposits above zero: `TooFewLeaders()`.

A refused reading changes nothing at all: not the centre, not the leaders, not the history, not the id.

A handover then passes:

4. `next` is not the zero address: `ZeroAddress()`.

And `executeRotate(id)` checks:

1. The id names a queued handover: `NotQueued(id)`.
2. No other handover has executed since this one was queued: `Voided(id)`. Every handover queued before
   the last executed one is void forever, including the executed one itself.
3. Its delay has passed: `NotReady(readyAt)` until 72 hours after the block in which it was queued.

## What an accepted reading does

1. The leaders are the three candidates with the largest deposits among those above zero, in rank
   order. A tie is won by the lower index. A candidate with nothing deposited is never a leader, whatever
   its rate.
2. The reading is stored with its `asOf`, its ten rates and ten running sums (below) in a ring of 64
   readings; the oldest is overwritten.
3. The centre becomes the sum of the three leaders' averages over the window, divided by three, rounded
   down. The first accepted reading has no span to average over: it starts the history and names the
   leaders, and the centre stays the initial centre.
4. The event `ReadingAccepted(id, asOf, leaders, centre)` is emitted.

## The averaging rule

A stated rate counts forward: from its own reading until the next one. The record keeps, for each
candidate, a running sum of rate times seconds. The running sum at reading `n` is the running sum at
reading `n-1` plus reading `n-1`'s rate multiplied by the seconds between the two readings. The first
reading's running sums are zero.

The average of a candidate at reading `n` is taken over the window ending at `asOf(n)` and starting 24
hours earlier, or at the oldest reading still kept if the history is shorter than that. The running sum
at the window's start is found from the latest stored reading at or before the start, plus that reading's
rate multiplied by the seconds from it to the start. The average is the difference of the two running
sums divided by the window's length.

Because a stated rate counts forward, a stretch of silence counts at the last stated rates, not at the
rates the next reading brings. And because the centre is a stored value, it never depends on the clock:
with no new reading for any length of time, the centre stays what it is.

### A worked example

Take one leader, hourly readings, and rates written in percent a year for readability (the record holds
them per second, scaled by 1e18; the arithmetic is the same).

The leader is read at 5 percent at every hour from hour 0 to hour 24. At hour 24 the window is hours 0 to
24, the running sum over it is 5 × 24 hours, and the average is 5 percent.

At hour 25 the leader is read at 15 percent. Nothing has moved yet: the 15 percent counts forward from
hour 25, and the window at hour 25, hours 1 to 25, holds only the 5 percent readings. The average is still
5 percent.

At hour 26 the leader is read at 5 percent again. The window is hours 2 to 26. From hour 2 to hour 25 the
rate was 5 percent (23 hours); from hour 25 to hour 26 it was 15 percent (1 hour). The running sum over
the window is 5 × 23 + 15 × 1 = 130 hour-percent, and the average is 130 / 24 = 5.4167 percent, rounded
down in the record's integer arithmetic. The spike of 10 points for one hour moved this leader's average
by 10 / 24 points.

If the other two leaders stayed at 5 percent, the centre moved from 5 percent to (5.4167 + 5 + 5) / 3 =
5.1389 percent: the spike divided by 24 and by 3.

The spike hour stays in the window until 24 hours after it ended: at hour 49 the window is hours 25 to 49
and still holds it; at hour 50 the window is hours 26 to 50 and the average is 5 percent again.

## The centre over time

A market charges the whole time since its last accrual at the one rate the formula answers when the
market is next touched. A reading delivered in between moves the centre, and anyone may deliver one
at any moment up to its deadline. So that a reading prices only the time after its delivery, and never
the idle time before it, the record keeps a checkpoint for every change of the centre: the time of
the block that stored it, the centre from then on, and the integral of the centre over time from the
record's creation up to that block. A reading that leaves the centre unchanged makes no checkpoint.

`centreOver(from, to)` answers the mean of the centre over the span from `from` to `to`, weighted by
time, from those checkpoints: the difference of the integrals at the two ends divided by the span's
length, rounded down. Each centre counts from the block in which the reading that stored it was
delivered until the next change; what counts is the block of delivery, not the reading's `asOf`. Time
before the record's creation is not counted: a `from` earlier than that is raised to the creation. A
span of no length, or one ending before it starts, answers the centre in force at `to`. The answer
depends on nothing but the stored history and the two arguments; it never depends on the block.

The following formula reads `centreOver(lastAccrual, now)` for the market that asks it, so a market
untouched for a week during which the centre rose is charged the old centre for the time before the
rise and the new one from the block of the rise. See "The following formula" below.

## Reading the record

| Function              | Answer                                                                          |
| --------------------- | ------------------------------------------------------------------------------- |
| `centre()`            | The stored centre. Never reverts; never depends on the clock.                   |
| `centreOver(from, to)` | The mean of the centre over the span, weighted by time, from the checkpoints of its changes; the centre in force at `to` for a span of no length. Depends only on the history and its arguments. |
| `leaders()`           | The three leaders' indexes, in rank order, from the last accepted reading.      |
| `lastAsOf()`          | `asOf` of the last accepted reading; zero before any.                           |
| `readingCount()`      | How many readings have been accepted.                                           |
| `candidates()`        | The ten candidates' labels.                                                     |
| `signer()`            | The current signer.                                                             |
| `readingAt(position)` | One stored reading by its sequence number (0 is the first ever): its `asOf`, rates and running sums. Refused with `NotKept(position)` once overwritten or before it is made. |
| `readingDigest(r)`    | The digest the signer signs for a reading.                                      |
| `rotateDigest(r)`     | The digest the signer signs for a handover.                                     |

## Every figure

| Figure           | Value                      | Kind                                                        |
| ---------------- | -------------------------- | ----------------------------------------------------------- |
| `CANDIDATES`     | 10                         | Constant                                                    |
| `LEADERS`        | 3                          | Constant                                                    |
| `WINDOW`         | 24 hours                   | Constant                                                    |
| `MIN_INTERVAL`   | 30 minutes                 | Constant                                                    |
| `HISTORY`        | 64 readings                | Constant; `HISTORY × MIN_INTERVAL` exceeds `WINDOW`, asserted at creation |
| `ROTATE_DELAY`   | 72 hours                   | Constant                                                    |
| `candidates`     | ten non-zero, distinct labels | Set at creation; refused with `BadConfig()` otherwise    |
| `maxRate`        | above zero, below 2^192    | Set at creation; refused with `BadConfig()` otherwise. The bound keeps every running sum below 2^256 over any span a 64-bit `asOf` can name |
| `initialCentre`  | above zero, at most `maxRate` | Set at creation; refused with `BadConfig()` otherwise    |
| the first signer | a non-zero address         | Set at creation; refused with `BadConfig()` otherwise; changes only by a handover |

## The following formula

`FollowingRateFormula` takes the record's centre `c` (lowered to its ceiling, the record's `maxRate` read
once at creation, if ever above it) and answers, with `u` the utilisation and every figure scaled by 1e18:

- for `u` at or below the target: `rate = c × (floorFraction + (1e18 − floorFraction) × u / target) / 1e18`
- for `u` above the target: `rate = c + c × fullMultiple × (u − target) / (1e18 − target) / 1e18`

So the rate at the target is exactly the centre, at zero utilisation the centre times the floor fraction,
at full utilisation the centre times one plus the full multiple; it rises with utilisation everywhere,
and the slope above the target is strictly steeper than below it. `ratePerSecond` never reverts.

Which centre `c` is: the formula asks its caller for `lastAccrual()`, which every market answers, by a
static call that changes nothing. When the caller answers with a time before the block, `c` is the
record's `centreOver(lastAccrual, now)`, the mean of the centre over the time the market is about to
charge; a reading delivered while the market was untouched thus prices only the time after its
delivery. When the caller does not answer, answers with the wrong width, or answers with a time not
before the block, `c` is the record's `centre()` as it stands. The rate is linear in `c`, so the rate at
the mean centre is exactly the mean of the rates the parts of the span would have been charged on their
own.

| Figure              | Rule                                                       | Kind                                                   |
| ------------------- | ---------------------------------------------------------- | ------------------------------------------------------ |
| `record`            | a rate record, not zero                                    | Set at creation; `ZeroRecord()`                        |
| `ceiling`           | the record's `maxRate`, read once                          | Set at creation; `BadConfig()` if zero or too wide     |
| `targetUtilisation` | strictly between 0 and 1e18                                | Set at creation; `InvalidTarget()`                     |
| `floorFraction`     | below 1e18 (zero allowed: no rate at zero utilisation)     | Set at creation; `InvalidFloorFraction()`              |
| `fullMultiple`      | above zero; steeper above than below; `ceiling × fullMultiple × 1e18` must fit in 256 bits | Set at creation; `ZeroMultiple()`, `SlopeAboveNotSteeper()`, `BadConfig()` |
