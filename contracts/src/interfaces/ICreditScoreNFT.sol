// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICreditScoreNFT
/// @notice Interface for the CreditLayer soul-bound credit score NFT
interface ICreditScoreNFT {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted whenever a credit score is updated on a token
    /// @param wallet   The wallet address whose score changed
    /// @param newScore The new raw credit score (0–1000)
    /// @param tier     The derived tier (0=Unverified, 1=Bronze, 2=Silver, 3=Gold)
    /// @param zkVerified Whether the score update was backed by a ZK proof
    event ScoreUpdated(
        address indexed wallet,
        uint16 newScore,
        uint8 tier,
        bool zkVerified
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when an attempt is made to transfer a soul-bound token
    error SoulBoundToken();

    /// @notice Thrown when a score update is attempted before the cooldown expires
    /// @param nextUpdateAllowed Unix timestamp after which the next update is permitted
    error CooldownNotExpired(uint64 nextUpdateAllowed);

    /// @notice Thrown when a caller that is not the authorised oracle attempts a
    ///         privileged action (mint or update)
    error UnauthorizedOracle();

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /// @notice Mint a new credit-score NFT to `to`
    /// @dev    Only callable by the authorised oracle.
    ///         Reverts if `to` already owns a token.
    /// @param to The wallet that will receive the soul-bound token
    /// @return tokenId The token ID that was minted
    function mintScore(address to) external returns (uint256 tokenId);

    /// @notice Update the credit score stored on an existing token
    /// @dev    Only callable by the authorised oracle.
    ///         Enforces a 24-hour cooldown between updates (CooldownNotExpired).
    /// @param tokenId    The token whose score should be updated
    /// @param newScore   New raw credit score in the range [0, 1000]
    /// @param zkVerified Whether this update is accompanied by a valid ZK proof
    function updateScore(
        uint256 tokenId,
        uint16 newScore,
        bool zkVerified
    ) external;

    // -------------------------------------------------------------------------
    // Read functions
    // -------------------------------------------------------------------------

    /// @notice Retrieve the current credit profile for a given wallet
    /// @param wallet The wallet address to query
    /// @return score      Raw credit score (0–1000)
    /// @return tier       Derived tier (0=Unverified, 1=Bronze, 2=Silver, 3=Gold)
    /// @return zkVerified Whether the most recent update was ZK-verified
    function getScore(address wallet)
        external
        view
        returns (
            uint16 score,
            uint8 tier,
            bool zkVerified
        );

    /// @notice Derive the tier from an arbitrary score value
    /// @dev    Pure function — no state reads required.
    ///         Tier boundaries:
    ///           0 = Unverified  (score <  300)
    ///           1 = Bronze      (300 <= score < 600)
    ///           2 = Silver      (600 <= score < 800)
    ///           3 = Gold        (score >= 800)
    /// @param score Raw credit score to evaluate
    /// @return tier The corresponding tier index
    function getTier(uint16 score) external pure returns (uint8 tier);

    /// @notice Look up the token ID associated with a wallet
    /// @dev    Returns 0 if the wallet has never been minted a token
    ///         (token IDs start at 1).
    /// @param wallet The wallet address to query
    /// @return The token ID owned by `wallet`, or 0 if none
    function getTokenId(address wallet) external view returns (uint256);
}
