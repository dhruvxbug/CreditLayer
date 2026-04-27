// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/MockUSDC.sol";
import "../src/CreditScoreNFT.sol";
import "../src/CreditOracle.sol";
import "../src/CreditLendingPool.sol";

/// @title Deploy
/// @notice Foundry deployment script for the full CreditLayer protocol stack.
///
///         Required environment variables
///         ────────────────────────────────
///         TRUSTED_SIGNER      — EOA whose private key signs score attestations
///         CHAINLINK_ETH_USD   — Chainlink ETH/USD AggregatorV3 feed address
///         ZK_VERIFIER         — ZK verifier contract address (or zero address to disable)
///
///         Optional
///         ────────
///         BASESCAN_API_KEY    — used by forge verify-contract, not needed here
///
///         Run example (Base Sepolia)
///         ──────────────────────────
///         forge script script/Deploy.s.sol \
///           --rpc-url base_sepolia          \
///           --broadcast                     \
///           --verify                        \
///           -vvvv
contract Deploy is Script {
    // -------------------------------------------------------------------------
    // run()
    // -------------------------------------------------------------------------

    /// @notice Deploy all CreditLayer contracts in dependency order and wire
    ///         them together.
    /// @return mockUSDC        Deployed MockUSDC address
    /// @return creditScoreNFT  Deployed CreditScoreNFT address
    /// @return creditOracle    Deployed CreditOracle address
    /// @return lendingPool     Deployed CreditLendingPool address
    function run()
        external
        returns (
            address mockUSDC,
            address creditScoreNFT,
            address creditOracle,
            address lendingPool
        )
    {
        // ── Read environment ──────────────────────────────────────────────────
        address trustedSigner   = vm.envAddress("TRUSTED_SIGNER");
        address chainlinkEthUsd = vm.envAddress("CHAINLINK_ETH_USD");
        address zkVerifier      = vm.envAddress("ZK_VERIFIER");

        // The deployer is the tx.origin inside broadcast; msg.sender == Script
        // contract so we derive the deployer from the private key env var that
        // forge-std uses automatically when --broadcast is set.
        address deployer = msg.sender;

        console.log("=== CreditLayer Deployment ===");
        console.log("Deployer        :", deployer);
        console.log("Trusted signer  :", trustedSigner);
        console.log("Chainlink feed  :", chainlinkEthUsd);
        console.log("ZK verifier     :", zkVerifier);
        console.log("");

        vm.startBroadcast();

        // ── 1. MockUSDC ───────────────────────────────────────────────────────
        // Deploy first — the lending pool needs its address and the deployer
        // receives 10,000,000 mUSDC automatically via the constructor.
        MockUSDC usdcContract = new MockUSDC();
        mockUSDC = address(usdcContract);
        console.log("MockUSDC        :", mockUSDC);

        // ── 2. CreditScoreNFT ─────────────────────────────────────────────────
        // We pass address(0) as the initial oracle because the oracle contract
        // hasn't been deployed yet.  We update it with setOracle() below after
        // CreditOracle is live.
        CreditScoreNFT nftContract = new CreditScoreNFT(
            deployer,       // initialOwner
            address(0)      // oracle — updated below
        );
        creditScoreNFT = address(nftContract);
        console.log("CreditScoreNFT  :", creditScoreNFT);

        // ── 3. CreditOracle ───────────────────────────────────────────────────
        CreditOracle oracleContract = new CreditOracle(
            deployer,        // owner
            trustedSigner,   // the EOA whose sig the oracle validates
            creditScoreNFT   // the NFT contract to call mint/update on
        );
        creditOracle = address(oracleContract);
        console.log("CreditOracle    :", creditOracle);

        // ── 4. Wire CreditScoreNFT → CreditOracle ────────────────────────────
        // Now that the oracle is deployed we point the NFT at it.
        nftContract.setOracle(creditOracle);
        console.log("NFT oracle set to CreditOracle");

        // ── 5. CreditLendingPool ──────────────────────────────────────────────
        CreditLendingPool poolContract = new CreditLendingPool(
            creditScoreNFT,  // credit score gate
            mockUSDC,        // USDC token
            chainlinkEthUsd, // Chainlink ETH/USD feed
            zkVerifier,      // ZK verifier (address(0) disables on testnet)
            deployer         // owner
        );
        lendingPool = address(poolContract);
        console.log("CreditLendingPool:", lendingPool);

        // ── 6. Seed pool liquidity from deployer's initial 10 M mUSDC ─────────
        // Transfer 1,000,000 mUSDC (6 decimals) to the pool so borrowers
        // can draw funds immediately after deployment.
        uint256 seedAmount = 1_000_000 * 10 ** 6;
        usdcContract.transfer(lendingPool, seedAmount);
        console.log("Pool seeded with 1,000,000 mUSDC");

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console.log("");
        console.log("=== Deployment complete ===");
        console.log("MockUSDC         :", mockUSDC);
        console.log("CreditScoreNFT   :", creditScoreNFT);
        console.log("CreditOracle     :", creditOracle);
        console.log("CreditLendingPool:", lendingPool);
    }
}
