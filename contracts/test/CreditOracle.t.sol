// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/CreditOracle.sol";
import "../src/CreditScoreNFT.sol";

contract CreditOracleTest is Test {
    CreditScoreNFT internal nft;
    CreditOracle internal oracle;

    uint256 internal trustedSignerPk = 0xA11CE;
    uint256 internal otherSignerPk = 0xB0B;

    address internal owner = makeAddr("owner");
    address internal trustedSigner;
    address internal borrower = makeAddr("borrower");
    address internal otherBorrower = makeAddr("otherBorrower");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        trustedSigner = vm.addr(trustedSignerPk);
        vm.warp(1_700_000_000);

        vm.startPrank(owner);
        nft = new CreditScoreNFT(owner, address(0));
        oracle = new CreditOracle(owner, trustedSigner, address(nft));
        nft.setOracle(address(oracle));
        vm.stopPrank();
    }

    function test_SubmitScore_MintsAndUpdatesScore() public {
        uint64 timestamp = uint64(block.timestamp);
        bytes memory sig = _signScore(trustedSignerPk, borrower, 742, true, timestamp);

        vm.expectEmit(true, false, false, true);
        emit CreditOracle.ScoreSubmitted(borrower, 742, true, timestamp);

        oracle.submitScore(borrower, 742, true, timestamp, sig);

        uint256 tokenId = nft.getTokenId(borrower);
        assertGt(tokenId, 0, "borrower should receive score NFT");
        assertEq(nft.ownerOf(tokenId), borrower, "borrower should own score NFT");

        (uint16 score, uint8 tier, bool zkVerified) = nft.getScore(borrower);
        assertEq(score, 742, "score mismatch");
        assertEq(tier, 2, "tier should be Silver");
        assertTrue(zkVerified, "score should be ZK verified");
    }

    function test_SubmitScore_UpdatesExistingTokenAfterCooldown() public {
        uint64 firstTimestamp = uint64(block.timestamp);
        oracle.submitScore(
            borrower,
            610,
            false,
            firstTimestamp,
            _signScore(trustedSignerPk, borrower, 610, false, firstTimestamp)
        );

        uint256 firstTokenId = nft.getTokenId(borrower);

        vm.warp(block.timestamp + nft.UPDATE_COOLDOWN());
        uint64 secondTimestamp = uint64(block.timestamp);

        oracle.submitScore(
            borrower,
            830,
            true,
            secondTimestamp,
            _signScore(trustedSignerPk, borrower, 830, true, secondTimestamp)
        );

        assertEq(nft.getTokenId(borrower), firstTokenId, "token ID should be stable");

        (uint16 score, uint8 tier, bool zkVerified) = nft.getScore(borrower);
        assertEq(score, 830, "score should update");
        assertEq(tier, 3, "tier should be Gold");
        assertTrue(zkVerified, "ZK flag should update");
    }

    function test_SubmitScore_RevertsForWrongSigner() public {
        uint64 timestamp = uint64(block.timestamp);
        bytes memory sig = _signScore(otherSignerPk, borrower, 700, true, timestamp);

        vm.expectRevert(CreditOracle.UnauthorizedOracle.selector);
        oracle.submitScore(borrower, 700, true, timestamp, sig);
    }

    function test_SubmitScore_RevertsForMalformedSignature() public {
        vm.expectRevert(CreditOracle.InvalidSignature.selector);
        oracle.submitScore(borrower, 700, true, uint64(block.timestamp), hex"1234");
    }

    function test_SubmitScore_RevertsForExpiredPastTimestamp() public {
        uint64 timestamp = uint64(block.timestamp - oracle.ATTESTATION_WINDOW() - 1);
        bytes memory sig = _signScore(trustedSignerPk, borrower, 700, true, timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditOracle.AttestationExpired.selector,
                timestamp,
                uint64(block.timestamp)
            )
        );
        oracle.submitScore(borrower, 700, true, timestamp, sig);
    }

    function test_SubmitScore_RevertsForFutureTimestampBeyondWindow() public {
        uint64 timestamp = uint64(block.timestamp + oracle.ATTESTATION_WINDOW() + 1);
        bytes memory sig = _signScore(trustedSignerPk, borrower, 700, true, timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditOracle.AttestationExpired.selector,
                timestamp,
                uint64(block.timestamp)
            )
        );
        oracle.submitScore(borrower, 700, true, timestamp, sig);
    }

    function test_SetSigner_RotatesTrustedSigner() public {
        address newSigner = vm.addr(otherSignerPk);

        vm.prank(owner);
        oracle.setSigner(newSigner);

        uint64 timestamp = uint64(block.timestamp);
        bytes memory oldSig = _signScore(trustedSignerPk, borrower, 700, true, timestamp);
        vm.expectRevert(CreditOracle.UnauthorizedOracle.selector);
        oracle.submitScore(borrower, 700, true, timestamp, oldSig);

        bytes memory newSig = _signScore(otherSignerPk, borrower, 700, true, timestamp);
        oracle.submitScore(borrower, 700, true, timestamp, newSig);

        (uint16 score, , ) = nft.getScore(borrower);
        assertEq(score, 700, "new signer should be accepted");
    }

    function test_SetCreditScoreNFT_RetargetsOracle() public {
        CreditScoreNFT replacement = new CreditScoreNFT(owner, address(oracle));

        vm.prank(owner);
        oracle.setCreditScoreNFT(address(replacement));

        uint64 timestamp = uint64(block.timestamp);
        bytes memory sig = _signScore(trustedSignerPk, otherBorrower, 910, true, timestamp);
        oracle.submitScore(otherBorrower, 910, true, timestamp, sig);

        assertEq(nft.getTokenId(otherBorrower), 0, "old NFT should not be updated");

        (uint16 score, uint8 tier, bool zkVerified) = replacement.getScore(otherBorrower);
        assertEq(score, 910, "replacement NFT should receive score");
        assertEq(tier, 3, "replacement score should be Gold");
        assertTrue(zkVerified, "replacement ZK flag mismatch");
    }

    function test_SetSigner_RevertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setSigner(attacker);
    }

    function test_SetCreditScoreNFT_RevertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setCreditScoreNFT(attacker);
    }

    function _signScore(
        uint256 signerPk,
        address scoreBorrower,
        uint16 score,
        bool zkVerified,
        uint64 timestamp
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                oracle.SCORE_ATTESTATION_TYPEHASH(),
                scoreBorrower,
                score,
                timestamp,
                zkVerified
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("CreditLayer")),
                keccak256(bytes("1")),
                block.chainid,
                address(oracle)
            )
        );
    }
}
