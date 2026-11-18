# The rate record

The rate record is the small contract that gives a LOVEH2 market its rate level. One record serves one
loan coin. It follows ten candidate lending protocols on other chains through readings that the AERKey
signer signs and anyone delivers. On each accepted reading it ranks the candidates by what is deposited
in them, names the three leaders, extends a history of the stated rates, and stores one figure: the
centre, the mean of the three leaders' average borrowing rates over the last 24 hours. The following
rate formula reads that figure on every touch of a market.

The record holds no value and moves no coin. It has no owner. The only authority is the signer, and the
signer changes only by a handover the signer itself signs, effective 72 hours later and executable for
72 hours after that, then void. Until a queued handover executes or its window closes, the signer, and
nobody else, may void it by a second signed instruction, so that a handover signed to a wrong address
need not complete. A void does not recover the record from a stolen key (see "Void" below). Nobody can
pause the record or set the centre by hand.

Every rate is a per-second rate scaled by 1e18, the unit the rate formulas use: a figure of 1e18 means
100 percent per second.

## The instructions

All three instructions are EIP-712 typed messages under the domain `AERKey`, version `1`, bound to the chain id
and to the record's address. A signature over anything else, or by anyone but the current signer, is
refused. The record publishes `readingDigest(reading)`, `rotateDigest(rotate)` and `voidDigest(void)`, the
exact digests the signer signs; no function accepts a raw digest.

### Reading

```
Reading(bytes32 id,uint64 asOf,uint256[10] deposits,uint256[10] rates,uint256 deadline)
```

| Field      | Meaning                                                                                   |
| ---------- | ----------------------------------------------------------------------------------------- |
| `id`       | A label unique across all instructions, forever. A second use is refused.                 |
| `asOf`     | The moment the signer took the reading, as a Unix time.                                   |
| `deposits` | For each of the ten candidates, in index order, the amount deposited in it. Used only to rank. |
| `rates`    | For each candidate, its borrowing rate per second scaled by 1e18.                         |
| `deadline` | The last Unix time at which the reading may be delivered. A deadline later than `asOf` plus one hour adds nothing, since the reading is stale by then (check 5 below). |

A fixed array is encoded as EIP-712 prescribes: the hash of its ten members' encodings laid end to end.

Delivered with `submitReading(reading, signature)` by anyone.

### Rotate

```
Rotate(bytes32 id,address next,uint256 deadline)
```

| Field      | Meaning                                                            |
| ---------- | ------------------------------------------------------------------ |
| `id`       | A label unique across all instructions, forever.                   |
| `next`     | The address that becomes the signer once the handover executes.    |
| `deadline` | The last Unix time at which the handover may be queued.            |

Delivered with `submitRotate(rotate, signature)` by anyone; executed later with `executeRotate(id)` by
anyone, from 72 hours (`ROTATE_DELAY`) after the block that queued it until 72 hours (`ROTATE_WINDOW`)
after that. A handover not executed within its window is void: `executeRotate` refuses it with
`Voided(id)` from the first second past the window, so a handover queued as a contingency, or abandoned
after a change of mind, does not stay executable by anyone for ever, to an address that may since have
been retired, lost or compromised. The `deadline` bounds only the queueing.

### Void

```
Void(bytes32 id,bytes32 handover,uint256 deadline)
```

| Field      | Meaning                                                            |
| ---------- | ------------------------------------------------------------------ |
| `id`       | A label unique across all instructions, forever.                   |
| `handover` | The `id` of the queued handover to void.                           |
| `deadline` | The last Unix time at which the void may be delivered.             |

Delivered with `submitVoid(void, signature)` by anyone, signed by the current signer. A voided handover
can never execute; nothing else about the record changes. Nobody but the signer can void a handover,
and nothing but execution, a void or the close of its window ends one, so a signer who has signed a
handover to a wrong address voids it within the 72 hours and, if need be, queues another. A handover
whose window has closed is void already, and a void of it is refused with `Voided(handover)`.

