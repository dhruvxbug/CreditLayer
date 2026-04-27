// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./interfaces/ICreditScoreNFT.sol";

/// @title CreditOracle
/// @notice Accepts EIP-712-signed score attestations from a trusted off-chain
///         signer and forwards them to CreditScoreNFT.  This contract is the
///         sole authorised oracle for the NFT contract.
///
///         Flow
///         ────
///         1. An off-chain service signs a ScoreAttestation struct with the
///            trusted private key.
///         2. Anyone calls submitScore() with the attestation data + signature.
///         3. The contract recovers the signer and validates it against
///            `trustedSigner`.
///         4. If the borrower has no NFT yet, mintScore() is called first.
///         5. updateScore() is called with the new score.
contract CreditOracle is Ownable, EIP712 {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the recovered signer does not match `trustedSigner`
    error UnauthorizedOracle();

    /// @notice Thrown when the ECDSA signature cannot be recovered or is malformed
    error InvalidSignature();

    /// @notice Thrown when the attestation timestamp is outside the 5-minute window
    error AttestationExpired(uint64 timestamp, uint64 blockTime);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted after a score is successfully submitted and applied
    /// @param borrower   The wallet whose score was updated
    /// @param score      The new credit score
    /// @param zkVerified Whether the attestation included a ZK proof
    /// @param timestamp  The timestamp embedded in the attestation
    event ScoreSubmitted(
        address indexed borrower,
        uint16  score,
        bool    zkVerified,
        uint64  timestamp
    );

    // -------------------------------------------------------------------------
    // EIP-712 type hash
    // -------------------------------------------------------------------------

    /// @notice EIP-712 typehash for ScoreAttestation
    /// keccak256("ScoreAttestation(address borrower,uint16 score,uint64 timestamp,bool zkVerified)")
    bytes32 public constant SCORE_ATTESTATION_TYPEHASH =
        keccak256(
            "ScoreAttestation(address borrower,uint16 score,uint64 timestamp,bool zkVerified)"
        );

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice The data that the trusted signer commits to off-chain
    struct ScoreAttestation {
        address borrower;
        uint16  score;
        uint64  timestamp;
        bool    zkVerified;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Maximum age of an attestation before it is rejected
    uint64 public constant ATTESTATION_WINDOW = 5 minutes;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The off-chain key whose signatures are accepted
    address public trustedSigner;

    /// @notice The soul-bound credit score NFT contract
    ICreditScoreNFT public creditScoreNFT;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _owner         Contract owner (can rotate signer / NFT address)
    /// @param _trustedSigner Initial trusted signer address
    /// @param _creditScoreNFT Address of the deployed CreditScoreNFT contract
    constructor(
        address _owner,
        address _trustedSigner,
        address _creditScoreNFT
    )
        Ownable(_owner)
        EIP712("CreditLayer", "1")
    {
        trustedSigner  = _trustedSigner;
        creditScoreNFT = ICreditScoreNFT(_creditScoreNFT);
    }

    // -------------------------------------------------------------------------
    // Core logic
    // -------------------------------------------------------------------------

    /// @notice Submit an EIP-712-signed score attestation and apply it on-chain.
    ///
    /// @param borrower   The wallet whose score is being attested
    /// @param score      The new credit score (0–1000)
    /// @param zkVerified Whether this score is backed by a ZK proof
    /// @param timestamp  Unix timestamp baked into the attestation (must be
    ///                   within 5 minutes of block.timestamp)
    /// @param sig        65-byte ECDSA signature over the EIP-712 digest
    function submitScore(
        address borrower,
        uint16  score,
        bool    zkVerified,
        uint64  timestamp,
        bytes calldata sig
    ) external {
        // ── 1. Validate timestamp freshness ──────────────────────────────────
        uint64 blockTime = uint64(block.timestamp);
        if (
            timestamp > blockTime + ATTESTATION_WINDOW ||
            (blockTime > timestamp && blockTime - timestamp > ATTESTATION_WINDOW)
        ) {
            revert AttestationExpired(timestamp, blockTime);
        }

        // ── 2. Reconstruct EIP-712 digest ────────────────────────────────────
        bytes32 structHash = keccak256(
            abi.encode(
                SCORE_ATTESTATION_TYPEHASH,
                borrower,
                score,
                timestamp,
                zkVerified
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        // ── 3. Recover signer ────────────────────────────────────────────────
        if (sig.length != 65) revert InvalidSignature();

        address recovered = ECDSA.recover(digest, sig);

        // ECDSA.recover returns address(0) on failure in older OZ; guard anyway
        if (recovered == address(0)) revert InvalidSignature();
        if (recovered != trustedSigner) revert UnauthorizedOracle();

        // ── 4. Mint NFT if borrower does not yet have one ────────────────────
        uint256 tokenId = creditScoreNFT.getTokenId(borrower);
        if (tokenId == 0) {
            tokenId = creditScoreNFT.mintScore(borrower);
        }

        // ── 5. Apply score update ────────────────────────────────────────────
        creditScoreNFT.updateScore(tokenId, score, zkVerified);

        emit ScoreSubmitted(borrower, score, zkVerified, timestamp);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Rotate the trusted signer key
    /// @param newSigner New signer address
    function setSigner(address newSigner) external onlyOwner {
        trustedSigner = newSigner;
    }

    /// @notice Point the oracle at a different CreditScoreNFT deployment
    /// @param newNFT New NFT contract address
    function setCreditScoreNFT(address newNFT) external onlyOwner {
        creditScoreNFT = ICreditScoreNFT(newNFT);
    }
}
