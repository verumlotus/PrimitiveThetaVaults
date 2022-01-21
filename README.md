# Primitive Theta Vaults
Theta vaults leveraging Primtive's RMM-01 modeling the payoff function of a covered call. 

[Primitive Finance](https://primitive.finance/) is a new DeFi primitive (pun intended) that designs AMMs such that the payoff function for LP tokens mimics a certain payoff function. There first AMM, RMM-01, aims to replicate the payoff function of selling far out of the money covered calls. For more information, visit their research page [here](https://docs.primitive.finance/faq/research).

This repo contains vaults that automate a covered call strategy leveraging RMM-01 under the hood. This enables users to implement a set-and-forget strategy to capture premiums from theta decay. 

Note that this repo is a prototype, and is not intended to be used on mainnet. There are many optimizations to be performed and testing is sparse currently. 

## Flow for a keeper/owner of the vault
- Flow for rolling over options (duties of the keeper/owner):
    - Call `closePosition` to burn our RMM-01 LP tokens in exchange for a combination of asset (risky) and stable (riskless). Note that in theory, if our option expires out-of-the-money, we should receive only the asset (risky) token. If our option expires in-the-money, we shuld receive only the stable (riskless) token.
    - Set swap path via `setSwapPath` if necessary to swap all of the vault’s stable token to the asset token. 
    - Swap all stable token to asset token via `swap`
    - Call `rollToNextOption` to update the Vault state in preparation for entering a new covered call position. This updates internal bookkeeping. 
    - Set swap path via `setSwapPath` if necessary to calibrate the vault’s holdings of stable token & asset token to match the desired amount for our RMM pool (this can be calculated off-chain)
    - Swap desired amount of asset token for stable token via `swap`
    -  Call `openPosition` to enter a new covered call position with the desired configuration

## Build Repo

This repo uses Foundry for both compiling and testing. 

## Improvements

There are many improvements that could be made, starting with more thorough testing to ensure that the vaults operate as intended. Since RMM-01 is an AMM, the LP (in this case our vault) must deposit a certain composition of risky asset and a riskless stable. As a prototype, this vault swaps between risky <-> riskless multiple times, incurring a fee from the UniswapV3 AMM which would cut into profits. Updating internal bookkeeping mechanisms to limit the need for swapping would provide vault depositors with increased yield. 

## Credits

Inspiration for this project came from this [post](https://mirror.xyz/alexangel.eth/TEBqxbYcoK_5kD8k_fmXuIeKEgfjmdm0LLcm_yqwqt8) by Alex Angel (founder of Primitive). 

This vault was heavily modelled after [Ribbon's V2 Theta Vaults](https://github.com/ribbon-finance/ribbon-v2/) that use Opyn's option protocol under the hood rather than Primitive RMMs. 

Basic scaffolding of Foundry was adapted from Frankie's template here: https://github.com/FrankieIsLost/forge-template/tree/2ff5ae4ea40d77d4aa4e8353e0a878478ec9df24
