// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/CreditScoreNFT.sol";
import "../src/CreditOracle.sol";
import "../src/MockUSDC.sol";

/// @title CreditScoreNFT Test Suite
/// @notice Comprehensive Foundry tests for CreditScoreNFT covering soul-bound
///         enforcement, cooldown logic, tier derivation, access control and
///         fuzz coverage.
contract CreditScoreNFTTest is Test {
    // -------------------------------------------------------------------------
    // Contracts under test
    // -------------------------------------------------------------------------

    CreditScoreNFT internal nft;
    CreditOracle   internal oracle;
    MockUSDC       internal usdc;

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal owner       = makeAddr("owner");
    address internal trustedSigner = makeAddr("trustedSigner");
    address internal oracleEOA   = makeAddr("oracleEOA");   // acts as direct oracle
    address internal userA       = makeAddr("userA");
    address internal userB       = makeAddr("userB");
    address internal attacker    = makeAddr("attacker");

    // -------------------------------------------------------------------------
    // setUp — runs before every test
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);

        // Deploy MockUSDC (not central to these tests but mirrors prod setup)
        usdc = new MockUSDC();

        // Deploy CreditScoreNFT — initially set oracleEOA as the oracle so
        // we can call mint/update directly without going through CreditOracle's
        // EIP-712 path (which requires valid off-chain signatures).
        nft = new CreditScoreNFT(owner, oracleEOA);

        // Deploy CreditOracle pointing at the NFT (trustedSigner is a dummy
        // key here since we test the NFT directly via oracleEOA in most cases)
        oracle = new CreditOracle(owner, trustedSigner, address(nft));

        vm.stopPrank();
    }

    // =========================================================================
    // 1. test_MintScore
    // =========================================================================

    /// @notice The oracle can mint a score NFT to a user; the token ID is stored
    ///         and getScore returns a sensible initial state.
    function test_MintScore() public {
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Token ID must be non-zero (IDs start at 1)
        assertGt(tokenId, 0, "tokenId should be > 0");

        // walletToTokenId mapping must be updated
        assertEq(nft.walletToTokenId(userA), tokenId, "walletToTokenId mismatch");

        // userA must own the token
        assertEq(nft.ownerOf(tokenId), userA, "owner should be userA");

        // After mint, score is 0 and tier is Unverified (0)
        (uint16 score, uint8 tier, bool zkVerified) = nft.getScore(userA);
        assertEq(score,      0, "initial score should be 0");
        assertEq(tier,       0, "initial tier should be 0 (Unverified)");
        assertFalse(zkVerified, "initial zkVerified should be false");
    }

    /// @notice A second mint for the same wallet must revert.
    function test_MintScore_RevertIfAlreadyMinted() public {
        vm.startPrank(oracleEOA);
        nft.mintScore(userA);

        // Second mint should fail
        vm.expectRevert("CreditScoreNFT: wallet already has token");
        nft.mintScore(userA);
        vm.stopPrank();
    }

    /// @notice Minting to distinct wallets produces distinct, monotonically
    ///         increasing token IDs.
    function test_MintScore_MultipleUsers() public {
        vm.startPrank(oracleEOA);
        uint256 idA = nft.mintScore(userA);
        uint256 idB = nft.mintScore(userB);
        vm.stopPrank();

        assertEq(idA, 1, "first token ID should be 1");
        assertEq(idB, 2, "second token ID should be 2");
        assertEq(nft.walletToTokenId(userA), idA);
        assertEq(nft.walletToTokenId(userB), idB);
    }

    // =========================================================================
    // 2. test_SoulBound_CannotTransfer
    // =========================================================================

    /// @notice transferFrom must always revert with SoulBoundToken.
    function test_SoulBound_CannotTransfer() public {
        // Mint token for userA
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Attempt to transfer as the owner (userA)
        vm.prank(userA);
        vm.expectRevert(ICreditScoreNFT.SoulBoundToken.selector);
        nft.transferFrom(userA, userB, tokenId);
    }

    /// @notice transferFrom also reverts when called by an approved operator.
    function test_SoulBound_CannotTransfer_Operator() public {
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Approve attacker
        vm.prank(userA);
        // Approval itself should succeed (approve is not blocked)
        nft.approve(attacker, tokenId);

        // But transfer must still revert
        vm.prank(attacker);
        vm.expectRevert(ICreditScoreNFT.SoulBoundToken.selector);
        nft.transferFrom(userA, attacker, tokenId);
    }

    // =========================================================================
    // 3. test_SoulBound_CannotSafeTransfer
    // =========================================================================

    /// @notice safeTransferFrom (3-arg) must always revert with SoulBoundToken.
    function test_SoulBound_CannotSafeTransfer() public {
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        vm.prank(userA);
        vm.expectRevert(ICreditScoreNFT.SoulBoundToken.selector);
        nft.safeTransferFrom(userA, userB, tokenId);
    }

    /// @notice safeTransferFrom (4-arg, with data) must also revert.
    function test_SoulBound_CannotSafeTransfer_WithData() public {
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        vm.prank(userA);
        vm.expectRevert(ICreditScoreNFT.SoulBoundToken.selector);
        nft.safeTransferFrom(userA, userB, tokenId, bytes("extra data"));
    }

    // =========================================================================
    // 4. test_UpdateScore_Cooldown
    // =========================================================================

    /// @notice Updating a score twice without waiting for the 24-hour cooldown
    ///         must revert with CooldownNotExpired.
    function test_UpdateScore_Cooldown() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // First update — sets lastUpdated to block.timestamp
        nft.updateScore(tokenId, 400, false);

        // Second update immediately after — should revert
        uint64 expectedNext = uint64(block.timestamp) + uint64(nft.UPDATE_COOLDOWN());
        vm.expectRevert(
            abi.encodeWithSelector(
                ICreditScoreNFT.CooldownNotExpired.selector,
                expectedNext
            )
        );
        nft.updateScore(tokenId, 500, false);

        vm.stopPrank();
    }

    /// @notice The cooldown is measured from lastUpdated; a partial warp that
    ///         is one second short of expiry must still revert.
    function test_UpdateScore_Cooldown_OneSecondShort() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);
        nft.updateScore(tokenId, 300, false);

        // Warp to exactly 1 second before cooldown expires
        vm.warp(block.timestamp + nft.UPDATE_COOLDOWN() - 1);

        uint64 expectedNext = uint64(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICreditScoreNFT.CooldownNotExpired.selector,
                expectedNext
            )
        );
        nft.updateScore(tokenId, 350, false);
        vm.stopPrank();
    }

    // =========================================================================
    // 5. test_UpdateScore_AfterCooldown
    // =========================================================================

    /// @notice After waiting 25 hours the oracle can successfully update again.
    function test_UpdateScore_AfterCooldown() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // First update
        nft.updateScore(tokenId, 400, false);

        // Advance time by 25 hours (beyond the 24 h cooldown)
        vm.warp(block.timestamp + 25 hours);

        // Second update — should succeed
        nft.updateScore(tokenId, 650, true);
        vm.stopPrank();

        (uint16 score, uint8 tier, bool zkVerified) = nft.getScore(userA);
        assertEq(score,     650, "score should be updated to 650");
        assertEq(tier,        2, "tier should be Silver (2) for score 650");
        assertTrue(zkVerified,  "zkVerified should be true after second update");
    }

    /// @notice Exactly at the cooldown boundary (24 h) the update should succeed.
    function test_UpdateScore_ExactlyAtCooldownBoundary() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);
        nft.updateScore(tokenId, 300, false);

        // Warp to exactly the cooldown expiry
        vm.warp(block.timestamp + nft.UPDATE_COOLDOWN());

        // Should not revert
        nft.updateScore(tokenId, 800, true);
        vm.stopPrank();

        (uint16 score, , ) = nft.getScore(userA);
        assertEq(score, 800);
    }

    // =========================================================================
    // 6. test_TierDerivation
    // =========================================================================

    /// @notice getTier must return the correct tier for boundary and interior
    ///         values at every tier boundary.
    function test_TierDerivation() public view {
        // ── Unverified (tier 0): score < 300 ─────────────────────────────────
        assertEq(nft.getTier(0),   0, "score=0   => Unverified");
        assertEq(nft.getTier(1),   0, "score=1   => Unverified");
        assertEq(nft.getTier(299), 0, "score=299 => Unverified");

        // ── Bronze (tier 1): 300 <= score < 600 ──────────────────────────────
        assertEq(nft.getTier(300), 1, "score=300 => Bronze");
        assertEq(nft.getTier(450), 1, "score=450 => Bronze");
        assertEq(nft.getTier(599), 1, "score=599 => Bronze");

        // ── Silver (tier 2): 600 <= score < 800 ──────────────────────────────
        assertEq(nft.getTier(600), 2, "score=600 => Silver");
        assertEq(nft.getTier(700), 2, "score=700 => Silver");
        assertEq(nft.getTier(799), 2, "score=799 => Silver");

        // ── Gold (tier 3): score >= 800 ───────────────────────────────────────
        assertEq(nft.getTier(800),  3, "score=800  => Gold");
        assertEq(nft.getTier(900),  3, "score=900  => Gold");
        assertEq(nft.getTier(1000), 3, "score=1000 => Gold");
    }

    /// @notice getScore returns a tier consistent with getTier at all points.
    function test_TierDerivation_ViaGetScore() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        uint16[8] memory scores   = [uint16(0),   299, 300, 599, 600, 799, 800, 1000];
        uint8[8]  memory expected = [uint8(0),       0,   1,   1,   2,   2,   3,    3];

        for (uint256 i = 0; i < scores.length; i++) {
            // We need to advance time to bypass cooldown on each iteration
            if (i > 0) vm.warp(block.timestamp + 25 hours);

            nft.updateScore(tokenId, scores[i], false);
            (, uint8 tier, ) = nft.getScore(userA);
            assertEq(tier, expected[i], "tier mismatch from getScore");
        }
        vm.stopPrank();
    }

    // =========================================================================
    // 7. test_OnlyOracle_CanMint
    // =========================================================================

    /// @notice A non-oracle address must not be able to call mintScore.
    function test_OnlyOracle_CanMint() public {
        vm.prank(attacker);
        vm.expectRevert(ICreditScoreNFT.UnauthorizedOracle.selector);
        nft.mintScore(userA);
    }

    /// @notice A non-oracle address must not be able to call updateScore.
    function test_OnlyOracle_CanUpdate() public {
        // First legitimately mint a token
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Attacker tries to update
        vm.prank(attacker);
        vm.expectRevert(ICreditScoreNFT.UnauthorizedOracle.selector);
        nft.updateScore(tokenId, 900, true);
    }

    /// @notice Owner must not be able to mint — only the oracle address can.
    function test_OnlyOracle_OwnerCannotMint() public {
        vm.prank(owner);
        vm.expectRevert(ICreditScoreNFT.UnauthorizedOracle.selector);
        nft.mintScore(userA);
    }

    // =========================================================================
    // 8. test_SetOracle
    // =========================================================================

    /// @notice The owner can rotate the oracle address.
    function test_SetOracle_Owner() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(owner);
        nft.setOracle(newOracle);

        assertEq(nft.oracle(), newOracle, "oracle should be updated");

        // Old oracle can no longer mint
        vm.prank(oracleEOA);
        vm.expectRevert(ICreditScoreNFT.UnauthorizedOracle.selector);
        nft.mintScore(userA);

        // New oracle can mint
        vm.prank(newOracle);
        uint256 tokenId = nft.mintScore(userA);
        assertGt(tokenId, 0);
    }

    /// @notice A non-owner must not be able to call setOracle.
    function test_SetOracle_NonOwnerReverts() public {
        vm.prank(attacker);
        // OwnableUnauthorizedAccount is the OZ v5 error selector
        vm.expectRevert();
        nft.setOracle(attacker);
    }

    // =========================================================================
    // 9. tokenURI
    // =========================================================================

    /// @notice tokenURI should return a non-empty base64-encoded JSON string.
    function test_TokenURI_NonEmpty() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);
        nft.updateScore(tokenId, 750, true);
        vm.stopPrank();

        string memory uri = nft.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0, "tokenURI should not be empty");

        // Should start with the data URI prefix
        bytes memory uriBytes = bytes(uri);
        bytes memory prefix   = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i], "tokenURI prefix mismatch");
        }
    }

    /// @notice tokenURI on a non-existent token should revert.
    function test_TokenURI_NonExistentReverts() public {
        vm.expectRevert();
        nft.tokenURI(9999);
    }

    // =========================================================================
    // 10. getTokenId
    // =========================================================================

    /// @notice getTokenId returns 0 for wallets without a token.
    function test_GetTokenId_NoToken() public view {
        assertEq(nft.getTokenId(userA), 0, "should return 0 for unminted wallet");
    }

    /// @notice getTokenId returns the correct ID after mint.
    function test_GetTokenId_AfterMint() public {
        vm.prank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        assertEq(nft.getTokenId(userA), tokenId);
    }

    // =========================================================================
    // 11. ScoreUpdated event
    // =========================================================================

    /// @notice updateScore must emit ScoreUpdated with the correct parameters.
    function test_UpdateScore_EmitsEvent() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Expect event: wallet=userA, tokenId, newScore=600, tier=2, zkVerified=true
        vm.expectEmit(true, true, false, true);
        emit CreditScoreNFT.ScoreUpdated(userA, tokenId, 600, 2, true);

        nft.updateScore(tokenId, 600, true);
        vm.stopPrank();
    }

    // =========================================================================
    // 12. First update bypasses cooldown (lastUpdated == 0)
    // =========================================================================

    /// @notice The very first update on a freshly minted token must not be
    ///         gated by the cooldown (lastUpdated is 0).
    function test_FirstUpdate_NoCooldown() public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Should succeed immediately — no warp needed
        nft.updateScore(tokenId, 700, true);
        vm.stopPrank();

        (uint16 score, uint8 tier, bool zkVerified) = nft.getScore(userA);
        assertEq(score, 700);
        assertEq(tier,    2);
        assertTrue(zkVerified);
    }

    // =========================================================================
    // Fuzz: getTier never reverts for any uint16 score
    // =========================================================================

    /// @notice getTier must never revert, regardless of the score value, and
    ///         must always return a value in [0, 3].
    function fuzz_ScoreAlwaysInRange(uint16 score) public view {
        uint8 tier = nft.getTier(score);
        assertLe(tier, 3, "tier must be <= 3");
    }

    /// @notice Fuzz alias using the standard Foundry naming convention so both
    ///         `fuzz_` and `testFuzz_` prefixes are covered.
    function testFuzz_ScoreAlwaysInRange(uint16 score) public view {
        uint8 tier = nft.getTier(score);
        assertLe(tier, 3, "tier out of range");

        // Verify tier boundaries are respected
        if (score < 300)       assertEq(tier, 0, "should be Unverified");
        else if (score < 600)  assertEq(tier, 1, "should be Bronze");
        else if (score < 800)  assertEq(tier, 2, "should be Silver");
        else                   assertEq(tier, 3, "should be Gold");
    }

    /// @notice Fuzz that updateScore stores whatever score the oracle provides
    ///         and getScore returns consistent tier values.
    function testFuzz_UpdateScoreStoresCorrectly(uint16 score) public {
        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);
        nft.updateScore(tokenId, score, true);
        vm.stopPrank();

        (uint16 storedScore, uint8 storedTier, bool zkVerified) = nft.getScore(userA);

        assertEq(storedScore, score,              "stored score mismatch");
        assertEq(storedTier,  nft.getTier(score), "stored tier mismatch");
        assertTrue(zkVerified,                    "zkVerified should be true");
    }

    /// @notice Fuzz that the cooldown window is always exactly UPDATE_COOLDOWN
    ///         regardless of the block timestamp at which the update was made.
    function testFuzz_CooldownWindow(uint32 warpSeconds) public {
        // Bound warpSeconds to a sane range: 1 second to 10 years
        uint256 warp = bound(warpSeconds, 1, 10 * 365 days);

        vm.startPrank(oracleEOA);
        uint256 tokenId = nft.mintScore(userA);

        // Warp to some arbitrary future time before first update
        vm.warp(block.timestamp + warp);
        nft.updateScore(tokenId, 400, false);

        uint64 updateTime    = uint64(block.timestamp);
        uint64 expectedNext  = updateTime + uint64(nft.UPDATE_COOLDOWN());

        // Immediate second update must revert with the correct next timestamp
        vm.expectRevert(
            abi.encodeWithSelector(
                ICreditScoreNFT.CooldownNotExpired.selector,
                expectedNext
            )
        );
        nft.updateScore(tokenId, 500, false);

        vm.stopPrank();
    }
}
