// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice A minimal ERC-20 mock of USDC for testnet and local development use.
///         Mints 10,000,000 mUSDC to the deployer on construction and exposes
///         an unrestricted public mint — do NOT deploy to mainnet.
contract MockUSDC is ERC20 {
    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy MockUSDC, minting the initial supply to the deployer.
    constructor() ERC20("Mock USDC", "mUSDC") {
        // 10,000,000 mUSDC — note 6-decimal precision
        _mint(msg.sender, 10_000_000 * 10 ** decimals());
    }

    // -------------------------------------------------------------------------
    // Overrides
    // -------------------------------------------------------------------------

    /// @notice ERC-20 tokens typically use 18 decimals; USDC uses 6.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // -------------------------------------------------------------------------
    // Testnet helpers
    // -------------------------------------------------------------------------

    /// @notice Mint an arbitrary amount of mUSDC to any address.
    /// @dev    No access control is intentional — this is a testnet-only token.
    ///         Anyone can call this to fund their wallet without needing a faucet.
    /// @param to     Recipient address
    /// @param amount Amount to mint in the smallest unit (1 mUSDC = 1e6)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
