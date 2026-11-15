# The foundation's till

## What it is for

Every LOVEH market pays a protocol fee: 10 percent of the interest its borrowers pay, in the coin
the market lends. The market sends that fee to one address, the fee recipient, which the market's
factory fixed when the factory was created. Nothing can change it afterwards: not in the factory, not
in any market, not by anyone.

A fixed address is right for the markets, but the party that is meant to receive the fee may change
over the years, and an address that nobody can move is also an address that nobody can recover if
its holder is lost. The foundation's till solves both. It is a small contract that stands as the fee
recipient. The markets pay the till for ever. The till knows one party, its beneficiary, who alone
can take out what is in it, and who can hand the till over to a successor. So the party that
receives the fee can change without touching any factory or any market.

The till holds coins and nothing else. It has no owner, no administrator, no pause, no upgrade. The
only authority in it is the beneficiary of the moment.

## Who may do what

The till has two readable facts, which anyone may read:

- `beneficiary`: the one party that can collect from the till and name a successor.
- `successor`: the party named to take the till over, or nobody.

And three actions:

- `collect(asset)`: the beneficiary, and only the beneficiary, sends the till's whole balance of one
  coin to itself. Anyone else is refused. A coin of which the till holds nothing is refused too. Each
  call moves one coin; a till holding several coins is emptied one coin at a time.
- `nameSuccessor(successor)`: the beneficiary, and only the beneficiary, names the party that may
  take over. Naming a new party replaces the earlier name; naming nobody clears it. The beneficiary
  cannot name itself.
- `acceptHandover()`: the named successor, and only the named successor, takes the till over. When
  no successor is named, everybody is refused.

Nobody but the beneficiary can move anything out of the till, and nothing can go anywhere but to the
beneficiary of that moment. A stranger, a market, the deployer, a former beneficiary, a named but
not yet accepted successor: none of them can take a single coin.

Every action leaves a record: `Collected` (which coin, to whom, how much the till sent),
`SuccessorNamed` (who named whom) and `HandedOver` (from whom to whom).

## The two steps of a handover, and why there are two

A handover takes two steps by two different parties:

1. The beneficiary names the successor.
2. The successor accepts. At that moment the successor becomes the beneficiary and the name is
   cleared.

Until the second step, nothing has changed: the beneficiary is still the beneficiary, still collects,
and may still change its mind, name someone else or clear the name. After the second step the
earlier beneficiary has no power left: it can neither collect nor name anyone.

There are two steps because a handover in one step would be irreversible the instant it was sent,
and a single wrong character in the address would send the till, and every fee the markets will
ever pay, to an address that nobody controls. With two steps, the successor proves that it controls
its address by accepting from it. A mistaken name is harmless: nobody can accept from an address
nobody controls, and the beneficiary simply replaces or clears the name.

## Coins that arrive before and after a handover

The till does not keep accounts per beneficiary. It holds balances, and whoever is the beneficiary
when `collect` is called receives the whole balance of the coin collected. So:

- Coins that arrived before a handover and were not collected stay in the till and belong to
  whoever is the beneficiary when they are collected: after the handover, the new beneficiary.
- Coins that arrive after a handover are collected by the new beneficiary alone.
- The earlier beneficiary can collect nothing once the handover is accepted, whether the coins
  arrived before it or after it.

A beneficiary that wants what has accrued up to the handover simply collects before naming, or
before the successor accepts.

## What the till does with awkward coins

The till sends with the usual safe transfer and trusts the coin for the rest. A coin that takes a
fee on transfer delivers less than the till sent; the `Collected` record states what the till sent.
A coin that refuses to move (for instance one that has frozen the till or the beneficiary) makes
that collection fail and leaves the balance where it is, but it does not stop the till paying out
any other coin. A coin that calls back into the till while being sent cannot take anything twice:
`collect` is guarded against re-entry.

## The chain's own currency

The till never holds the chain's own currency. It has no function that accepts it, plainly or with
data: a transfer of the chain's currency to the till is refused and bounces back to the sender.
Only coins (ERC-20 balances) can be in the till, and only `collect` can move them out.