What a void does not do: it does not recover the record from a stolen key. A void is signed by the
same key as a handover, and it takes effect at once while a handover waits 72 hours. So whoever holds
a copy of the signer's key sees every handover the rightful signer queues and can void it within the
three days, every time; the rightful signer can do the same to the thief's. The outcome is a standing
stalemate: the signer never changes, and the thief keeps signing readings, which the record accepts
up to `maxRate`. The record offers nothing against that, by design: it has no second authority and no
owner. What bounds the harm of a stolen key is outside the record: the formula's ceiling and its
resting centre, and the markets' own terms. `test_void_doesNotRecoverARecordFromAStolenKey` in
`test/RateRecordRotation.t.sol` shows the stalemate.

## The checks, in order

Every instruction passes these three first, each refused with its own error:

1. The deadline is not past: refused with `Expired(deadline)` once the block's time is after it. At the
   deadline itself it is still accepted.
2. The id has not been used before, by either kind of instruction: refused with `AlreadyUsed(id)`.
3. The signature recovers to the current signer: otherwise `BadSignature()`. A malformed signature is a
   bad signature.

A reading then passes, in this order:

4. `asOf` is not after the block's time: `FromTheFuture(asOf)`.
5. `asOf` is not more than one hour (`MAX_AGE`) before the block's time: `Stale(asOf)`. At exactly an
   hour old the reading is still accepted. So a reading is delivered within the hour of its `asOf` or
   never, whatever its deadline says: it cannot be held back and delivered when its moment suits, nor
   dated back into a silence so as to rewrite the window at once. Of two readings outstanding together,
   delivering the later first still shuts the earlier out under check 6, but what can be shut out that
   way is at most an hour of history, and a silence counts at the last stated rates for a week at the
   most (see "A silence in the history" below).
6. If a reading was accepted before, `asOf` is at least 30 minutes after the last accepted `asOf`:
   `TooSoon(asOf, lastAsOf)`.
7. Every rate is at most the record's highest rate: `RateTooHigh(index, rate)`.
8. At least three candidates have deposits above zero: `TooFewLeaders()`.

A refused reading changes nothing at all: not the centre, not the leaders, not the history, not the id.

A handover then passes:

4. `next` is not the zero address: `ZeroAddress()`.

A void then passes:

4. `handover` names a queued handover: `NotQueued(handover)`.
5. That handover is still live: `Voided(handover)` if the signer voided it before, if another
   handover has executed since it was queued, or if its window has closed.

And `executeRotate(id)` checks:

1. The id names a queued handover: `NotQueued(id)`.
2. The handover is still live: `Voided(id)` if the signer voided it, if another handover has
   executed since it was queued, or if the block is past its window: `readyAt + ROTATE_WINDOW`, 72
   hours after it became ready. At the last second of the window it is still live. Every handover
   queued before the last executed one is void forever, including the executed one itself.
3. Its delay has passed: `NotReady(readyAt)` until 72 hours after the block in which it was queued.

## What an accepted reading does

1. The leaders are the three candidates with the largest deposits among those above zero, in rank
   order. A tie is won by the lower index. A candidate with nothing deposited is never a leader, whatever
   its rate.
2. The reading is stored with its `asOf`, its ten rates and ten running sums (below) in a ring of 64
   readings; the oldest is overwritten.
3. The centre becomes the sum of the three leaders' averages over the window, divided by three, rounded
   down. The first accepted reading has no span to average over: it starts the history and names the
   leaders, and the centre stays the initial centre. A reading that ends a silence of more than
   `STALE_AFTER` (7 days), by the block of its delivery against the last accepted `asOf`, does the same:
   it writes the rest into the history (see "A silence in the history" below), starts the history
   afresh and names the leaders, and the centre becomes the initial centre, where it stays until the
   next reading. The rates stated before such a silence are never averaged again.
4. The event `ReadingAccepted(id, asOf, leaders, centre)` is emitted.

## The averaging rule

A stated rate counts forward: from its own reading until the next one. The record keeps, for each
candidate, a running sum of rate times seconds. The running sum at reading `n` is the running sum at
reading `n-1` plus reading `n-1`'s rate multiplied by the seconds between the two readings. The first
reading's running sums are zero.

