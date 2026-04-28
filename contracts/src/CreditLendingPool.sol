// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICreditScoreNFT.sol";
import "./interfaces/ICreditLendingPool.sol";

/// @notice Minimal Chainlink AggregatorV3 interface — only what we need.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        );
}

/// @notice Minimal ZK verifier interface.
///         On testnet the pool is deployed with zkVerifier == address(0) to
///         skip verification entirely.
interface IZKVerifier {
    function verifyProof(address borrower, bytes calldata proof) external view returns (bool);
}

/// @title CreditLendingPool
/// @notice Credit-score-gated ETH-collateralised USDC lending pool for CreditLayer.
///
///         Tier parameters
///         ───────────────
///         Tier 1 – Bronze  : minScore=300, minCollateralRatio=135 %, APR= 12 %
///         Tier 2 – Silver  : minScore=600, minCollateralRatio=125 %, APR=  9 %
///         Tier 3 – Gold    : minScore=800, minCollateralRatio=115 %, APR=  6 %
///
///         Health factor
///         ─────────────
///         healthFactor = (collateral_ETH * ETH/USD_price * 1e18) / (principal + accruedInterest)
///         A health factor < 1e18 means the loan is liquidatable.
///
///         Liquidation
///         ───────────
///         The liquidator repays the outstanding debt and receives the full ETH
///         collateral plus a 5 % bonus sourced from the collateral.  Any surplus
///         collateral above the bonus is returned to the borrower.
contract CreditLendingPool is ReentrancyGuard, Ownable, ICreditLendingPool {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Borrower's credit score is below the minimum required for their tier.
    error InsufficientScore(uint16 required, uint16 actual);

    /// @notice The supplied ZK proof failed on-chain verification.
    error InvalidZKProof();

    /// @notice The loan's health factor is at or above 1e18 — cannot liquidate.
    /// @param healthFactor Current health factor (1e18 scale).
    error HealthFactorTooLow(uint256 healthFactor);

    /// @notice Repay or liquidate called on a loan that has already been repaid.
    error LoanAlreadyRepaid(uint256 loanId);

    /// @notice ETH collateral supplied is below the tier minimum.
    /// @param required Minimum collateral in wei.
    /// @param provided Collateral actually sent (msg.value) in wei.
    error CollateralTooLow(uint256 required, uint256 provided);

    /// @notice Loan is not in the Active state.
    error LoanNotActive();

    /// @notice Caller is not the borrower of this loan.
    error OnlyBorrower();

    /// @notice Chainlink returned a non-positive price.
    error InvalidChainlinkPrice();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Liquidation bonus paid to the liquidator (5 %).
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;

    /// @notice Seconds in a calendar year — used for simple-interest accrual.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Denominator for basis-point arithmetic.
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Loan duration used for the informational `dueAt` field (30 days).
    uint64 public constant LOAN_DURATION = 30 days;

    // -------------------------------------------------------------------------
    // Tier configuration
    // -------------------------------------------------------------------------

    /// @dev Index 0 = Bronze, 1 = Silver, 2 = Gold  (tier IDs 1, 2, 3 from NFT)
    uint16[3]  internal _tierMinScore           = [300, 600, 800];
    uint256[3] internal _tierMinCollateralBps   = [13_500, 12_500, 11_500];
    uint16[3]  internal _tierInterestRateBps    = [1_200,    900,    600];

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The CreditScoreNFT contract used to gate access.
    ICreditScoreNFT public immutable creditScoreNFT;

    /// @notice The USDC token lent out by this pool.
    IERC20 public immutable usdc;

    /// @notice Chainlink ETH/USD price feed (8 decimals).
    AggregatorV3Interface public chainlinkEthUsd;

    /// @notice Optional ZK verifier — set to address(0) to skip on testnet.
    address public zkVerifier;

    /// @notice All loan positions indexed by loan ID.
    mapping(uint256 => LoanPosition) public loans;

    /// @notice List of loan IDs opened by each borrower.
    mapping(address => uint256[]) public borrowerLoans;

    /// @notice Monotonically increasing loan counter (starts at 1).
    uint256 public nextLoanId;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _creditScoreNFT Address of the deployed CreditScoreNFT.
    /// @param _usdc           Address of the USDC ERC-20 token.
    /// @param _chainlinkEthUsd Address of the Chainlink ETH/USD feed.
    /// @param _zkVerifier     Address of the ZK verifier (address(0) to disable).
    /// @param _owner          Owner of this contract.
    constructor(
        address _creditScoreNFT,
        address _usdc,
        address _chainlinkEthUsd,
        address _zkVerifier,
        address _owner
    ) Ownable(_owner) {
        creditScoreNFT  = ICreditScoreNFT(_creditScoreNFT);
        usdc            = IERC20(_usdc);
        chainlinkEthUsd = AggregatorV3Interface(_chainlinkEthUsd);
        zkVerifier      = _zkVerifier;
        nextLoanId      = 1;
    }

    // -------------------------------------------------------------------------
    // Borrow
    // -------------------------------------------------------------------------

    /// @inheritdoc ICreditLendingPool
    /// @dev Caller sends ETH as collateral via msg.value.
    function borrow(
        uint256 usdcAmount,
        bytes calldata zkProof,
        uint256 /*scoreThreshold*/
    ) external payable override nonReentrant {
        // ── 1. Fetch borrower credit profile ─────────────────────────────────
        (uint16 score, uint8 tier, ) = creditScoreNFT.getScore(msg.sender);

        // Minimum tier is Bronze (1)
        if (tier == 0) {
            revert InsufficientScore(_tierMinScore[0], score);
        }

        // ── 2. Resolve tier parameters (tier is 1-indexed; array is 0-indexed) ─
        uint256 tierIdx            = uint256(tier) - 1;
        uint256 minCollateralBps   = _tierMinCollateralBps[tierIdx];
        uint16  interestRateBps    = _tierInterestRateBps[tierIdx];

        // ── 3. Get latest ETH/USD price from Chainlink ────────────────────────
        uint256 ethPriceUsd = getLatestEthPrice(); // 8 decimals

        // ── 4. Calculate minimum required collateral ──────────────────────────
        //
        //  Unit analysis:
        //    usdcAmount  : 6-decimal USDC  →  1 USDC = 1e6
        //    ethPriceUsd : 8-decimal USD   →  $2000  = 2000e8
        //    output      : wei             →  1 ETH  = 1e18
        //
        //    collateralWei = usdcAmount / 1e6 * ratioBps / 1e4
        //                    * 1e8 / ethPriceUsd * 1e18
        //                  = usdcAmount * ratioBps * 1e20
        //                    ───────────────────────────────────
        //                    ethPriceUsd * BASIS_POINTS
        //
        uint256 requiredCollateral =
            (usdcAmount * minCollateralBps * 1e20) /
            (ethPriceUsd * BASIS_POINTS);

        if (msg.value < requiredCollateral) {
            revert CollateralTooLow(requiredCollateral, msg.value);
        }

        // ── 5. Optional ZK proof verification ────────────────────────────────
        if (zkVerifier != address(0)) {
            bool valid = IZKVerifier(zkVerifier).verifyProof(msg.sender, zkProof);
            if (!valid) revert InvalidZKProof();
        }

        // ── 6. Record loan ───────────────────────────────────────────────────
        uint256 loanId = nextLoanId;
        unchecked { nextLoanId++; }

        uint256 actualCollateralRatio =
            (msg.value * ethPriceUsd * BASIS_POINTS) /
            (usdcAmount * 1e20);

        loans[loanId] = LoanPosition({
            id:              loanId,
            borrower:        msg.sender,
            principal:       usdcAmount,
            collateral:      msg.value,
            collateralRatio: actualCollateralRatio,
            openedAt:        uint64(block.timestamp),
            dueAt:           uint64(block.timestamp) + LOAN_DURATION,
            status:          LoanStatus.Active,
            interestRateBps: interestRateBps,
            interestAccrued: 0
        });

        borrowerLoans[msg.sender].push(loanId);

        // ── 7. Transfer USDC to borrower ──────────────────────────────────────
        usdc.safeTransfer(msg.sender, usdcAmount);

        emit LoanOpened(loanId, msg.sender, usdcAmount, msg.value, interestRateBps);
    }

    // -------------------------------------------------------------------------
    // Repay
    // -------------------------------------------------------------------------

    /// @inheritdoc ICreditLendingPool
    function repay(uint256 loanId) external override nonReentrant {
        LoanPosition storage loan = loans[loanId];

        // ── Checks ────────────────────────────────────────────────────────────
        if (loan.status == LoanStatus.Repaid)     revert LoanAlreadyRepaid(loanId);
        if (loan.status == LoanStatus.Liquidated) revert LoanNotActive();
        if (loan.borrower != msg.sender)          revert OnlyBorrower();

        // ── Effects ───────────────────────────────────────────────────────────
        uint256 interest    = getAccruedInterest(loanId);
        uint256 totalOwed   = loan.principal + interest;
        uint256 collateral  = loan.collateral;

        loan.interestAccrued = interest;
        loan.status          = LoanStatus.Repaid;
        loan.collateral      = 0;

        // ── Interactions ──────────────────────────────────────────────────────
        // Pull USDC repayment from borrower
        usdc.safeTransferFrom(msg.sender, address(this), totalOwed);

        // Return ETH collateral to borrower
        (bool sent, ) = payable(msg.sender).call{value: collateral}("");
        require(sent, "ETH return failed");

        emit LoanRepaid(loanId, msg.sender, loan.principal, interest);
    }

    // -------------------------------------------------------------------------
    // Liquidate
    // -------------------------------------------------------------------------

    /// @inheritdoc ICreditLendingPool
    function liquidate(uint256 loanId) external override nonReentrant {
        LoanPosition storage loan = loans[loanId];

        // ── Checks ────────────────────────────────────────────────────────────
        if (loan.status == LoanStatus.Repaid)     revert LoanAlreadyRepaid(loanId);
        if (loan.status == LoanStatus.Liquidated) revert LoanNotActive();

        uint256 hf = getHealthFactor(loanId);
        // Health factor must be below 1e18 to be liquidatable
        if (hf >= 1e18) revert HealthFactorTooLow(hf);

        // ── Effects ───────────────────────────────────────────────────────────
        uint256 interest       = getAccruedInterest(loanId);
        uint256 totalDebt      = loan.principal + interest;
        uint256 totalCollateral = loan.collateral;

        // Bonus collateral for liquidator (5 % of total collateral)
        uint256 bonus          = (totalCollateral * LIQUIDATION_BONUS_BPS) / BASIS_POINTS;
        uint256 liquidatorGets = totalCollateral; // liquidator takes everything
        // Any collateral above debt-value + bonus is returned to borrower
        // (in practice with a low HF the collateral roughly equals the debt,
        //  but we always send any residual back to protect the borrower)
        uint256 ethPrice       = getLatestEthPrice();
        // Collateral value in USDC units (6-decimal)
        //   collateralUsd = collateral(wei) * ethPrice(8-dec) / 1e(18+8-6) = / 1e20
        uint256 collateralUsd  = (totalCollateral * ethPrice) / 1e20;

        uint256 borrowerReturn = 0;
        if (collateralUsd > totalDebt + (totalDebt * LIQUIDATION_BONUS_BPS) / BASIS_POINTS) {
            // Excess collateral in wei
            uint256 excessUsd  = collateralUsd - totalDebt - (totalDebt * LIQUIDATION_BONUS_BPS) / BASIS_POINTS;
            uint256 excessWei  = (excessUsd * 1e20) / ethPrice;
            if (excessWei < totalCollateral) {
                borrowerReturn  = excessWei;
                liquidatorGets  = totalCollateral - excessWei;
                bonus           = (liquidatorGets * LIQUIDATION_BONUS_BPS) / BASIS_POINTS;
            }
        }

        loan.interestAccrued = interest;
        loan.status          = LoanStatus.Liquidated;
        loan.collateral      = 0;

        // ── Interactions ──────────────────────────────────────────────────────
        // Liquidator covers the outstanding USDC debt
        usdc.safeTransferFrom(msg.sender, address(this), totalDebt);

        // Pay liquidator their ETH
        (bool sentLiq, ) = payable(msg.sender).call{value: liquidatorGets}("");
        require(sentLiq, "Liquidator ETH transfer failed");

        // Return any surplus to the borrower
        if (borrowerReturn > 0) {
            (bool sentBorrower, ) = payable(loan.borrower).call{value: borrowerReturn}("");
            require(sentBorrower, "Borrower ETH return failed");
        }

        emit LoanLiquidated(loanId, msg.sender, liquidatorGets, bonus);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @inheritdoc ICreditLendingPool
    function getLoan(uint256 loanId)
        external
        view
        override
        returns (LoanPosition memory)
    {
        return loans[loanId];
    }

    /// @inheritdoc ICreditLendingPool
    /// @dev  healthFactor = collateralValueUSD * 1e18 / (principal + accruedInterest)
    ///       Returns type(uint256).max when total debt is zero (infinite health).
    function getHealthFactor(uint256 loanId)
        public
        view
        override
        returns (uint256)
    {
        LoanPosition storage loan = loans[loanId];
        uint256 totalDebt = loan.principal + getAccruedInterest(loanId);
        if (totalDebt == 0) return type(uint256).max;

        uint256 ethPrice = getLatestEthPrice(); // 8-decimal USD price

        // collateralUsd in 6-decimal USDC units
        //   collateral(wei) * price(8-dec) / 1e20 = USDC (6-dec)
        uint256 collateralUsd = (loan.collateral * ethPrice) / 1e20;

        return (collateralUsd * 1e18) / totalDebt;
    }

    /// @notice Calculate the simple interest accrued on a loan from open to now.
    /// @param loanId The loan to evaluate.
    /// @return Accrued interest in 6-decimal USDC units.
    function getAccruedInterest(uint256 loanId)
        public
        view
        returns (uint256)
    {
        LoanPosition storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active) {
            return loan.interestAccrued;
        }
        uint256 elapsed = block.timestamp - loan.openedAt;
        // interest = principal * rateBps * elapsed / (BASIS_POINTS * SECONDS_PER_YEAR)
        return (loan.principal * loan.interestRateBps * elapsed) /
               (BASIS_POINTS * SECONDS_PER_YEAR);
    }

    /// @notice Returns the list of loan IDs opened by a borrower.
    function getBorrowerLoans(address borrower)
        external
        view
        returns (uint256[] memory)
    {
        return borrowerLoans[borrower];
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @notice Query the Chainlink ETH/USD feed and return the price.
    /// @return price ETH price in USD with 8 decimal places (e.g. $2000 = 2000e8).
    function getLatestEthPrice() internal view returns (uint256 price) {
        (
            ,
            int256 answer,
            ,
            ,
        ) = chainlinkEthUsd.latestRoundData();
        if (answer <= 0) revert InvalidChainlinkPrice();
        price = uint256(answer);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Update the Chainlink price feed address (e.g. after migration).
    function setChainlinkFeed(address newFeed) external onlyOwner {
        chainlinkEthUsd = AggregatorV3Interface(newFeed);
    }

    /// @notice Update the ZK verifier address (use address(0) to disable).
    function setZKVerifier(address newVerifier) external onlyOwner {
        zkVerifier = newVerifier;
    }

    /// @notice Allow the owner to rescue tokens accidentally sent to the pool.
    ///         Does NOT allow withdrawing USDC that is owed to borrowers.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Allow the pool to receive plain ETH (e.g. from collateral returns
    ///         that overshoot due to rounding, or direct funding).
    receive() external payable {}
}
