// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

library Vault {
    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    // Fees are 6-decimal places. For example: 20 * 10**6 = 20%
    uint256 internal constant FEE_MULTIPLIER = 10**6;

    // Placeholder uint value to prevent cold writes
    uint256 internal constant PLACEHOLDER_UINT = 1;

    struct VaultParams {
        // Token decimals for vault shares
        uint8 decimals;
        // Risky asset of RMM pool
        address asset;
        // Riskless (stable) asset of RMM pool
        address stable;
        // Minimum supply of the vault shares issued, for ETH it's 10**10
        uint56 minimumSupply;
        // Vault cap
        uint104 cap;
    }

    struct OptionState {
        // Current poolId in which the vault has deployed assets
        bytes32 currentPoolId;
        // Amount of liquidity allocated to the curve, wei value with 18 decimals of precision
        uint256 delLiquidity;
    }

    struct VaultState {
        //  Current round number. `round` represents the number of `period`s elapsed.
        uint16 round;
        // Amount of total liquidity we have in our RMM Pool
        uint256 delLiquidityAmount;
        // Amount in asset that was present at the end of the previous round
        // used to calculate vault fees
        uint256 lastRoundAssetAmount;
        // Stores the total tally of how much of `asset` there is in pending deposits
        // to be used to mint shares
        uint128 totalDepositPending;
        // Amount of shares queued for scheduled withdrawals;
        uint128 queuedWithdrawShares;
    }

    struct DepositReceipt {
        // Maximum of 65535 rounds. Assuming 1 round is 7 days, maximum is 1256 years.
        uint16 round;
        // Deposit amount in asset
        uint104 amount;
        // Unredeemed shares balance
        uint128 unredeemedShares;
    }

    struct Withdrawal {
        // Maximum of 65535 rounds. Assuming 1 round is 7 days, maximum is 1256 years.
        uint16 round;
        // Number of shares withdrawn
        uint128 shares;
    }
}