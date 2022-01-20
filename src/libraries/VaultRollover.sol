// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "./Vault.sol";
import "./ShareMath.sol";
import "./UniswapRouter.sol";

/**
 * Utilities to help with Vault rollover to next option
 * Adapted from: https://github.com/ribbon-finance/ribbon-v2/blob/master/contracts/libraries/VaultLifecycle.sol
 */
library VaultRollover {
     /**
     * @param decimals is the decimals of the asset/shares
     * @param totalBalance is the total balance of the asset held by the vault
     * @param currentShareSupply is the supply of the shares invoked with totalSupply()
     * @param lastQueuedAssetWithdrawAmount is the amount queued for withdrawals from previous rounds
     * @param performanceFee is the perf fee percent to charge on premiums
     * @param managementFee is the management fee percent to charge on the AUM
     */
    struct RolloverParams {
        uint256 decimals;
        uint256 totalBalance;
        uint256 currentShareSupply;
        uint256 lastQueuedAssetWithdrawAmount;
        uint256 performanceFee;
        uint256 managementFee;
    }

    /**
     * @notice Calculate the shares to mint, new price per share, and
       amount of funds to re-allocate as collateral for the new round
     * @param vaultState is the storage variable vaultState passed from PrimitiveRmm01Vault
     * @param params is the rollover parameters passed to compute the next state
     * @return newLockedAmount is the amount of funds to allocate for the new round
     * @return queuedWithdrawAssetAmount is the amount of assets set aside for withdrawal
     * @return newPricePerShare is the price per share of the new round
     * @return sharesToMint is the amount of shares to mint from deposits
     * @return performanceFeeInAsset is the performance fee charged by vault
     * @return totalVaultFee is the total amount of fee charged by vault in asset
     */
    function rollover(
        Vault.VaultState storage vaultState, 
        RolloverParams calldata params
    ) external view returns (
        uint256 newLockedAmount,
        uint256 queuedWithdrawAssetAmount,
        uint256 newPricePerShare,
        uint256 sharesToMint,
        uint256 performanceFeeInAsset,
        uint256 totalVaultFee
    ) {
        uint256 currentBalance = params.totalBalance;
        uint256 pendingDepositAmount = vaultState.totalDepositPending;
        uint256 queuedWithdrawShares = vaultState.queuedWithdrawShares;

        uint256 balanceForVaultFees;
        {
            uint256 pricePerShareBeforeFee =
                ShareMath.assetPerShare(
                    params.currentShareSupply,
                    currentBalance,
                    pendingDepositAmount,
                    params.decimals
                );

            uint256 queuedWithdrawAssetBeforeFee =
                params.currentShareSupply > 0
                    ? ShareMath.sharesToAsset(
                        queuedWithdrawShares,
                        pricePerShareBeforeFee,
                        params.decimals
                    )
                    : 0;

            // Deduct the difference between the newly scheduled withdrawals
            // and the older withdrawals
            // so we can charge them fees before they leave
            uint256 withdrawAmountDiff =
                queuedWithdrawAssetBeforeFee > params.lastQueuedAssetWithdrawAmount
                    ? queuedWithdrawAssetBeforeFee - params.lastQueuedAssetWithdrawAmount
                    : 0;

            balanceForVaultFees = currentBalance - queuedWithdrawAssetBeforeFee + withdrawAmountDiff;
        }

        {
            (performanceFeeInAsset, , totalVaultFee) = VaultRollover
                .getVaultFees(
                balanceForVaultFees,
                vaultState.lastRoundAssetAmount,
                vaultState.totalDepositPending,
                params.performanceFee,
                params.managementFee
            );
        }

        // Take into account the fee
        // so we can calculate the newPricePerShare
        currentBalance = currentBalance - totalVaultFee;

        {
            newPricePerShare = ShareMath.assetPerShare(
                params.currentShareSupply,
                currentBalance,
                pendingDepositAmount,
                params.decimals
            );

            // After closing the short, if the options expire in-the-money
            // vault pricePerShare would go down because vault's asset balance decreased.
            // This ensures that the newly-minted shares do not take on the loss.
            sharesToMint = ShareMath.assetToShares(
                pendingDepositAmount,
                newPricePerShare,
                params.decimals
            );

            uint256 newSupply = params.currentShareSupply + sharesToMint;

            queuedWithdrawAssetAmount = newSupply > 0
                ? ShareMath.sharesToAsset(
                    queuedWithdrawShares,
                    newPricePerShare,
                    params.decimals
                )
                : 0;
        }

        return (
            currentBalance - queuedWithdrawAssetAmount, // new locked balance subtracts the queued withdrawals
            queuedWithdrawAssetAmount,
            newPricePerShare,
            sharesToMint,
            performanceFeeInAsset,
            totalVaultFee
        );
    }

    /**
     * @notice Calculates the performance and management fee for this week's round
     * @param currentBalance is the balance of funds held on the vault after closing our position
     * @param assetBalanceBeforeRound is the amount of funds held by the vault before entering our position
     * @param pendingDeposits is the pending deposit amount in assets
     * @param performanceFeePercent is the performance fee pct in 6 decimal places; For example: 20 * 10**6 = 20% 
     * @param managementFeePercent is the management fee pct. Also 6 decimal places
     * @return performanceFeeInAsset is the performance fee
     * @return managementFeeInAsset is the management fee
     * @return vaultFee is the total fees
     */
    function getVaultFees(
        uint256 currentBalance, 
        uint256 assetBalanceBeforeRound,
        uint256 pendingDeposits,
        uint256 performanceFeePercent,
        uint256 managementFeePercent 
    ) internal pure returns (
        uint256 performanceFeeInAsset,
        uint256 managementFeeInAsset,
        uint256 vaultFee
    ) {
        uint256 lockedBalanceSansPending =
            currentBalance > pendingDeposits
                ? currentBalance - pendingDeposits
                : 0;
        
        uint256 _performanceFeeInAsset;
        uint256 _managementFeeInAsset;
        uint256 _vaultFee;

        // Take performance fee and management fee ONLY if difference between
        // last week and this week's vault deposits, taking into account pending
        // deposits and withdrawals, is positive. If it is negative, last week's
        // option expired ITM past breakeven, and the vault took a loss so we
        // do not collect performance fee for last week
        if (lockedBalanceSansPending > assetBalanceBeforeRound) {
            _performanceFeeInAsset = performanceFeePercent > 0
                ? (lockedBalanceSansPending - assetBalanceBeforeRound) * performanceFeePercent / (100 * Vault.FEE_MULTIPLIER)
                : 0;
            _managementFeeInAsset = managementFeePercent > 0
                ? lockedBalanceSansPending * managementFeePercent / (100 * Vault.FEE_MULTIPLIER)
                : 0;

            _vaultFee = _performanceFeeInAsset + _managementFeeInAsset;
        }

        return (_performanceFeeInAsset, _managementFeeInAsset, _vaultFee);
    }

    /**
     * @notice Swaps tokens using UniswapV3 router
     * @param tokenIn is the token address to swap
     * @param minAmountOut is the minimum acceptable amount of tokenOut received from swap
     * @param router is the contract address of UniswapV3 router
     * @param swapPath is the swap path e.g. encodePacked(tokenIn, poolFee, tokenOut)
     */
    function swap(
        address tokenIn,
        uint256 minAmountOut,
        address router,
        bytes calldata swapPath
    ) external {
        uint256 balance = IERC20(tokenIn).balanceOf(address(this));

        if (balance > 0) {
            UniswapRouter.swap(
                address(this),
                tokenIn,
                balance,
                minAmountOut,
                router,
                swapPath
            );
        }
    }

    /**
     * @notice Check if the path set for swap is valid
     * @param swapPath is the swap path e.g. encodePacked(tokenIn, poolFee, tokenOut)
     * @param validTokenIn is the contract address of the correct tokenIn
     * @param validTokenOut is the contract address of the correct tokenOut
     * @param uniswapFactory is the contract address of UniswapV3 factory
     * @return isValidPath is whether the path is valid
     */
    function checkPath(
        bytes calldata swapPath,
        address validTokenIn,
        address validTokenOut,
        address uniswapFactory
    ) external view returns (bool isValidPath) {
        return
            UniswapRouter.checkPath(
                swapPath,
                validTokenIn,
                validTokenOut,
                uniswapFactory
            );
    }
}