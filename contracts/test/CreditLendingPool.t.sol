// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/CreditLendingPool.sol";
import "../src/CreditScoreNFT.sol";
import "../src/MockUSDC.sol";

// ---------------------------------------------------------------------------
// MockV3Aggregator
// ---------------------------------------------------------------------------
// Minimal Chainlink AggregatorV3Interface mock that lets tests control the
// ETH/USD price.  Prices use 8 decimal places (e.g. $2 000 == 2000e8).
// ---------------------------------------------------------------------------
contract MockV3Aggregator {
    int256  public latestAnswer;
    uint8   public decimals = 8;
    uint80  private _roundId;

    constructor(int256 _initialAnswer) {
        latestAnswer = _initialAnswer;
        _roundId     = 1;
    }

    /// @notice Simulate a price update.
    function updateAnswer(int256 _answer) external {
        latestAnswer = _answer;
        _roundId++;
    }

    /// @notice Subset of AggregatorV3Interface used by CreditLendingPool.
    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        )
    {
        return (
            _roundId,
            latestAnswer,
            block.timestamp,
            block.timestamp,
            _roundId
        );
    }
}

// ---------------------------------------------------------------------------
// CreditLendingPoolTest
// ---------------------------------------------------------------------------
contract CreditLendingPoolTest is Test {
    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------
    CreditLendingPool internal pool;
    CreditScoreNFT    internal nft;
    MockUSDC          internal usdc;
    MockV3Aggregator  internal priceFeed;

    // -------------------------------------------------------------------------
    // Named actors
    // -------------------------------------------------------------------------
    address internal owner      = makeAddr("owner");
    address internal oracleAddr = makeAddr("oracleEOA");
    address internal borrower   = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal other      = makeAddr("other");

    // -------------------------------------------------------------------------
    // Constants mirrored from the pool
    // -------------------------------------------------------------------------
    int256  constant INITIAL_ETH_PRICE     = 2_000e8; // $2 000 with 8 dec
    int256  constant CRASH_ETH_PRICE       = 500e8;   // $500  with 8 dec

    uint256 constant POOL_SEED_USDC        = 1_000_000e6; // 1 M mUSDC (6 dec)
    uint256 constant BORROWER_SEED_USDC    = 500_000e6;   // 500 k mUSDC

    // Tier parameters (same as contract internals)
    uint256 constant BRONZE_COLLAT_BPS = 13_500;
    uint256 constant SILVER_COLLAT_BPS = 12_500;
    uint256 constant GOLD_COLLAT_BPS   = 11_500;

    uint16  constant GOLD_RATE_BPS     = 600;  // 6 % APR

    uint256 constant BASIS_POINTS      = 10_000;
    uint256 constant SECONDS_PER_YEAR  = 365 days;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------
    function setUp() public {
        // Deploy as owner ─────────────────────────────────────────────────────
        vm.startPrank(owner);

        usdc      = new MockUSDC();                        // mints 10 M to owner
        priceFeed = new MockV3Aggregator(INITIAL_ETH_PRICE);
        nft       = new CreditScoreNFT(owner, oracleAddr); // oracle = oracleAddr
        pool      = new CreditLendingPool(
            address(nft),
            address(usdc),
            address(priceFeed),
            address(0),   // zkVerifier == 0 → skip ZK checks
            owner
        );

        // Seed pool with USDC liquidity
        usdc.transfer(address(pool), POOL_SEED_USDC);

        vm.stopPrank();

        // Mint Gold-tier NFT for the borrower ─────────────────────────────────
        // Gold tier = score >= 800, getTier returns 3
        _grantScore(borrower, 850, true);

        // Give borrower USDC so they can repay loans
        vm.prank(owner);
        usdc.mint(borrower, BORROWER_SEED_USDC);

        // Give liquidator USDC so they can cover debt during liquidation
        vm.prank(owner);
        usdc.mint(liquidator, POOL_SEED_USDC);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Mints (or updates) a credit-score NFT for `wallet` via the oracle.
    ///      Warps past the 24-hour update cooldown when needed.
    function _grantScore(address wallet, uint16 score, bool zkVerified) internal {
        vm.startPrank(oracleAddr);
        uint256 tokenId = nft.getTokenId(wallet);
        if (tokenId == 0) {
            tokenId = nft.mintScore(wallet);
        } else {
            vm.warp(block.timestamp + nft.UPDATE_COOLDOWN() + 1);
        }
        nft.updateScore(tokenId, score, zkVerified);
        vm.stopPrank();
    }

    /// @dev Replicate the pool's minimum-collateral formula:
    ///      requiredWei = usdcAmount * minCollBps * 1e20
    ///                    ─────────────────────────────────
    ///                    ethPrice8dec * 10_000
    function _calcRequiredCollateral(
        uint256 usdcAmount,
        uint256 tierMinCollBps
    ) internal view returns (uint256) {
        uint256 ethPrice = uint256(priceFeed.latestAnswer());
        return (usdcAmount * tierMinCollBps * 1e20)
            / (ethPrice * BASIS_POINTS);
    }

    /// @dev Simple-interest accrual matching the pool formula.
    function _calcAccruedInterest(
        uint256 principal,
        uint16  rateBps,
        uint256 elapsed
    ) internal pure returns (uint256) {
        return (principal * uint256(rateBps) * elapsed)
            / (BASIS_POINTS * SECONDS_PER_YEAR);
    }

    /// @dev Open a loan at Gold tier, return loanId.
    function _openGoldLoan(uint256 usdcAmount) internal returns (uint256 loanId) {
        uint256 required = _calcRequiredCollateral(usdcAmount, GOLD_COLLAT_BPS);
        uint256 collat   = required * 130 / 100; // 30 % buffer
        vm.deal(borrower, collat + 5 ether);
        vm.prank(borrower);
        pool.borrow{value: collat}(usdcAmount, "", 0);
        loanId = pool.nextLoanId() - 1;
    }

    // =========================================================================
    // Tests
    // =========================================================================

    // ─── 1. Basic borrow → repay happy path ──────────────────────────────────
    function test_BorrowAndRepay() public {
        uint256 usdcAmount = 1_000e6;
        uint256 required   = _calcRequiredCollateral(usdcAmount, GOLD_COLLAT_BPS);
        uint256 collatSent = required * 130 / 100;

        vm.deal(borrower, collatSent + 2 ether);

        uint256 usdcBefore = usdc.balanceOf(borrower);

        // Borrow
        vm.prank(borrower);
        pool.borrow{value: collatSent}(usdcAmount, "", 0);

        uint256 loanId = pool.nextLoanId() - 1;
        assertEq(usdc.balanceOf(borrower), usdcBefore + usdcAmount, "USDC not received");

        // Confirm loan is Active
        ICreditLendingPool.LoanPosition memory loanBefore = pool.getLoan(loanId);
        assertEq(uint8(loanBefore.status), uint8(ICreditLendingPool.LoanStatus.Active));

        // Warp 1 day forward so interest accrues
        vm.warp(block.timestamp + 1 days);

        uint256 interest  = pool.getAccruedInterest(loanId);
        uint256 totalOwed = usdcAmount + interest;

        // Approve repayment amount
        vm.startPrank(borrower);
        usdc.approve(address(pool), totalOwed);
        uint256 ethBeforeRepay = borrower.balance;
        pool.repay(loanId);
        vm.stopPrank();

        // Loan should now be Repaid
        ICreditLendingPool.LoanPosition memory loanAfter = pool.getLoan(loanId);
        assertEq(uint8(loanAfter.status), uint8(ICreditLendingPool.LoanStatus.Repaid));

        // ETH collateral should have been returned
        assertGt(borrower.balance, ethBeforeRepay, "collateral not returned");
        assertApproxEqAbs(borrower.balance, ethBeforeRepay + collatSent, 1);
    }

    // ─── 2. CollateralTooLow revert ───────────────────────────────────────────
    function test_CollateralTooLow() public {
        vm.deal(borrower, 10 ether);

        uint256 usdcAmount = 1_000e6;
        uint256 required   = _calcRequiredCollateral(usdcAmount, GOLD_COLLAT_BPS);

        // Send only 1 wei ─ far below the minimum
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditLendingPool.CollateralTooLow.selector,
                required,
                uint256(1)
            )
        );
        pool.borrow{value: 1}(usdcAmount, "", 0);
    }

    // ─── 3. InsufficientScore — wallet has no NFT ─────────────────────────────
    function test_InsufficientScore_NoNFT() public {
        address noNftWallet = makeAddr("noNft");
        vm.deal(noNftWallet, 10 ether);

        // Score=0, tier=0 → below Bronze minimum of 300
        // The pool reverts with InsufficientScore(required=300, actual=0)
        vm.prank(noNftWallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditLendingPool.InsufficientScore.selector,
                uint16(300),
                uint16(0)
            )
        );
        pool.borrow{value: 1 ether}(100e6, "", 0);
    }

    // ─── 4. Liquidation after price crash ────────────────────────────────────
    function test_Liquidation() public {
        uint256 usdcAmount = 1_000e6;
        uint256 loanId     = _openGoldLoan(usdcAmount);

        // Crash the ETH price to $500 — collateral value drops ~75 %
        priceFeed.updateAnswer(CRASH_ETH_PRICE);

        // Health factor must be below 1e18
        uint256 hf = pool.getHealthFactor(loanId);
        assertLt(hf, 1e18, "health factor should be < 1e18 after price crash");

        // Liquidator approves debt + interest
        uint256 interest  = pool.getAccruedInterest(loanId);
        uint256 totalDebt = usdcAmount + interest;

        vm.startPrank(liquidator);
        usdc.approve(address(pool), totalDebt);

        uint256 ethBefore = liquidator.balance;
        pool.liquidate(loanId);
        vm.stopPrank();

        // Loan should now be Liquidated
        ICreditLendingPool.LoanPosition memory loan = pool.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(ICreditLendingPool.LoanStatus.Liquidated));

        // Liquidator should have received ETH collateral
        assertGt(liquidator.balance, ethBefore, "liquidator ETH not received");
    }

    // ─── 5. Cannot liquidate a healthy loan ───────────────────────────────────
    function test_CannotLiquidateHealthyLoan() public {
        uint256 loanId = _openGoldLoan(1_000e6);

        // Health factor should be well above 1e18 immediately after open
        uint256 hf = pool.getHealthFactor(loanId);
        assertGe(hf, 1e18, "fresh loan should be healthy");

        // Attempt liquidation on healthy loan should revert
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditLendingPool.HealthFactorTooLow.selector,
                hf
            )
        );
        pool.liquidate(loanId);
        vm.stopPrank();
    }

    // ─── 6. Health factor is >= 1e18 at open ─────────────────────────────────
    function test_HealthFactor_AboveOne_AtOpen() public {
        uint256 loanId = _openGoldLoan(1_000e6);
        uint256 hf     = pool.getHealthFactor(loanId);
        assertGe(hf, 1e18, "health factor should be >= 1e18 at open");
    }

    // ─── 7. Interest accrual after 1 day ─────────────────────────────────────
    function test_InterestAccrual_1Day() public {
        uint256 usdcAmount = 1_000e6;
        uint256 loanId     = _openGoldLoan(usdcAmount);

        ICreditLendingPool.LoanPosition memory loan = pool.getLoan(loanId);
        uint256 openedAt = loan.openedAt;

        uint256 elapsed = 1 days;
        vm.warp(openedAt + elapsed);

        uint256 expected = _calcAccruedInterest(usdcAmount, GOLD_RATE_BPS, elapsed);
        uint256 actual   = pool.getAccruedInterest(loanId);

        assertEq(actual, expected, "1-day interest mismatch");
        assertGt(actual, 0, "interest should be non-zero after 1 day");
    }

    // ─── 8. Interest accrual after 7 days ────────────────────────────────────
    function test_InterestAccrual_7Days() public {
        uint256 usdcAmount = 1_000e6;
        uint256 loanId     = _openGoldLoan(usdcAmount);

        ICreditLendingPool.LoanPosition memory loan = pool.getLoan(loanId);
        uint256 openedAt = loan.openedAt;

        uint256 elapsed = 7 days;
        vm.warp(openedAt + elapsed);

        uint256 expected = _calcAccruedInterest(usdcAmount, GOLD_RATE_BPS, elapsed);
        uint256 actual   = pool.getAccruedInterest(loanId);

        assertEq(actual, expected, "7-day interest mismatch");
    }

    // ─── 9. Interest accrual after 30 days ───────────────────────────────────
    function test_InterestAccrual_30Days() public {
        uint256 usdcAmount = 1_000e6;
        uint256 loanId     = _openGoldLoan(usdcAmount);

        ICreditLendingPool.LoanPosition memory loan = pool.getLoan(loanId);
        uint256 openedAt = loan.openedAt;

        uint256 elapsed = 30 days;
        vm.warp(openedAt + elapsed);

        uint256 expected = _calcAccruedInterest(usdcAmount, GOLD_RATE_BPS, elapsed);
        uint256 actual   = pool.getAccruedInterest(loanId);

        assertEq(actual, expected, "30-day interest mismatch");
    }

    // ─── 10. Cannot liquidate at exact health factor 1.0 ─────────────────────
    function test_Liquidation_RevertsAtExactHealthFactorOne() public {
        uint256 usdcAmount = 1_000e6;

        // At $1,000/ETH, 1 ETH collateral is worth exactly 1,000 USDC.
        // With zero elapsed time, healthFactor should be exactly 1e18.
        vm.deal(borrower, 2 ether);
        vm.prank(borrower);
        pool.borrow{value: 1 ether}(usdcAmount, "", 0);
        uint256 loanId = pool.nextLoanId() - 1;

        priceFeed.updateAnswer(1_000e8);

        uint256 hf = pool.getHealthFactor(loanId);
        assertEq(hf, 1e18, "health factor should be exactly 1.0");

        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditLendingPool.HealthFactorTooLow.selector,
                uint256(1e18)
            )
        );
        pool.liquidate(loanId);
        vm.stopPrank();
    }

    // ─── 11. Cannot repay an already-repaid loan ──────────────────────────────
    function test_LoanAlreadyRepaid() public {
        uint256 usdcAmount = 1_000e6;
        uint256 loanId     = _openGoldLoan(usdcAmount);

        // First repayment
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(loanId);

        // Second repayment should revert with LoanAlreadyRepaid
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditLendingPool.LoanAlreadyRepaid.selector,
                loanId
            )
        );
        pool.repay(loanId);
        vm.stopPrank();
    }

    // ─── 12. Only the borrower can repay ─────────────────────────────────────
    function test_OnlyBorrower_CanRepay() public {
        uint256 loanId = _openGoldLoan(1_000e6);

        // Fund `other` with USDC and ETH so the call doesn't revert for other
        // reasons
        vm.prank(owner);
        usdc.mint(other, 100_000e6);
        vm.deal(other, 1 ether);

        vm.startPrank(other);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(CreditLendingPool.OnlyBorrower.selector);
        pool.repay(loanId);
        vm.stopPrank();
    }

    // ─── 13. Fuzz — arbitrary borrow amounts always produce HF >= 1e18 ───────
    /// @dev Uses vm.deal to provide adequate ETH for the exact required
    ///      collateral plus a 30 % safety buffer.
    function fuzz_BorrowAmount(uint256 rawAmount) public {
        // Bound: 1 USDC (1e6) to 10 000 USDC (10_000e6)
        uint256 usdcAmount = bound(rawAmount, 1e6, 10_000e6);

        // Ensure pool has enough USDC liquidity (refund + reseed if needed)
        uint256 poolBalance = usdc.balanceOf(address(pool));
        if (poolBalance < usdcAmount) {
            vm.prank(owner);
            usdc.mint(address(pool), usdcAmount - poolBalance + 1e6);
        }

        uint256 required   = _calcRequiredCollateral(usdcAmount, GOLD_COLLAT_BPS);
        uint256 collatSent = required * 130 / 100; // 30 % buffer

        vm.deal(borrower, collatSent + 1 ether);

        vm.prank(borrower);
        pool.borrow{value: collatSent}(usdcAmount, "", 0);

        uint256 loanId = pool.nextLoanId() - 1;
        uint256 hf     = pool.getHealthFactor(loanId);

        assertGe(hf, 1e18, "health factor must be >= 1e18 at open");
    }

    // ─── 14. Liquidator receives collateral (bonus / full) ───────────────────
    function test_LiquidatorGetsBonus() public {
        uint256 usdcAmount = 1_000e6;
        uint256 loanId     = _openGoldLoan(usdcAmount);

        ICreditLendingPool.LoanPosition memory loan = pool.getLoan(loanId);
        uint256 totalCollateral = loan.collateral;
        assertGt(totalCollateral, 0, "collateral should be > 0");

        // Drop price so the loan is liquidatable
        priceFeed.updateAnswer(CRASH_ETH_PRICE);

        uint256 interest  = pool.getAccruedInterest(loanId);
        uint256 totalDebt = usdcAmount + interest;

        vm.startPrank(liquidator);
        usdc.approve(address(pool), totalDebt);

        uint256 ethBefore = liquidator.balance;
        pool.liquidate(loanId);
        uint256 ethAfter  = liquidator.balance;
        vm.stopPrank();

        // Liquidator must receive some ETH (strictly more than nothing)
        uint256 received = ethAfter - ethBefore;
        assertGt(received, 0, "liquidator should receive ETH collateral");

        // Received amount must not exceed total collateral
        assertLe(received, totalCollateral, "liquidator cannot receive more than total collateral");
    }

    // ─── 15. Soul-bound: transferFrom is permanently disabled ────────────────
    function test_SoulBound_CannotTransfer() public {
        // borrower already has a token from setUp
        uint256 tokenId = nft.getTokenId(borrower);
        assertGt(tokenId, 0, "borrower should have a token");

        vm.prank(borrower);
        vm.expectRevert(ICreditScoreNFT.SoulBoundToken.selector);
        nft.transferFrom(borrower, other, tokenId);
    }
}
