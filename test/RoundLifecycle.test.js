// Draft tests for the ZK-FedChain contracts.
// The Groth16 verifier is replaced by MockVerifier so the round logic can be
// tested before the circuit and trusted setup exist.
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

const MIN_STAKE = ethers.parseEther("1");
const AGG_BOND = ethers.parseEther("0.5");
const CHALLENGE_BOND = ethers.parseEther("0.2");
const STEP = 600; // seconds per phase
const GENESIS_HASH = ethers.id("genesis-adapter");
const DUMMY_PROOF = { a: [0, 0], b: [[0, 0], [0, 0]], c: [0, 0] };

const Phase = { None: 0, Commit: 1, Reveal: 2, Aggregate: 3, Challenge: 4, Disputed: 5, Finalized: 6 };

const CONFIG = {
  commitDuration: STEP,
  revealDuration: STEP,
  aggregateDuration: STEP,
  challengeDuration: STEP,
  normBoundSq: 1n << 40n,
  rewardPerUpdate: ethers.parseEther("10"),
  aggregatorReward: ethers.parseEther("5"),
  aggregatorBond: AGG_BOND,
  invalidProofPenalty: ethers.parseEther("0.3"),
  noRevealPenalty: ethers.parseEther("0.1"),
  aggregatorTimeoutPenalty: ethers.parseEther("0.4"),
  badAggregatePenalty: ethers.parseEther("0.6"),
};

async function deployFixture() {
  const [admin, treasury, ...rest] = await ethers.getSigners();
  const members = rest.slice(0, 5);

  const token = await ethers.deployContract("FedRewardToken", [admin.address]);
  const registry = await ethers.deployContract("Registry", [MIN_STAKE, treasury.address, admin.address]);
  const verifier = await ethers.deployContract("MockVerifier");
  const rm = await ethers.deployContract("RoundManager", [
    registry, verifier, token, CONFIG, GENESIS_HASH, "ipfs://genesis", admin.address,
  ]);
  const dr = await ethers.deployContract("DisputeResolver", [
    registry, rm, CHALLENGE_BOND, STEP, 2, admin.address,
  ]);

  // Wire roles exactly as scripts/deploy.js does.
  await registry.grantRole(await registry.PROTOCOL_ROLE(), rm);
  await registry.grantRole(await registry.PROTOCOL_ROLE(), dr);
  await token.grantRole(await token.MINTER_ROLE(), rm);
  await rm.grantRole(await rm.DISPUTE_RESOLVER_ROLE(), dr);

  for (const m of members) {
    await registry.addMember(m.address);
    await registry.connect(m).depositStake({ value: MIN_STAKE });
  }
  return { admin, treasury, members, token, registry, verifier, rm, dr };
}

// Starts a round and splits the members into the aggregator and the clients.
async function startRound(ctx) {
  await ctx.rm.startRound();
  const roundId = await ctx.rm.currentRoundId();
  const round = await ctx.rm.getRound(roundId);
  const aggregator = ctx.members.find((m) => m.address === round.aggregator);
  const clients = ctx.members.filter((m) => m.address !== round.aggregator);
  return { roundId, aggregator, clients };
}

// Runs commit + reveal for every client and moves the round to Aggregate.
async function commitAndReveal(ctx, roundId, clients) {
  for (const [i, c] of clients.entries()) {
    await ctx.rm.connect(c).submitUpdate(roundId, 1000 + i, DUMMY_PROOF);
  }
  await time.increase(STEP + 1);
  await ctx.rm.advancePhase(roundId);
  for (const [i, c] of clients.entries()) {
    await ctx.rm.connect(c).revealUpdate(roundId, `ipfs://update-${i}`, 42 + i);
  }
  await time.increase(STEP + 1);
  await ctx.rm.advancePhase(roundId);
}

