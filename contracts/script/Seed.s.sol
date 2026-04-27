// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/MockUSDC.sol";
import "../src/CreditScoreNFT.sol";
import "../src/CreditOracle.sol";

/// @title Seed
/// @notice Foundry script that seeds the CreditLayer testnet deployment with
///         test wallets, USDC balances and on-chain credit scores.
///
///         Required environment variables
///         ────────────────────────────────
///         MOCK_USDC          — deployed MockUSDC address
///         CREDIT_SCORE_NFT   — deployed CreditScoreNFT address
///         CREDIT_ORACLE      — deployed CreditOracle address
///         LENDING_POOL       — deployed CreditLendingPool address
///         TEST_WALLET_A      — first test wallet (will receive score 750 – Silver/Gold border)
///         TEST_WALLET_B      — second test wallet (will receive score 320 – Bronze)
///
///         NOTE on score submission
///         ────────────────────────
///         CreditOracle.submitScore() requires a valid EIP-712 signature from
///         the trusted signer.  On a live testnet you must generate the
///         signatures off-chain (see the companion `scripts/sign-attestation.ts`
///         helper) and paste them in, OR deploy a version of CreditOracle that
///         exposes the seedScore() admin bypass below.
///
///         For local Anvil / fork testing the script calls seedScore() directly
///         on the NFT via an admin path (the script deployer is set as oracle
///         temporarily).  The exact approach is toggled by the USE_ADMIN_SEED
///         env var:
///           USE_ADMIN_SEED=true  → bypass signature, call NFT directly (local only)
///           USE_ADMIN_SEED=false → call submitScore() with pre-built sigs (testnet)
///
///         Run example (local Anvil)
///         ──────────────────────────
///         USE_ADMIN_SEED=true \
///         forge script script/Seed.s.sol \
///           --rpc-url http://localhost:8545 \
///           --broadcast \
///           -vvvv
///
///         Run example (Base Sepolia — requires valid sigs)
///         ──────────────────────────────────────────────────
///         forge script script/Seed.s.sol \
///           --rpc-url base_sepolia \
///           --broadcast \
///           -vvvv
contract Seed is Script {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev 100,000 mUSDC (6 decimals)
    uint256 constant WALLET_USDC_AMOUNT = 100_000 * 1e6;

    /// @dev 50,000 mUSDC (6 decimals) — initial pool liquidity top-up
    uint256 constant POOL_USDC_AMOUNT = 50_000 * 1e6;

    /// @dev Credit score for Wallet A — 750 puts it firmly in the Silver tier
    ///      (600 <= score < 800) and close to Gold, useful for UI demos.
    uint16 constant SCORE_A = 750;

    /// @dev Credit score for Wallet B — 320 is the minimum viable Bronze score.
    uint16 constant SCORE_B = 320;

    // -------------------------------------------------------------------------
    // run()
    // -------------------------------------------------------------------------

    function run() external {
        // ── Read environment ──────────────────────────────────────────────────
        address mockUSDCAddr     = vm.envAddress("MOCK_USDC");
        address creditScoreNFT   = vm.envAddress("CREDIT_SCORE_NFT");
        address creditOracleAddr = vm.envAddress("CREDIT_ORACLE");
        address lendingPool      = vm.envAddress("LENDING_POOL");
        address walletA          = vm.envAddress("TEST_WALLET_A");
        address walletB          = vm.envAddress("TEST_WALLET_B");

        // Toggle between admin seed (local) and signature-based seed (testnet)
        bool useAdminSeed = vm.envOr("USE_ADMIN_SEED", false);

        MockUSDC     usdc   = MockUSDC(mockUSDCAddr);
        CreditScoreNFT nft  = CreditScoreNFT(creditScoreNFT);
        CreditOracle oracle = CreditOracle(creditOracleAddr);

        address seeder = msg.sender;

        console.log("=== CreditLayer Seed Script ===");
        console.log("Seeder         :", seeder);
        console.log("MockUSDC       :", mockUSDCAddr);
        console.log("CreditScoreNFT :", creditScoreNFT);
        console.log("CreditOracle   :", creditOracleAddr);
        console.log("LendingPool    :", lendingPool);
        console.log("Wallet A       :", walletA);
        console.log("Wallet B       :", walletB);
        console.log("Admin seed     :", useAdminSeed);
        console.log("");

        vm.startBroadcast();

        // ── 1. Mint USDC to test wallets ──────────────────────────────────────
        usdc.mint(walletA, WALLET_USDC_AMOUNT);
        console.log("Minted 100,000 mUSDC to Wallet A");

        usdc.mint(walletB, WALLET_USDC_AMOUNT);
        console.log("Minted 100,000 mUSDC to Wallet B");

        // ── 2. Top-up the lending pool ────────────────────────────────────────
        usdc.mint(lendingPool, POOL_USDC_AMOUNT);
        console.log("Minted 50,000 mUSDC to LendingPool");

        // ── 3. Submit credit scores ───────────────────────────────────────────
        if (useAdminSeed) {
            // ----------------------------------------------------------------
            // LOCAL / ADMIN PATH
            // ----------------------------------------------------------------
            // Temporarily set the seeder as oracle so we can call mint/update
            // directly without a valid EIP-712 signature.  We restore the real
            // oracle address afterwards.
            //
            // This is only safe on a private/local network.  NEVER use this
            // path on a public testnet or mainnet.
            // ----------------------------------------------------------------

            address realOracle = nft.oracle();

            // Elevate seeder to oracle role
            nft.setOracle(seeder);

            // ── Wallet A: score 750 (Silver tier) ────────────────────────────
            uint256 tokenIdA = nft.getTokenId(walletA);
            if (tokenIdA == 0) {
                tokenIdA = nft.mintScore(walletA);
                console.log("Minted score NFT for Wallet A, tokenId:", tokenIdA);
            }
            nft.updateScore(tokenIdA, SCORE_A, true /* zkVerified */);
            console.log("Updated Wallet A score to", SCORE_A, "(Silver, ZK verified)");

            // ── Wallet B: score 320 (Bronze tier) ────────────────────────────
            uint256 tokenIdB = nft.getTokenId(walletB);
            if (tokenIdB == 0) {
                tokenIdB = nft.mintScore(walletB);
                console.log("Minted score NFT for Wallet B, tokenId:", tokenIdB);
            }
            nft.updateScore(tokenIdB, SCORE_B, false /* zkVerified */);
            console.log("Updated Wallet B score to", SCORE_B, "(Bronze, not ZK verified)");

            // Restore real oracle
            nft.setOracle(realOracle);
            console.log("Restored oracle to CreditOracle contract");

        } else {
            // ----------------------------------------------------------------
            // TESTNET / SIGNATURE PATH
            // ----------------------------------------------------------------
            // To use this path:
            //   1. Run the off-chain helper:
            //        npx ts-node scripts/sign-attestation.ts \
            //          --borrower <WALLET_A> --score 750 --zkVerified true
            //      which prints a hex signature.
            //   2. Set WALLET_A_SIG and WALLET_B_SIG in your environment.
            //   3. Re-run this script with USE_ADMIN_SEED=false.
            //
            // The timestamp baked into each signature must be within 5 minutes
            // of the block timestamp at submission time — generate the sigs
            // immediately before broadcasting.
            // ----------------------------------------------------------------

            bytes memory sigA = vm.envBytes("WALLET_A_SIG");
            bytes memory sigB = vm.envBytes("WALLET_B_SIG");
            uint64 tsA        = uint64(vm.envUint("WALLET_A_TS"));
            uint64 tsB        = uint64(vm.envUint("WALLET_B_TS"));

            // Wallet A — score 750, ZK verified
            oracle.submitScore(walletA, SCORE_A, true,  tsA, sigA);
            console.log("Submitted score 750 for Wallet A via CreditOracle");

            // Wallet B — score 320, not ZK verified
            oracle.submitScore(walletB, SCORE_B, false, tsB, sigB);
            console.log("Submitted score 320 for Wallet B via CreditOracle");
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console.log("");
        console.log("=== Seed complete ===");
        console.log("Wallet A USDC balance :", usdc.balanceOf(walletA));
        console.log("Wallet B USDC balance :", usdc.balanceOf(walletB));
        console.log("Pool USDC balance     :", usdc.balanceOf(lendingPool));

        (uint16 scoreA, uint8 tierA, bool zkA) = nft.getScore(walletA);
        console.log("Wallet A score:", scoreA, "| tier:", uint256(tierA));
        console.log("Wallet A zkVerified:", zkA);

        (uint16 scoreB, uint8 tierB, bool zkB) = nft.getScore(walletB);
        console.log("Wallet B score:", scoreB, "| tier:", uint256(tierB));
        console.log("Wallet B zkVerified:", zkB);
    }
}
