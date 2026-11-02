// Hardhat configuration for ZK-FedChain.
// Networks:
//   hardhat   - in-process chain used by `npx hardhat test`
//   localhost - `npx hardhat node` running on port 8545
//   sepolia   - public Ethereum testnet (needs SEPOLIA_RPC_URL and PRIVATE_KEY in .env)
//   besu      - optional permissioned EVM network for a consortium deployment
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { SEPOLIA_RPC_URL, BESU_RPC_URL, PRIVATE_KEY, REPORT_GAS } = process.env;
const accounts = PRIVATE_KEY ? [PRIVATE_KEY] : [];

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    localhost: { url: "http://127.0.0.1:8545" },
    ...(SEPOLIA_RPC_URL ? { sepolia: { url: SEPOLIA_RPC_URL, accounts } } : {}),
    ...(BESU_RPC_URL ? { besu: { url: BESU_RPC_URL, accounts } } : {}),
  },
  gasReporter: {
    enabled: REPORT_GAS === "true",
    currency: "USD",
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    artifacts: "./artifacts",
    cache: "./cache",
  },
};
