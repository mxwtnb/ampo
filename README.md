## Auction-managed perpetual options

A Uniswap V4 hook that lets users trade perpetual options.

### Background

This project was built and submitted for the [Hookathon C1](https://learnweb3.learnweb3.io/hackathons/hookathon-c1/), a hackathon for Uniswap V4 hooks.

Feel free to check out the [accompanying slides](https://docs.google.com/presentation/d/1xeaBmTHIDDWf5YchmquMXHaOp3F_LkDre-ubl_WtfKI/) for an overview of the motivation behind the project as well as how the mechanism works.

## Overview

All functionality is built into a single hook contract in `src/AmpoHook.sol`. Unit tests are in `test/AmpoHook.t.sol`.

The main public methods in the AmpoHook contract:

**bid()**: Called by potential managers to place bids

**deposit(), withdraw()**: Deposit or withdraw collateral from contract. Collateral is used to pay rent or funding

**modifyLiquidity()**: Deposit or withdraw liquidity in underlying pool

**setFundingRate()**: Called by manager to change funding rate

**modifyOptionsPosition()**: Called by traders to open or close options positions

## Mechanism

**Perpetual options** are options that never expire and can be exercised at any point in the future. They can be synthetically constructed by borrowing a narrow Uniswap concentrated liquidity position and withdrawing the tokens inside it. Users with an open perpetual options position pay *funding* each block, analogous to funding on perpetual futures.

The pricing of these options is **auction-managed**. A continuous auction is run where anyone can place bids and modify their bids at any time. The current highest bidder is called the *manager*. The manager pays their bid amount, called *rent*, each block to LPs. In return, they get to **set the funding rate** for options holders and **receive funding** from all options positions as well as LP fees from all swaps.

In summary:
- Managers pay rent to LPs each block
- Managers receive funding from options holders each block
- Managers receive LP fees each swap

Managers are therefore able to make a profit if they can set the funding in a smart way, not too low which leaves potential income on the table and not too high which discourages users from buying and holding options. They are incentivized to come up with better ways to calculate the best funding in order to maximise their profit and be able to bid more in the manager auction. With a set of competitive managers who are constantly trying to outbid each other, the system should be able to find the best funding rate for options holders and most of the potential revenue should flow to LPs.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