The average of a candidate at reading `n` is taken over the window ending at `asOf(n)` and starting 24
hours earlier, or at the first reading of the current history still kept if the history is shorter than
that: the first reading ever, or the latest reading that ended a silence of more than `STALE_AFTER`
(below). The running sum at the window's start is found from the latest stored reading at or before the
start, plus that reading's rate multiplied by the seconds from it to the start. The average is the
difference of the two running sums divided by the window's length.

Because a stated rate counts forward, a stretch of silence counts at the last stated rates, not at the
rates the next reading brings, for as long as the silence is shorter than `STALE_AFTER` (7 days). And
because the centre is a stored value, it never depends on the clock: with no new reading for any length
of time, the centre stays what it is. What a market is charged during such a silence is bounded by the
following formula while the silence is open, and by the rest the record writes into its history once a
reading ends it; and a silence of more than `STALE_AFTER` is not averaged at all: the reading that ends
it starts the history afresh, so the rates stated before it are dead for good. See "A silence in the
history" and "A stale record" below.

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

### A silence in the history

The stored centre does not rest of itself: readings move it and silence leaves it as it is. But the
following formula charges it only until the last reading's `asOf` is `STALE_AFTER` (7 days) old, and
the initial centre, the resting centre, after that. So that a reading which ends a silence cannot
re-price the silence, the rest is written into the history before the reading is. A reading accepted
in a block more than `STALE_AFTER` after the last accepted `asOf` first checkpoints the initial centre
at the moment the record went stale, `lastAsOf + STALE_AFTER`. The moment of the rest is never before
the last checkpoint, which is at most `MAX_AGE` (an hour) after the last `asOf`; the moment is fixed by
the last reading's `asOf` and the block of delivery, not by the resuming reading's `asOf`, which may
be a little before it. A reading delivered at the moment itself ends no silence. A stored centre that
is the initial centre already rests at nothing, and no checkpoint is made.

And so that the rates stated before the silence, dead for more than a week, are not put back in force
by the reading that ends it, that reading starts the history afresh, as the first reading ever did. Its
window would lie wholly inside the silence, and averaging it would make the dead rates the whole
centre; instead the reading is averaged over nothing: it names the leaders and is stored, with running
sums that carry on from the reading before it as every reading's do, but the stored centre becomes the
initial centre and stays there until the next reading, and the window of that reading and of every
later one reaches no further back than the resuming reading's `asOf`. The next reading, 30 minutes
later at the least, thus averages the resuming reading's rates alone over the time since it, exactly
as the second reading ever averages the first's. The rest written at the moment of staleness therefore
runs to the block of the reading after the resuming one, and no rate stated before a silence of more
than a week is ever charged after it. A reading that ends a silence makes no checkpoint of its own.

