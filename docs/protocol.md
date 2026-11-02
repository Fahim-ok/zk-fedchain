# ZK-FedChain round protocol

This note describes how the contracts and off-chain nodes interact in one
training round `r`. Function names refer to `contracts/interfaces/`.

## Roles

| Role | Who | Main calls |
|------|-----|-----------|
| Admin | Consortium governance (a multisig in practice) | `Registry.addMember`, `RoundManager.setConfig` |
| Client | Any staked member with private data | `submitUpdate`, `revealUpdate` |
| Aggregator | One staked member, picked by `RoundManager` each round | `postAggregate` |
| Challenger / voter | Any other staked member | `DisputeResolver.openChallenge`, `castVote`, `resolve` |
| Anyone | Keeper that moves deadlines forward | `startRound`, `advancePhase`, `finalizeRound` |

## Phases

```
None -> Commit -> Reveal -> Aggregate -> Challenge -> Finalized
                                            |
                                            +-> Disputed -> Finalized
```

| Phase | Ends when | What happens on exit |
|-------|-----------|----------------------|
| Commit | `commitDeadline` passes (`advancePhase`) | Round closes early if nobody submitted |
| Reveal | `revealDeadline` passes (`advancePhase`) | Clients that committed but did not reveal are slashed |
| Aggregate | aggregator calls `postAggregate`, or `aggregateDeadline` passes | On timeout the aggregator is slashed and the round closes |
| Challenge | `challengeDeadline` passes (`finalizeRound`) or a challenge is opened | Rewards paid, model hash recorded |
| Disputed | `DisputeResolver.resolve` after the voting deadline | Aggregate upheld -> normal settlement; overturned -> aggregator slashed, bond to challenger |

## Sequence

```mermaid
sequenceDiagram
    participant C as Client
    participant RM as RoundManager
    participant V as Groth16Verifier
    participant R as Registry
    participant I as IPFS
    participant A as Aggregator
    participant D as DisputeResolver

    Note over RM: startRound() picks aggregator, sets deadlines
    C->>C: LoRA fine-tune, quantize update, snarkjs proof
    C->>RM: submitUpdate(r, commitment, proof)
    RM->>V: verifyProof(proof, [commitment, B^2, r, sender])
    alt proof invalid
        RM->>R: slash(client, INVALID_PROOF)
    else proof valid
        RM->>R: lockStake(client)
    end
    C->>I: upload update file
    C->>RM: revealUpdate(r, CID, salt)
    A->>I: fetch revealed updates
    A->>A: re-check commitments, Multi-Krum
    A->>I: upload global adapter
    A->>RM: postAggregate(r, modelHash, CID, acceptedBitmap) + bond
    opt member disagrees
        D->>RM: markDisputed(r)
        Note over D: members re-run aggregation and vote
        D->>RM: resolveDispute(r, upheld, challenger)
    end
    RM->>R: adjustReputation(...)
    Note over RM: finalizeRound mints FCR rewards, refunds bond, records modelHash
```

## Penalties follow the evidence

| Event | Evidence | Penalty |
|-------|----------|---------|
| Proof fails `verifyProof` | Cryptographic, checked by the contract | Stake slashed (`invalidProofPenalty`) |
| Commitment never revealed | Checked by the contract | Stake slashed (`noRevealPenalty`) |
| Aggregator never posts | Checked by the contract | Stake slashed (`aggregatorTimeoutPenalty`) |
| Aggregate overturned by vote | Re-execution by members | Stake slashed + bond lost (`badAggregatePenalty`) |
| Update dropped by Multi-Krum | Statistical only | Reputation -1, no slashing |

## Why the public signals come from the contract

`submitUpdate` builds the verifier input as
`[commitment, normBoundSq, roundId, uint160(msg.sender)]`.
Only the commitment comes from the caller. Because the round id and the
sender address are inside the proof, a proof cannot be replayed in a later
round or submitted by a different client, and because the commitment is
fixed before any update is revealed, a free-rider cannot copy another
client's update.
