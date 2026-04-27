// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICreditLendingPool
/// @notice Interface for the CreditLayer credit-score-gated lending pool
interface ICreditLendingPool {
    // -------------------------------------------------------------------------
    // Enums
    // -------------------------------------------------------------------------

    /// @notice Lifecycle states for a loan position
    enum LoanStatus {
        Active,     // 0 — loan is open and accruing interest
        Repaid,     // 1 — borrower has fully repaid principal + interest
        Liquidated  // 2 — collateral was seized by a liquidator
    }

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Full on-chain record of a single loan position
    struct LoanPosition {
        /// @dev Monotonically increasing loan identifier
        uint256 id;
        /// @dev Address that opened the loan
        address borrower;
        /// @dev USDC principal borrowed (6-decimal)
        uint256 principal;
        /// @dev ETH collateral locked at open (in wei)
        uint256 collateral;
        /// @dev Collateral ratio at origination expressed in basis points
        ///      e.g. 15000 = 150 %
        uint256 collateralRatio;
        /// @dev Unix timestamp when the loan was opened
        uint64 openedAt;
        /// @dev Unix timestamp of the nominal due date (informational)
        uint64 dueAt;
        /// @dev Current lifecycle status of this loan
        LoanStatus status;
        /// @dev Annual interest rate in basis points, e.g. 900 = 9 %
        uint16 interestRateBps;
        /// @dev Accrued interest cached at last interaction (6-decimal USDC)
        uint256 interestAccrued;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new loan is opened
    /// @param loanId          Unique loan identifier
    /// @param borrower        Address that opened the loan
    /// @param principal       USDC borrowed (6-decimal)
    /// @param collateral      ETH collateral deposited (wei)
    /// @param interestRateBps Annual rate in basis points
    event LoanOpened(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 principal,
        uint256 collateral,
        uint16 interestRateBps
    );

    /// @notice Emitted when a borrower fully repays their loan
    /// @param loanId    Unique loan identifier
    /// @param borrower  Address that repaid
    /// @param principal Original USDC principal (6-decimal)
    /// @param interest  Total interest paid (6-decimal)
    event LoanRepaid(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 principal,
        uint256 interest
    );

    /// @notice Emitted when an under-collateralised loan is liquidated
    /// @param loanId          Unique loan identifier
    /// @param liquidator      Address that triggered the liquidation
    /// @param collateralSeized Total ETH collateral seized by liquidator (wei)
    /// @param bonus           Liquidation bonus paid to liquidator (wei)
    event LoanLiquidated(
        uint256 indexed loanId,
        address indexed liquidator,
        uint256 collateralSeized,
        uint256 bonus
    );

    /// @notice Emitted when extra collateral is deposited into an existing loan
    /// @param loanId  Unique loan identifier
    /// @param amount  Additional ETH deposited (wei)
    event CollateralDeposited(
        uint256 indexed loanId,
        uint256 amount
    );



    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /// @notice Open a new collateralised USDC loan
    /// @dev    Caller must send ETH as collateral (msg.value).
    ///         The pool validates the credit score via ICreditScoreNFT,
    ///         checks collateral sufficiency and (optionally) verifies a ZK
    ///         proof before transferring USDC to the borrower.
    /// @param usdcAmount     Amount of USDC to borrow (6-decimal)
    /// @param zkProof        Encoded ZK proof bytes (may be empty if zkVerifier == address(0))
    /// @param scoreThreshold Minimum score the caller claims to have; used as
    ///                       an early revert hint before the on-chain lookup
    function borrow(
        uint256 usdcAmount,
        bytes calldata zkProof,
        uint256 scoreThreshold
    ) external payable;

    /// @notice Repay an active loan in full (principal + accrued interest)
    /// @dev    Caller must have approved the pool to spend at least
    ///         principal + accrued interest worth of USDC.
    ///         On success the locked ETH collateral is returned to the borrower.
    /// @param loanId The identifier of the loan to repay
    function repay(uint256 loanId) external;

    /// @notice Seize the collateral of an under-collateralised loan
    /// @dev    Reverts with HealthFactorTooLow if the loan is still healthy.
    ///         The liquidator must supply USDC to cover the outstanding debt.
    ///         A 5 % bonus on the collateral is awarded to the liquidator.
    /// @param loanId The identifier of the loan to liquidate
    function liquidate(uint256 loanId) external;

    // -------------------------------------------------------------------------
    // Read functions
    // -------------------------------------------------------------------------

    /// @notice Fetch the full loan record for a given loan ID
    /// @param loanId The loan identifier to look up
    /// @return The LoanPosition struct for that loan
    function getLoan(uint256 loanId)
        external
        view
        returns (LoanPosition memory);

    /// @notice Compute the current health factor for an open loan
    /// @dev    Defined as:
    ///           healthFactor = collateralValueUSD * 1e18 / (principal + accruedInterest)
    ///         A value >= 1e18 means the loan is sufficiently collateralised.
    ///         A value <  1e18 means the loan is liquidatable.
    /// @param loanId The loan identifier to evaluate
    /// @return Health factor in 1e18 fixed-point scale
    function getHealthFactor(uint256 loanId)
        external
        view
        returns (uint256);
}