describe("ZK-FedChain round lifecycle (draft)", function () {
  it("runs a full round and pays accepted clients", async function () {
    const ctx = await loadFixture(deployFixture);
    const { roundId, aggregator, clients } = await startRound(ctx);
    await commitAndReveal(ctx, roundId, clients);

    // Accept the first three updates, filter the fourth.
    const newHash = ethers.id("global-adapter-r1");
    await ctx.rm.connect(aggregator).postAggregate(roundId, newHash, "ipfs://model-1", 0b0111, { value: AGG_BOND });
    expect((await ctx.rm.getRound(roundId)).phase).to.equal(Phase.Challenge);

    await time.increase(STEP + 1);
    await expect(ctx.rm.finalizeRound(roundId)).to.emit(ctx.rm, "RoundFinalized").withArgs(roundId, newHash, 3);

    for (const c of clients.slice(0, 3)) {
      expect(await ctx.token.balanceOf(c.address)).to.equal(CONFIG.rewardPerUpdate);
      expect(await ctx.registry.reputationOf(c.address)).to.equal(1);
    }
    expect(await ctx.token.balanceOf(clients[3].address)).to.equal(0);
    expect(await ctx.registry.reputationOf(clients[3].address)).to.equal(-1); // reputation only, no slash
    expect(await ctx.registry.stakeOf(clients[3].address)).to.equal(MIN_STAKE);

    const [hash, cid, fromRound] = await ctx.rm.latestModel();
    expect(hash).to.equal(newHash);
    expect(cid).to.equal("ipfs://model-1");
    expect(fromRound).to.equal(roundId);
  });

  it("slashes a client whose proof fails verification", async function () {
    const ctx = await loadFixture(deployFixture);
    const { roundId, clients } = await startRound(ctx);
    await ctx.verifier.setResult(false);

    await expect(ctx.rm.connect(clients[0]).submitUpdate(roundId, 7, DUMMY_PROOF))
      .to.emit(ctx.rm, "ProofRejected")
      .withArgs(roundId, clients[0].address);
    expect(await ctx.registry.stakeOf(clients[0].address)).to.equal(MIN_STAKE - CONFIG.invalidProofPenalty);
    expect((await ctx.rm.getSubmission(roundId, clients[0].address)).exists).to.equal(false);
  });

  it("slashes a client that commits but never reveals", async function () {
    const ctx = await loadFixture(deployFixture);
    const { roundId, clients } = await startRound(ctx);
    await ctx.rm.connect(clients[0]).submitUpdate(roundId, 1, DUMMY_PROOF);
    await ctx.rm.connect(clients[1]).submitUpdate(roundId, 2, DUMMY_PROOF);
    await time.increase(STEP + 1);
    await ctx.rm.advancePhase(roundId);

    await ctx.rm.connect(clients[1]).revealUpdate(roundId, "ipfs://u", 5); // clients[0] stays silent
    await time.increase(STEP + 1);
    await ctx.rm.advancePhase(roundId);

    expect(await ctx.registry.stakeOf(clients[0].address)).to.equal(MIN_STAKE - CONFIG.noRevealPenalty);
    expect(await ctx.registry.stakeOf(clients[1].address)).to.equal(MIN_STAKE);
  });

  it("rejects a second submission from the same client in one round", async function () {
    const ctx = await loadFixture(deployFixture);
    const { roundId, clients } = await startRound(ctx);
    await ctx.rm.connect(clients[0]).submitUpdate(roundId, 1, DUMMY_PROOF);
    await expect(ctx.rm.connect(clients[0]).submitUpdate(roundId, 1, DUMMY_PROOF)).to.be.revertedWithCustomError(
      ctx.rm,
      "AlreadySubmitted",
    );
  });

  it("overturns a bad aggregate after a successful challenge", async function () {
    const ctx = await loadFixture(deployFixture);
    const { roundId, aggregator, clients } = await startRound(ctx);
    await commitAndReveal(ctx, roundId, clients);
    await ctx.rm.connect(aggregator).postAggregate(roundId, ethers.id("bad"), "ipfs://bad", 0b1111, { value: AGG_BOND });

    const [challenger, voter1, voter2] = clients;
    await ctx.dr.connect(challenger).openChallenge(roundId, ethers.id("correct"), "ipfs://evidence", {
      value: CHALLENGE_BOND,
    });
    expect((await ctx.rm.getRound(roundId)).phase).to.equal(Phase.Disputed);

    const disputeId = await ctx.dr.disputeOfRound(roundId);
    await ctx.dr.connect(voter1).castVote(disputeId, true);
    await ctx.dr.connect(voter2).castVote(disputeId, true);
    await expect(ctx.dr.connect(aggregator).castVote(disputeId, false)).to.be.revertedWithCustomError(
      ctx.dr,
      "PartyCannotVote",
    );

    await time.increase(STEP + 1);
    await expect(ctx.dr.resolve(disputeId)).to.emit(ctx.rm, "AggregateOverturned").withArgs(roundId, challenger.address);

    expect((await ctx.rm.getRound(roundId)).phase).to.equal(Phase.Finalized);
    expect(await ctx.registry.stakeOf(aggregator.address)).to.equal(MIN_STAKE - CONFIG.badAggregatePenalty);
    const [hash] = await ctx.rm.latestModel();
    expect(hash).to.equal(GENESIS_HASH); // model lineage unchanged
  });
});