So `centreOver` over a span across a silence that a reading has since ended answers exactly what the
formula charged while the silence was open: the stored centre up to the moment of staleness, and the
initial centre from then to the block of the reading after the resuming one, from which that reading's
centre counts. A silence still open is not in the history; the formula prices it itself (see "A stale
record" below).

The following formula reads `centreOver(lastAccrual, now)` for the market that asks it, so a market
untouched for a week during which the centre rose is charged the old centre for the time before the
rise and the new one from the block of the rise. See "The following formula" below.

## Reading the record

| Function              | Answer                                                                          |
| --------------------- | ------------------------------------------------------------------------------- |
| `centre()`            | The stored centre; the initial centre before the second reading and after a reading that ends a silence of more than `STALE_AFTER`. Never reverts; never depends on the clock. |
| `centreOver(from, to)` | The mean of the centre over the span, weighted by time, from the checkpoints of its changes and of the rests of silences that readings have ended; the centre in force at `to` for a span of no length. Depends only on the history and its arguments. |
| `leaders()`           | The three leaders' indexes, in rank order, from the last accepted reading.      |
| `lastAsOf()`          | `asOf` of the last accepted reading; zero before any.                           |
| `readingCount()`      | How many readings have been accepted.                                           |
| `candidates()`        | The ten candidates' labels.                                                     |
| `signer()`            | The current signer.                                                             |
| `readingAt(position)` | One stored reading by its sequence number (0 is the first ever): its `asOf`, rates and running sums. Refused with `NotKept(position)` once overwritten or before it is made. |
| `readingDigest(r)`    | The digest the signer signs for a reading.                                      |
| `rotateDigest(r)`     | The digest the signer signs for a handover.                                     |
| `voidDigest(v)`       | The digest the signer signs for the voiding of a handover.                      |

## Every figure

| Figure           | Value                      | Kind                                                        |
| ---------------- | -------------------------- | ----------------------------------------------------------- |
| `CANDIDATES`     | 10                         | Constant                                                    |
| `LEADERS`        | 3                          | Constant                                                    |
| `WINDOW`         | 24 hours                   | Constant                                                    |
| `MIN_INTERVAL`   | 30 minutes                 | Constant                                                    |
| `MAX_AGE`        | 1 hour                     | Constant; the greatest age of a reading at delivery          |
| `HISTORY`        | 64 readings                | Constant; `HISTORY × MIN_INTERVAL` exceeds `WINDOW`, asserted at creation |
| `ROTATE_DELAY`   | 72 hours                   | Constant                                                    |
| `ROTATE_WINDOW`  | 72 hours                   | Constant; how long after becoming ready a handover may still be executed, then void |
| `STALE_AFTER`    | 7 days                     | Constant; the moment after the last `asOf` at which the record is stale; a reading that ends the silence rests the history at that moment and starts the history afresh, so the rates stated before the silence are never averaged again; the formula's figure, which must be the same |
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
and the slope above the target is strictly steeper than below it. `ratePerSecond` never reverts. The
formula reads five things of its record, `maxRate`, `initialCentre`, `centre`, `lastAsOf` and
`centreOver`, and its constructor asks each of them once and refuses, with `BadConfig()`, a record that
does not answer every one with a single word; so a contract of another shape cannot be made the record.
The constructor also reads the record's `STALE_AFTER` and refuses, with `BadConfig()`, a record whose
figure is not the formula's own: the record rests its history at that moment and the formula prices an
open silence from it, and the two must agree.

The check at creation is made once, and a contract that answered then may change afterwards: it may
revert, lose its code, or answer otherwise than a record does. So `ratePerSecond` reads the record by
guarded static calls, and treats a record that does not answer as a record, in the block of the call,
as a stale one: an answer that is not exactly one word (a revert, an account without code, two words),
or a `lastAsOf` wider than the uint64 a record stores, is charged at the resting centre, over the whole
span, until the record answers as a record again; a `centreOver` or `centre` that does not answer is
charged at the resting centre over its part of the span. The promise therefore holds over every record
a formula can be created on, whatever the record does after creation; a genuine `RateRecord` always
answers, and is read exactly as before. The ceiling, too, is bounded by the formula itself, below
2^192 as a genuine record's `maxRate` is, so the pricing of a span across the moment of staleness
cannot overflow whatever the record answers.

Which centre `c` is: the formula asks its caller for `lastAccrual()`, which every market answers, by a
static call that changes nothing. When the caller answers with a time before the block, `c` is the
record's `centreOver(lastAccrual, now)`, the mean of the centre over the time the market is about to
charge; a reading delivered while the market was untouched thus prices only the time after its
delivery. When the caller does not answer, answers with the wrong width, or answers with a time not
before the block, `c` is the record's `centre()` as it stands. The rate is linear in `c`, so the rate at
the mean centre is exactly the mean of the rates the parts of the span would have been charged on their
own.

A direct quote is not what a market is charged. The formula's answer depends on who asks: a market is
answered over its own span, while an account, a contract without `lastAccrual()` or an off-chain call
asking `ratePerSecond` directly is answered at the centre as it stands. The two differ whenever the
centre moved, or the record went stale, within the market's span. To learn what a market will be
charged, ask the market: its `loans()` and `loanOf()` price the span exactly as `accrue()` will. A
market reads the formula before it writes its last accrual, so its span always has its length; a
contract that happens to answer `lastAccrual()` of its own is answered over the span that answer names.

### A stale record

The record's centre is a stored figure: readings move it and silence leaves it as it is. Left alone,
a record whose readings had stopped, through a lost signer or a signer's silence, would have every
market charged its last centre for ever, a spike as much as a lull. The formula bounds that. It reads
the record's `lastAsOf`, the `asOf` of the last accepted reading, and once the block is more than
`STALE_AFTER` (7 days) past it, the centre charged is the resting centre, `restingCentre`: the record's
`initialCentre`, read once at creation and lowered to the ceiling if ever above it. At exactly seven
days the record's centre is still charged; a second later, the resting centre. While the silence is
open the record itself is not touched: `centre()` still answers the stored figure. A reading accepted
again makes the record fresh from the block of its delivery, but it starts the record's history afresh
(see "A silence in the history" above): the record's centre is then the initial centre, the very
resting centre, until the reading after it, so what is charged from the resumption is the resting
centre still, and then the centre the new readings make. The rates stated before the silence are not
charged again.

Over a span that crosses the moment the record went stale, a market is charged the record's mean
centre over the time before that moment and the resting centre over the time after it, each weighted
by its length, so the time already priced at the record's centre is not re-priced. Before any reading
`lastAsOf` is zero, so the record counts as stale and the resting centre is charged; that is the
initial centre, the very figure the record answers before its second reading, so the two agree.

Seven days is long enough for a lost signer to be replaced by a handover (72 hours) and for the new
signer's readings to begin, and short enough that no dead reading is charged for more than a week:
a reading is charged in full for at most a week of silence after its `asOf`, and the reading that
ends a longer silence does not average it again.

A silence that has ended. The formula prices a silence itself only while it is open, from the last
reading's `asOf`. Once a reading has resumed, `lastAsOf` has moved on and the formula can no longer
see the silence; what it sees instead is the record's history, into which the resuming reading wrote
the rest (see "A silence in the history" above). So a market untouched across a silence that a
reading has ended is charged, through `centreOver`, the record's centre up to the moment of
staleness, the resting centre from then to the block of the reading after the resuming one, and the
centre the new readings make after it: exactly what it would have been charged had it been touched
one block before the resuming reading, and then at the resting centre until the reading after it.
Nobody re-prices a silence by delivering the reading that ends it, no touch of the market during the
silence is needed to fix the rest, and the rates stated before the silence are never charged again.
(The formula's resting centre is the record's `initialCentre` lowered to the ceiling, and the record
rests at `initialCentre` itself; a record's `initialCentre` is at most its `maxRate`, the ceiling, so
the two are the same figure.)

| Figure              | Rule                                                       | Kind                                                   |
| ------------------- | ---------------------------------------------------------- | ------------------------------------------------------ |
| `record`            | not zero; answers `maxRate`, `initialCentre`, `centre`, `lastAsOf` and `centreOver`, each with one word, when asked at creation, and `STALE_AFTER` with the formula's own figure; read by guarded static calls afterwards, and charged as stale when it does not answer as a record | Set at creation; `ZeroRecord()`, `BadConfig()` |
| `ceiling`           | the record's `maxRate`, read once; above zero, below 2^192 | Set at creation; `BadConfig()` if zero or too wide     |
| `restingCentre`     | the record's `initialCentre`, read once, lowered to the ceiling if above it | Set at creation; `BadConfig()` if zero |
| `STALE_AFTER`       | 7 days; past it, by the last reading's `asOf`, the resting centre is charged; the record's `STALE_AFTER` must be the same | Constant |
| `targetUtilisation` | strictly between 0 and 1e18                                | Set at creation; `InvalidTarget()`                     |
| `floorFraction`     | below 1e18 (zero allowed: no rate at zero utilisation)     | Set at creation; `InvalidFloorFraction()`              |
| `fullMultiple`      | above zero; steeper above than below; `ceiling × fullMultiple × 1e18` must fit in 256 bits | Set at creation; `ZeroMultiple()`, `SlopeAboveNotSteeper()`, `BadConfig()` |
