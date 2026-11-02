// Deploys and wires the ZK-FedChain contracts.
//
//   npx hardhat node                                     # terminal 1
//   npx hardhat run scripts/deploy.js --network localhost # terminal 2
//   npx hardhat run scripts/deploy.js --network sepolia   # needs .env
//
// On local networks MockVerifier is used unless USE_REAL_VERIFIER=true.
// On any other network the snarkjs-generated Groth16Verifier must exist in
// contracts/verifier/ (see circuits/README.md).
// Addresses are written to deployments/<network>.json for the Python clients.
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { ethers, network } = hre;

const LOCAL_NETWORKS = ["hardhat", "localhost"];

// Default protocol parameters (small values for testnets).
const CONFIG = {
  commitDuration: 10 * 60,
  revealDuration: 10 * 60,
  aggregateDuration: 10 * 60,
  challengeDuration: 15 * 60,
  normBoundSq: BigInt(process.env.NORM_BOUND_SQ || (1n << 40n).toString()),
  rewardPerUpdate: ethers.parseEther("10"),
  aggregatorReward: ethers.parseEther("5"),
  aggregatorBond: ethers.parseEther("0.01"),
  invalidProofPenalty: ethers.parseEther("0.005"),
  noRevealPenalty: ethers.parseEther("0.002"),
  aggregatorTimeoutPenalty: ethers.parseEther("0.005"),
  badAggregatePenalty: ethers.parseEther("0.01"),
};
const MIN_STAKE = ethers.parseEther("0.02");
const CHALLENGE_BOND = ethers.parseEther("0.005");
const VOTING_DURATION = 15 * 60;
const QUORUM = 2;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Network: ${network.name}  deployer: ${deployer.address}`);

  // 1. Verifier: mock locally, real Groth16 verifier elsewhere.
  const useMock = LOCAL_NETWORKS.includes(network.name) && process.env.USE_REAL_VERIFIER !== "true";
  const verifier = await ethers.deployContract(useMock ? "MockVerifier" : "Groth16Verifier");
  await verifier.waitForDeployment();

  // 2. Reward token, registry, round manager, dispute resolver.
  const token = await ethers.deployContract("FedRewardToken", [deployer.address]);
  const registry = await ethers.deployContract("Registry", [MIN_STAKE, deployer.address, deployer.address]);
  const genesisHash = process.env.GENESIS_MODEL_HASH || ethers.id("genesis-adapter");
  const genesisCID = process.env.GENESIS_MODEL_CID || "ipfs://genesis";
  const roundManager = await ethers.deployContract("RoundManager", [
    registry, verifier, token, CONFIG, genesisHash, genesisCID, deployer.address,
  ]);
  const disputeResolver = await ethers.deployContract("DisputeResolver", [
    registry, roundManager, CHALLENGE_BOND, VOTING_DURATION, QUORUM, deployer.address,
  ]);
  await Promise.all([token, registry, roundManager, disputeResolver].map((c) => c.waitForDeployment()));

  // 3. Role wiring.
  await (await registry.grantRole(await registry.PROTOCOL_ROLE(), roundManager)).wait();
  await (await registry.grantRole(await registry.PROTOCOL_ROLE(), disputeResolver)).wait();
  await (await token.grantRole(await token.MINTER_ROLE(), roundManager)).wait();
  await (await roundManager.grantRole(await roundManager.DISPUTE_RESOLVER_ROLE(), disputeResolver)).wait();

  const out = {
    network: network.name,
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    verifier: { name: useMock ? "MockVerifier" : "Groth16Verifier", address: await verifier.getAddress() },
    FedRewardToken: await token.getAddress(),
    Registry: await registry.getAddress(),
    RoundManager: await roundManager.getAddress(),
    DisputeResolver: await disputeResolver.getAddress(),
  };
  console.table(out);

  const dir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${network.name}.json`), JSON.stringify(out, null, 2));
  console.log(`Saved deployments/${network.name}.json`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
