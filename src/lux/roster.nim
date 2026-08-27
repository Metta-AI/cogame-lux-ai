## Join / auth / identities and the results document. Forked from
## coworld-ctf's `src/ctf/roster.nim`; `IdentityNames`, `slotIdentityIndex` and
## `cogAlias` are UNTOUCHED, so the two-name-space rule and its inherited
## privacy test apply here with no further change.
##
## TWO NAME SPACES. In game the sides are `RED-alpha` and `BLUE-alpha` and
## nothing else — prompts, observations, the ASCII maps and the feed's in-board
## lines carry only those. The seats' REAL policy and player names appear only
## in `results.names`, in the replay's join records, in the viewer's scorebug
## plates and on the endcard. A seat can never learn who it is playing.

import std/[json, strutils]

import directives, sim_types

const IdentityNames* = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
  ## Per-team identities, assigned by slot order within the team. With
  ## `teams: 2` and `cogsPerTeam: 1` only `alpha` is ever used, which is why
  ## the starter's alias machinery needs no edit at all.

const IdentityNameUnknown* = "?"

type
  Seat* = object
    ## One connected (or absent) side.
    slot*: int
    token*: string
    name*: string            ## the REAL policy name — spectator side only.
    policyLabel*: string     ## <= MaxPolicyLabelRunes; spectator side only.
    joined*: bool
    connected*: bool
    registered*: bool
    isLlm*: bool
    baseline*: string
    dead*: bool              ## never connected, or dropped and not back.

func teamForSlot*(slot: int): Team =
  Team(slot mod 2)

func slotIdentityIndex*(slot: int): int =
  ## The slot's rank among same-team slots. Derived, not stored, so it is
  ## stable across matches, reconnects and replays.
  (slot div 2) mod IdentityNames.len

func cogAlias*(slot: int): string =
  ## The side's ANONYMOUS in-game name — "RED-alpha". This is the only name a
  ## seat, a prompt or an observation ever sees.
  if slot < 0:
    return IdentityNameUnknown
  toUpperAscii(teamText(teamForSlot(slot))) & "-" &
    IdentityNames[slotIdentityIndex(slot)]

proc registerRecord*(
  seat: int, alias, policy, kind, baseline: string
): JsonNode =
  ## The REDACTED registration record. The seat's PROMPT is never written:
  ## only the policy label, the kind, and which baseline a scripted seat picked.
  %*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  }
